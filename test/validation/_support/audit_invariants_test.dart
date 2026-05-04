// Dedicated unit tests for the shared audit-invariant helpers used by
// both `detector_metadata_audit_test.dart` and
// `component_metadata_audit_test.dart`. Pins the exact negative cases
// the v0.16.2 hardening pass was designed to close:
//
//   - Block-comment stripping: a reproducer file whose only `test(`
//     calls are inside `/* ... */` must not satisfy the gate.
//   - Repo containment: absolute paths, `../../` traversal that
//     escapes the repo, and symlinks that canonicalise outside the
//     repo all fail the reproducer + capture checks.
//   - Citation URL: non-empty strings that are not parseable http/https
//     URIs with an authority (e.g. `'see spec'`, `'ftp://...'`, or a
//     relative path) must fail.
//   - Bracket-count: runtimeVerified and externallyCited demand
//     exactly three captures.
//
// Where a helper needs on-disk state, the test materialises a temporary
// directory with a synthetic `pubspec.yaml` and passes it through the
// helper's `repoRoot` override. This keeps the helper hermetic (no
// dependence on repo layout drift) and lets us test both the positive
// and the negative shape of every rule without writing fixture files
// that the Flutter test runner might try to execute.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sleuth/sleuth.dart'
    show
        BracketSpec,
        DetectorMetadata,
        EvidenceTier,
        NetworkMonitorDetector,
        RebuildDetector;
import 'package:sleuth/src/detectors/heavy_compute_detector.dart'
    show HeavyComputeDetector;

import 'audit_invariants.dart';

void main() {
  group('stripDartComments (CLAUDE-R4-1)', () {
    test('removes line comments', () {
      const source = '''
void main() {
  // test('this should not count');
  print('hello');
}
''';
      final result = stripDartComments(source);
      expect(result, isNot(contains('this should not count')));
      expect(result, contains("print('hello');"));
    });

    test('removes block comments', () {
      const source = '''
/*
test('commented out test 1', () {});
testWidgets('commented out test 2', (tester) async {});
*/

void main() {
  print('real code');
}
''';
      final result = stripDartComments(source);
      expect(result, isNot(contains('commented out test 1')));
      expect(result, isNot(contains('commented out test 2')));
      expect(result, contains('real code'));
    });

    test('removes nested-looking content in block comments', () {
      const source = '''
/* outer
   // inner line comment inside block
   still inside block
*/
void main() {}
''';
      final result = stripDartComments(source);
      expect(result, isNot(contains('still inside block')));
      expect(result, isNot(contains('inner line comment')));
    });

    test('AB-10: preserves `//`-looking content inside single-quoted strings',
        () {
      const source = r'''
void main() {
  final s = '// not actually a comment, just string content';
  print(s);
}
''';
      final result = stripDartComments(source);
      expect(result, contains('not actually a comment, just string content'),
          reason: 'Line-comment stripper must not touch content inside string '
              'literals.');
    });

    test('AB-10: preserves comment-like content inside triple-quoted strings',
        () {
      const source = """
void main() {
  final doc = '''
    // docstring-style body
    /* looks like a block comment */
    test('fake inside string', () {});
  ''';
  print(doc);
}
""";
      final result = stripDartComments(source);
      expect(result, contains('docstring-style body'));
      expect(result, contains('looks like a block comment'));
      expect(result, contains("test('fake inside string'"),
          reason: 'Triple-quoted string contents must pass through untouched.');
    });

    test(
        'AB-10: raw strings do not interpret backslash — delimiter still closes',
        () {
      // In a raw string, a `\'` does NOT escape the closing quote. The
      // walker must not treat the escape sequence as preserving the quote.
      const source = r"""
void main() {
  final a = r'\' + 'after';
  final b = r'next raw';
  print(a + b);
}
""";
      final result = stripDartComments(source);
      // We only care that the post-lexer source still compiles-equivalent —
      // the code that follows each raw string must remain intact.
      expect(result, contains("'after'"));
      expect(result, contains("r'next raw'"));
    });

    test('AB-10: string containing `/*` does not swallow code that follows',
        () {
      // Before AB-10, a greedy `/*` regex could chew from a string opener
      // forward if a later `*/` closed inside another string.
      const source = r'''
void main() {
  final a = '/* pretend block opener';
  final b = 'still code after';
  print(a + b);
  test('post-string test', () {});
}
''';
      final result = stripDartComments(source);
      expect(result, contains('still code after'));
      expect(result, contains("test('post-string test'"));
    });
  });

  group('isPathInsideRepo (CODEX-R6-1)', () {
    late Directory repoRoot;

    setUp(() async {
      repoRoot = await Directory.systemTemp.createTemp('sleuth_repo_root_');
    });

    tearDown(() async {
      if (repoRoot.existsSync()) {
        await repoRoot.delete(recursive: true);
      }
    });

    test('accepts a simple repo-relative path', () {
      expect(
          isPathInsideRepo('test/foo.dart', repoRoot: repoRoot.path), isTrue);
    });

    test('accepts the repo root itself', () {
      expect(isPathInsideRepo(repoRoot.path, repoRoot: repoRoot.path), isTrue);
    });

    test('rejects an absolute path outside the repo', () {
      expect(
          isPathInsideRepo('/tmp/definitely_not_in_repo.dart',
              repoRoot: repoRoot.path),
          isFalse);
    });

    test('rejects a ../../ traversal that escapes the repo', () {
      // Descend into a nested subdirectory and try to escape upward
      // beyond the repo root.
      expect(isPathInsideRepo('../../etc/passwd', repoRoot: repoRoot.path),
          isFalse);
    });

    test('rejects empty path', () {
      expect(isPathInsideRepo('', repoRoot: repoRoot.path), isFalse);
    });
  });

  group('checkReproducerFile (CLAUDE-R4-1 + CODEX-R6-1 + CODEX-R3-2)', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sleuth_repro_root_');
      // Helpers require a `pubspec.yaml` at the root to run — without
      // it they return an empty list (CWD not a package).
      await File('${root.path}/pubspec.yaml').writeAsString('name: fake');
    });

    tearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    test('accepts a file with a real test() call that references the token',
        () async {
      // Bundle I (R3-NEW-2): the token must appear as a real identifier
      // in the AST — not just inside a string literal. Before Bundle I,
      // `contains('MyThing')` matched the token inside `'exercises
      // MyThing'`, so a reproducer could satisfy AB3 without ever
      // touching the thing under claim. Now the fixture uses MyThing
      // as a real variable reference.
      final file = File('${root.path}/good_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class MyThing {}

void main() {
  test('exercises the thing', () {
    final instance = MyThing();
    instance.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'MyThing',
        reproducerPath: 'good_test.dart',
        requiredTokens: ['MyThing'],
        repoRoot: root.path,
      );
      expect(failures, isEmpty);
    });

    // R3-NEW-2 (Bundle I): a reproducer that only names the token
    // inside a string literal must be rejected — the point of the AB3
    // parity check is to enforce real code exercising the claim.
    test(
        'rejects a file whose only token reference is inside a string literal '
        '(R3-NEW-2)', () async {
      final file = File('${root.path}/string_only_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';
void main() {
  test('pretends to cover XyzDetector', () {
    final s = 'XyzDetector is here but only in a string';
    s.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'string_only_test.dart',
        requiredTokens: ['XyzDetector'],
        repoRoot: root.path,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('does not reference "XyzDetector"'));
    });

    // AGR-3 (Bundle I): a reproducer that hides its only `test(...)`
    // invocation inside `${...}` interpolation SHOULD pass (interpolation
    // expressions are real code), and a `test(...)` inside a block
    // comment embedded in interpolation SHOULD still be rejected.
    // Exercising this through AST keeps both behaviours correct without
    // the mini-lexer needing to enter interpolation as code mode.
    test(
        'accepts a real `test(` inside a \${...} interpolation expression '
        '(AGR-3)', () async {
      final file = File('${root.path}/interp_test.dart');
      await file.writeAsString(r'''
import 'package:flutter_test/flutter_test.dart';

class MyDetector {}

void main() {
  final label = 'before ${test('real', () {
    final d = MyDetector();
    d.toString();
  })} after';
  label.toString();
}
''');
      final failures = checkReproducerFile(
        label: 'MyDetector',
        reproducerPath: 'interp_test.dart',
        requiredTokens: ['MyDetector'],
        repoRoot: root.path,
      );
      expect(failures, isEmpty);
    });

    test(
        'rejects a file whose only test() calls are inside a /* */ block '
        'comment (CLAUDE-R4-1)', () async {
      final file = File('${root.path}/block_comment_only_test.dart');
      await file.writeAsString('''
/*
test('commented out by block comment', () {});
testWidgets('also commented', (tester) async {});
*/

void main() {
  // No uncommented tests — should fail the gate.
}
''');
      final failures = checkReproducerFile(
        label: 'MyThing',
        reproducerPath: 'block_comment_only_test.dart',
        requiredTokens: ['MyThing'],
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'Block-commented test() calls must not satisfy the gate.');
      expect(failures.first, contains('no test()/testWidgets() calls'));
    });

    test('rejects absolute reproducerPath outside the repo (CODEX-R6-1)',
        () async {
      final outside = await Directory.systemTemp.createTemp('sleuth_outside_');
      try {
        final file = File('${outside.path}/escaped_test.dart');
        await file.writeAsString('void main() { test((){}); }');
        final failures = checkReproducerFile(
          label: 'MyThing',
          reproducerPath: file.path, // absolute, not inside `root`
          requiredTokens: ['MyThing'],
          repoRoot: root.path,
        );
        expect(failures, isNotEmpty);
        expect(failures.first, contains('escapes the repo root'));
      } finally {
        if (outside.existsSync()) await outside.delete(recursive: true);
      }
    });

    test('rejects ../../ traversal escaping the repo (CODEX-R6-1)', () {
      final failures = checkReproducerFile(
        label: 'MyThing',
        reproducerPath: '../../etc/passwd',
        requiredTokens: ['MyThing'],
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty);
      expect(failures.first, contains('escapes the repo root'));
    });

    test('rejects reproducer file that does not reference the token (AB3)',
        () async {
      final file = File('${root.path}/unrelated_test.dart');
      await file.writeAsString('''
void main() {
  test('some real test', () {});
}
''');
      final failures = checkReproducerFile(
        label: 'MyThing',
        reproducerPath: 'unrelated_test.dart',
        requiredTokens: ['MyThing'],
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty);
      expect(failures.first, contains('does not reference "MyThing"'));
    });

    // B4 Bundle K (v0.16.3 blocker): the reproducer gate must prove the
    // detector is actually constructed inside a test scope — not just
    // referenced by name. A file with an unused type annotation and a
    // single unrelated test would previously satisfy the old gate. These
    // negative tests close that loophole while keeping the 4 v0.16.3
    // reproducers (which instantiate in setUp at group scope) passing
    // because setUp is tracked as a wrapper.
    test('B4: rejects a file with token only in a top-level type annotation',
        () async {
      final file = File('${root.path}/top_level_only_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

// Unused annotation outside any test-harness callback — should NOT
// credit XyzDetector as "exercised" by the reproducer.
late XyzDetector _unused;

void main() {
  test('unrelated', () {
    expect(true, isTrue);
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'top_level_only_test.dart',
        requiredTokens: ['XyzDetector'],
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty);
      expect(failures.first,
          contains('does not reference "XyzDetector" by name inside a test'));
    });

    test('B4: rejects a file with token referenced but never instantiated',
        () async {
      final file = File('${root.path}/no_instantiation_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  group('g', () {
    XyzDetector? detector;
    test('references but never constructs', () {
      // `detector` is declared but never assigned — XyzDetector
      // appears as identifier inside scope (satisfying the scope
      // check) but is never instantiated.
      expect(detector, isNull);
    });
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'no_instantiation_test.dart',
        requiredTokens: ['XyzDetector'],
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty);
      expect(failures.first, contains('never instantiates "XyzDetector"'));
    });

    test(
        'B4: accepts instantiation in setUp at group scope (v0.16.3 '
        'reproducer pattern)', () async {
      final file = File('${root.path}/group_setup_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  group('g', () {
    late XyzDetector detector;
    setUp(() {
      detector = XyzDetector();
    });
    test('uses it', () {
      expect(detector, isNotNull);
    });
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'group_setup_test.dart',
        requiredTokens: ['XyzDetector'],
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: 'setUp at group scope must credit instantiation — '
              'this is the v0.16.3 reproducer pattern.');
    });

    test(
        'B4: rejects when coveredStableIds is declared but no stable-id '
        'literal appears in a test scope', () async {
      final file = File('${root.path}/missing_covered_id_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('constructs but does not assert the claimed family', () {
    final d = XyzDetector();
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'missing_covered_id_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty);
      expect(failures.first, contains('does not assert against every family'));
      expect(failures.first, contains('my_family'));
    });

    test(
        'B4: accepts coveredStableIds prefix match (family:suffix covers '
        'the canonical family id)', () async {
      final file = File('${root.path}/prefix_covered_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('exact prefix', () {
    final d = XyzDetector();
    final issue = d;
    expect(issue.stableId, 'my_family:0');
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'prefix_covered_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: 'A string literal matching "my_family:<suffix>" must '
              'satisfy the coveredStableIds prefix convention.');
    });

    test('rejects stable-id literal inside expect() `reason:` named arg',
        () async {
      // Literal sits in a NamedExpression (`reason:`) inside expect() —
      // reason strings are prose, not assertions. Parent-chain walk
      // must reject at the NamedExpression.
      final file = File('${root.path}/reason_bypass_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('bypass attempt via reason string', () {
    final d = XyzDetector();
    expect(42, equals(42), reason: 'my_family');
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'reason_bypass_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'A literal in a `reason:` named arg must NOT satisfy the '
              'coveredStableIds gate — reason strings are prose, not '
              'assertions against detector output.');
      expect(failures.first, contains('my_family'));
    });

    test(
        'rejects stable-id literal inside instance-method call '
        '(String.contains collision)', () async {
      // `contains` is in the matcher allowlist but `target != null`
      // distinguishes the String extension method from the test-package
      // matcher factory. Walker must reject at the non-null-target
      // MethodInvocation.
      final file = File('${root.path}/string_method_bypass_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('bypass via String.contains', () {
    final d = XyzDetector();
    final result = 'probe_value'.contains('my_family');
    if (result) d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'string_method_bypass_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'A literal in `str.contains("my_family")` must NOT credit '
              'the gate — String extension method is not a matcher factory.');
      expect(failures.first, contains('my_family'));
    });

    test('multi-family gate requires EVERY declared family to be asserted',
        () async {
      // `coveredStableIds: {'a', 'b'}` with only family `a` asserted —
      // set-tracking must reject because {a, b}.difference({a}) == {b}.
      final file = File('${root.path}/multi_family_partial_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('asserts only family_a, not family_b', () {
    final d = XyzDetector();
    final issue = d;
    expect(issue.stableId, 'family_a');
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'multi_family_partial_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'family_a', 'family_b'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'Declared families {family_a, family_b} but only family_a '
              'asserted — gate must surface family_b as missing.');
      expect(failures.first, contains('family_b'));
      expect(failures.first, isNot(contains('family_a: ')),
          reason: 'family_a was asserted; it should not appear as missing.');
    });

    test('parametricFamilies: underscore family matches non-empty suffix',
        () async {
      final file = File('${root.path}/parametric_match_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('parametric hit', () {
    final d = XyzDetector();
    final issue = d;
    expect(issue.stableId, 'foo_bar_Baz');
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'parametric_match_test.dart',
        requiredTokens: ['XyzDetector'],
        parametricFamilies: const {'foo_bar'},
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: "'foo_bar_Baz' must credit parametric family 'foo_bar'.");
    });

    test('parametricFamilies: empty suffix rejected (foo_ does not match foo)',
        () async {
      final file = File('${root.path}/parametric_empty_suffix_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('only empty suffix', () {
    final d = XyzDetector();
    final issue = d;
    expect(issue.stableId, 'foo_');
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'parametric_empty_suffix_test.dart',
        requiredTokens: ['XyzDetector'],
        parametricFamilies: const {'foo'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason:
              "'foo_' has empty suffix → must NOT credit parametric 'foo'.");
      expect(failures.first, contains('foo'));
    });

    test(
        'parametricFamilies: bare family does NOT match (coveredStableIds scope)',
        () async {
      final file = File('${root.path}/parametric_no_bare_match_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('only bare literal', () {
    final d = XyzDetector();
    final issue = d;
    expect(issue.stableId, 'foo');
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'parametric_no_bare_match_test.dart',
        requiredTokens: ['XyzDetector'],
        parametricFamilies: const {'foo'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: "'foo' bare literal must NOT match parametric 'foo' — "
              'parametric requires `_<suffix>`.');
    });

    test('parametricFamilies: false-positive guard (food_bar vs foo_)',
        () async {
      final file = File('${root.path}/parametric_false_positive_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('lookalike only', () {
    final d = XyzDetector();
    final issue = d;
    expect(issue.stableId, 'food_bar');
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'parametric_false_positive_test.dart',
        requiredTokens: ['XyzDetector'],
        parametricFamilies: const {'foo'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: "'food_bar' must NOT match parametric 'foo' — prefix check "
              'requires exact `foo_`, not `food`.');
    });

    test(
        'parametricFamilies: real detector literal (repaint_debug_CustomPaint) '
        'credits family `repaint_debug`', () async {
      // Anti-tautology anchor — literal is the exact string emitted by
      // RepaintDetector at runtime (stableId: `repaint_debug_$typeName`).
      // If the detector renames the parametric prefix, this test breaks.
      final file = File('${root.path}/parametric_real_literal_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('real detector literal', () {
    final d = XyzDetector();
    final issue = d;
    expect(issue.stableId, 'repaint_debug_CustomPaint');
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'parametric_real_literal_test.dart',
        requiredTokens: ['XyzDetector'],
        parametricFamilies: const {'repaint_debug'},
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: 'Real detector emission literal must credit parametric '
              'family declared in metadata.');
    });

    test('parametricFamilies + coveredStableIds: BOTH must be matched',
        () async {
      final file = File('${root.path}/parametric_mixed_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('only bare asserted', () {
    final d = XyzDetector();
    final issue = d;
    expect(issue.stableId, 'foo');
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'parametric_mixed_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'foo'},
        parametricFamilies: const {'bar_baz'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'Bare `foo` satisfied but parametric `bar_baz` has no '
              'credited literal — must fail.');
      expect(failures.first, contains('bar_baz'));
    });

    test(
        'parametricFamilies-only declaration: no coveredStableIds, parametric '
        'family matched', () async {
      // Edge case — detector declares ONLY parametricFamilies (null / empty
      // coveredStableIds). Audit gate must still require the declared
      // parametric family to be credited.
      final file = File('${root.path}/parametric_only_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('parametric hit only', () {
    final d = XyzDetector();
    final issue = d;
    expect(issue.stableId, 'foo_Bar');
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'parametric_only_test.dart',
        requiredTokens: ['XyzDetector'],
        parametricFamilies: const {'foo'},
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: 'Parametric-only declaration must pass when the family '
              'prefix is exercised.');
    });

    test('parametricFamilies: empty Set treated as none-declared (not failure)',
        () async {
      // Edge case — detector explicitly passes `const <String>{}` instead
      // of null. Audit must treat empty as "nothing declared" and not
      // synthesise a false-missing entry.
      final file = File('${root.path}/parametric_empty_set_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('bare only', () {
    final d = XyzDetector();
    final issue = d;
    expect(issue.stableId, 'foo');
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'parametric_empty_set_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'foo'},
        parametricFamilies: const <String>{},
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: 'Empty parametricFamilies set contributes zero declared '
              'families; bare `foo` satisfies the only declared family.');
    });

    test('skips gracefully when CWD is not a package root', () {
      // No pubspec.yaml at this override — helper must return [] rather
      // than false-failing.
      final failures = checkReproducerFile(
        label: 'MyThing',
        reproducerPath: 'whatever.dart',
        requiredTokens: ['MyThing'],
        repoRoot:
            '/tmp/definitely_not_a_package_root_${DateTime.now().microsecondsSinceEpoch}',
      );
      expect(failures, isEmpty);
    });

    test('Rule-1 credit: `expect(issues, hasStableId("LIT"))` shape', () async {
      // `parseString` is syntactic-only, so leaving `hasStableId`
      // undefined in the fixture is fine. A local stub would trip
      // shadow detection and reject Rule-1 credit.
      final file = File('${root.path}/rule1_hasStableId_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('rule-1 positive', () {
    final d = XyzDetector();
    expect([d], hasStableId('my_family'));
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'rule1_hasStableId_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: 'Literal as direct arg to `hasStableId(...)` must credit '
              'family `my_family` (Rule 1).');
    });

    test(
        'Rule-2 credit: `.where((i) => i.stableId == "LIT")` closure-parameter '
        'shape', () async {
      // Positive fixture for the matcher's second accepted shape — an
      // inline predicate where the literal is compared against
      // `<param>.stableId` inside a closure whose outer receiver is
      // detector-derived.
      final file = File('${root.path}/rule2_binary_stableId_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {
  List<dynamic> get issues => const [];
}

void main() {
  test('rule-2 positive', () {
    final d = XyzDetector();
    expect(d.issues.where((i) => i.stableId == 'my_family'), isEmpty);
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'rule2_binary_stableId_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: 'Literal as right operand of `i.stableId == "..."` inside a '
              '`.where` closure on a detector-derived receiver must credit '
              '(Rule 2).');
    });

    test(
        'Rule-3 credit: `<x>.stableId.startsWith("LIT_")` method-on-stableId '
        'shape', () async {
      // Positive fixture for the matcher's third accepted shape — the
      // literal is the argument to `startsWith`/`contains`/`endsWith`
      // whose target is a `.stableId` property access.
      final file = File('${root.path}/rule3_startsWith_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('rule-3 positive', () {
    final d = XyzDetector();
    final issue = d;
    expect(issue.stableId.startsWith('my_family:'), isTrue);
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'rule3_startsWith_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason:
              'Literal as arg to `<x>.stableId.startsWith(...)` must credit '
              'family via the `<family>:` prefix convention (Rule 3).');
    });

    test(
        'negative anchor: `expect("foo", equals("foo"))` tautology MUST NOT '
        'credit', () async {
      // The literal's AST position must prove detector-derived
      // provenance. A pure self-assertion never does — reject.
      final file = File('${root.path}/tautology_rejected_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

void main() {
  test('self-assertion tautology', () {
    final d = XyzDetector();
    expect('my_family', equals('my_family'));
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'tautology_rejected_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'Self-assertion tautology `expect("foo", equals("foo"))` '
              'must not credit family coverage.');
      expect(failures.first, contains('does not assert against every family'));
      expect(failures.first, contains('my_family'));
    });

    test('synthetic `FakeIssue.stableId` MUST NOT credit', () async {
      // A class with its own `stableId` getter cannot discharge family
      // coverage — the `.stableId` read must root in a detector-bound
      // receiver.
      final file = File('${root.path}/fake_issue_rejected_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

class FakeIssue {
  final String stableId;
  const FakeIssue(this.stableId);
}

void main() {
  test('synthetic stableId getter', () {
    final d = XyzDetector();
    d.toString();
    final fake = const FakeIssue('my_family');
    expect(fake.stableId, 'my_family');
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'fake_issue_rejected_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'A synthetic class with a `stableId` getter must NOT credit '
              'family coverage — receiver root `fake` is not detector-bound '
              'so the literal fails provenance.');
      expect(failures.first, contains('my_family'));
    });

    test(
        'reassignment-kill: `final issue = FakeIssue(...)` after prior '
        'detector-bound `issue` MUST NOT credit', () async {
      // Non-derived re-declaration removes the prior binding.
      final file = File('${root.path}/reassignment_kill_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {
  List<dynamic> get issues => const [];
}

class FakeIssue {
  final String stableId;
  const FakeIssue(this.stableId);
}

void main() {
  test('reassignment invalidates prior detector binding', () {
    final d = XyzDetector();
    final issue = d;
    issue.toString();
    final fake = const FakeIssue('my_family');
    final issue2 = fake;
    expect(issue2.stableId, 'my_family');
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'reassignment_kill_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'Second declaration `issue2 = fake` is non-derived so the '
              'name is not bound; `issue2.stableId` must fail provenance.');
      expect(failures.first, contains('my_family'));
    });

    test(
        'list-literal smuggling: detector-bound name inside a list '
        'MUST NOT taint the whole expression', () async {
      // Structural walker returns false for list literals regardless of
      // contents.
      final file = File('${root.path}/list_smuggling_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

class FakeIssue {
  final String stableId;
  const FakeIssue(this.stableId);
}

void main() {
  test('list-literal smuggling', () {
    final d = XyzDetector();
    final mixed = [const FakeIssue('my_family'), d];
    expect(mixed.first.stableId, 'my_family');
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'list_smuggling_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'List literal is not an aliasing shape; `mixed` must NOT '
              'be detector-bound even though the literal contains `d`.');
      expect(failures.first, contains('my_family'));
    });

    test('fold accumulator: `fold((acc, item) => ...)` MUST NOT bind `acc`',
        () async {
      // `_closureParamPositions['fold'] = 1` so only `item` is bound;
      // the caller-controlled accumulator stays free.
      final file = File('${root.path}/fold_accumulator_kill_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {
  List<dynamic> get issues => const [];
}

class FakeIssue {
  final String stableId;
  const FakeIssue(this.stableId);
}

void main() {
  test('fold accumulator is not detector-bound', () {
    final d = XyzDetector();
    final result = d.issues.fold(const FakeIssue('my_family'), (acc, item) {
      return acc.stableId == 'my_family' ? acc : acc;
    });
    result.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'fold_accumulator_kill_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: '`acc` is the accumulator (position 0 of fold), not an '
              'element iteration variable. It must NOT be bound, and '
              '`acc.stableId == "my_family"` must fail to credit.');
      expect(failures.first, contains('my_family'));
    });

    test(
        'for-in loop shadow: rebinding `issue` to fake iterable MUST clear '
        'prior detector binding inside the loop body', () async {
      // Iterable is a list literal (not derived), so the loop binder
      // is cleared for the loop body.
      final file = File('${root.path}/forin_shadow_kill_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {
  List<dynamic> get issues => const [];
}

class FakeIssue {
  final String stableId;
  const FakeIssue(this.stableId);
}

void main() {
  test('for-in binder overrides outer detector binding', () {
    final d = XyzDetector();
    for (final issue in [const FakeIssue('my_family')]) {
      expect(issue.stableId, 'my_family');
    }
    d.toString();
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'forin_shadow_kill_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'Iterable is a list literal (not derived). Loop binder '
              '`issue` must NOT be bound inside the loop body; Rule-4 must '
              'reject the literal.');
      expect(failures.first, contains('my_family'));
    });

    test(
        'for-in loop positive: `for (final issue in detector.scanTree(...))` '
        'keeps `issue` detector-bound in loop body', () async {
      // Iterable `d.scanTree(null)` is derived via producer-method
      // whitelist. Loop binder is bound inside the loop body.
      final file = File('${root.path}/forin_scanTree_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {
  List<dynamic> scanTree(dynamic root) => const [];
}

void main() {
  test('for-in over scanTree credits', () {
    final d = XyzDetector();
    for (final issue in d.scanTree(null)) {
      expect(issue.stableId, 'my_family');
    }
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'forin_scanTree_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: 'Iterable `d.scanTree(null)` is detector-derived via '
              'producer-method whitelist. Loop binder `issue` must be '
              'detector-bound in the loop body; Rule-4 credits.');
    });

    test(
        'pattern-destructure kill: `(issue, _) = ...` overwrite MUST clear '
        'prior detector binding', () async {
      // Dart 3 destructuring overwrites — per-slot derivation cannot be
      // proven, so every name in the pattern is conservatively cleared.
      final file = File('${root.path}/pattern_destructure_kill_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {
  List<dynamic> get issues => const [];
}

class FakeIssue {
  final String stableId;
  const FakeIssue(this.stableId);
}

void main() {
  test('pattern destructure rebinds issue to fake', () {
    final d = XyzDetector();
    var issue = d;
    issue.toString();
    (issue, _) = (const FakeIssue('my_family'), 0);
    expect(issue.stableId, 'my_family');
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'pattern_destructure_kill_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'Pattern-assignment conservatively removes `issue` from '
              'bound set (cannot prove per-slot derivation). Rule-4 must '
              'reject.');
      expect(failures.first, contains('my_family'));
    });

    test(
        'shadow detection: local `Matcher hasStableId(...)` function '
        'declaration rejects Rule-1 credit', () async {
      // A local shadow could be a stub that always returns true. Until
      // it is removed (or the reproducer switches to Rule-2/3/4),
      // Rule-1 credits no family for this file.
      final file = File('${root.path}/shadow_rejects_rule1_test.dart');
      await file.writeAsString('''
import 'package:flutter_test/flutter_test.dart';

class XyzDetector {}

Matcher hasStableId(String s) => equals(s);

void main() {
  test('shadow makes Rule-1 unsafe', () {
    final d = XyzDetector();
    expect([d], hasStableId('my_family'));
  });
}
''');
      final failures = checkReproducerFile(
        label: 'XyzDetector',
        reproducerPath: 'shadow_rejects_rule1_test.dart',
        requiredTokens: ['XyzDetector'],
        coveredStableIds: const {'my_family'},
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'Local `Matcher hasStableId(...)` function declaration '
              'triggers shadow detection; Rule-1 must reject to avoid '
              'credit via a potentially-stub helper.');
      expect(failures.first, contains('my_family'));
    });
  });

  group('checkCitationUrl (CLAUDE-R1-2)', () {
    test('accepts a valid https URL', () {
      expect(
          checkCitationUrl('x', 'https://api.flutter.dev/foo', required: true),
          isEmpty);
    });

    test('accepts a valid http URL', () {
      expect(checkCitationUrl('x', 'http://example.com/spec', required: true),
          isEmpty);
    });

    test('rejects non-URI free-form text', () {
      final failures = checkCitationUrl('x', 'see spec', required: true);
      expect(failures, isNotEmpty);
    });

    test('rejects ftp scheme', () {
      final failures =
          checkCitationUrl('x', 'ftp://example.com/spec', required: true);
      expect(failures, isNotEmpty);
      expect(failures.first, contains('http or https'));
    });

    test('rejects URL missing authority', () {
      final failures = checkCitationUrl('x', 'https:///', required: true);
      expect(failures, isNotEmpty);
    });

    test('required missing returns failure', () {
      expect(checkCitationUrl('x', null, required: true), isNotEmpty);
      expect(checkCitationUrl('x', '   ', required: true), isNotEmpty);
    });

    test('optional missing returns empty', () {
      expect(checkCitationUrl('x', null, required: false), isEmpty);
      expect(checkCitationUrl('x', '', required: false), isEmpty);
    });

    test('optional malformed still fails — a bad URL is a bug regardless', () {
      final failures = checkCitationUrl('x', 'see spec', required: false);
      expect(failures, isNotEmpty);
    });

    test('AB-11: rejects single-label host (intranet)', () {
      final failures =
          checkCitationUrl('x', 'http://intranet/spec', required: true);
      expect(failures, isNotEmpty);
      expect(failures.first, contains('single-label'));
    });

    test('AB-11: rejects localhost', () {
      final failures =
          checkCitationUrl('x', 'http://localhost:8080/path', required: true);
      expect(failures, isNotEmpty);
      expect(failures.first, contains('loopback'));
    });

    test('AB-11: rejects 127.0.0.1 loopback', () {
      final failures =
          checkCitationUrl('x', 'http://127.0.0.1/spec', required: true);
      expect(failures, isNotEmpty);
      expect(failures.first, contains('loopback'));
    });

    test('AB-11: rejects IPv6 loopback [::1]', () {
      final failures =
          checkCitationUrl('x', 'http://[::1]/spec', required: true);
      expect(failures, isNotEmpty);
      expect(failures.first, contains('loopback'));
    });

    test('AB-11: accepts dotted external host', () {
      expect(checkCitationUrl('x', 'https://api.flutter.dev/x', required: true),
          isEmpty);
    });

    test('AB-11: accepts IPv4 with dots (non-loopback)', () {
      expect(checkCitationUrl('x', 'http://93.184.216.34/', required: true),
          isEmpty);
    });

    // NEW-CODEX-2 (Bundle H): externally cited claims must resolve
    // off-network, so RFC1918 private-range and link-local literals
    // are rejected alongside loopback.
    test('Bundle H: rejects RFC1918 10.0.0.0/8', () {
      final failures =
          checkCitationUrl('x', 'http://10.0.0.1/', required: true);
      expect(failures, hasLength(1));
      expect(failures.single, contains('RFC1918'));
    });

    test('Bundle H: rejects RFC1918 172.16.0.0/12 (at lower bound)', () {
      final failures =
          checkCitationUrl('x', 'http://172.16.1.1/', required: true);
      expect(failures, hasLength(1));
      expect(failures.single, contains('RFC1918'));
    });

    test('Bundle H: rejects RFC1918 172.16.0.0/12 (at upper bound)', () {
      final failures =
          checkCitationUrl('x', 'http://172.31.255.254/', required: true);
      expect(failures, hasLength(1));
      expect(failures.single, contains('RFC1918'));
    });

    test('Bundle H: accepts 172.15.x.x (outside RFC1918 172.16/12)', () {
      expect(
          checkCitationUrl('x', 'http://172.15.0.1/', required: true), isEmpty);
    });

    test('Bundle H: accepts 172.32.x.x (above RFC1918 172.16/12)', () {
      expect(
          checkCitationUrl('x', 'http://172.32.0.1/', required: true), isEmpty);
    });

    test('Bundle H: rejects RFC1918 192.168.0.0/16', () {
      final failures =
          checkCitationUrl('x', 'http://192.168.1.1/', required: true);
      expect(failures, hasLength(1));
      expect(failures.single, contains('RFC1918'));
    });

    test('Bundle H: rejects IPv4 link-local 169.254.0.0/16', () {
      final failures =
          checkCitationUrl('x', 'http://169.254.1.1/', required: true);
      expect(failures, hasLength(1));
      expect(failures.single, contains('link-local'));
    });

    test('Bundle H: rejects IPv6 link-local fe80::/10', () {
      final failures =
          checkCitationUrl('x', 'http://[fe80::1]/', required: true);
      expect(failures, hasLength(1));
      expect(failures.single, contains('link-local IPv6'));
    });

    test('Bundle H: rejects IPv6 unique-local fc00::/7', () {
      final failures =
          checkCitationUrl('x', 'http://[fc00::beef]/', required: true);
      expect(failures, hasLength(1));
      expect(failures.single, contains('unique-local IPv6'));
    });

    test('Bundle H: accepts external IPv6 (Google DNS)', () {
      expect(
          checkCitationUrl('x', 'http://[2001:4860:4860::8888]/',
              required: true),
          isEmpty);
    });
  });

  group('checkBracketCount', () {
    test('unvalidated tier is unaffected', () {
      expect(
          checkBracketCount(
            label: 'x',
            tier: EvidenceTier.unvalidated,
            capturePaths: null,
          ),
          isEmpty);
    });

    test('reproducerOnly tier is unaffected', () {
      expect(
          checkBracketCount(
            label: 'x',
            tier: EvidenceTier.reproducerOnly,
            capturePaths: const ['one.json'],
          ),
          isEmpty);
    });

    test('runtimeVerified with null captures fails', () {
      final failures = checkBracketCount(
        label: 'x',
        tier: EvidenceTier.runtimeVerified,
        capturePaths: null,
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('missing profileCapturePaths'));
    });

    test('runtimeVerified with 2 captures fails', () {
      final failures = checkBracketCount(
        label: 'x',
        tier: EvidenceTier.runtimeVerified,
        capturePaths: const ['a.json', 'b.json'],
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('exactly 3'));
    });

    test('runtimeVerified with 3 captures passes', () {
      expect(
          checkBracketCount(
            label: 'x',
            tier: EvidenceTier.runtimeVerified,
            capturePaths: const ['a.json', 'b.json', 'c.json'],
          ),
          isEmpty);
    });

    test('externallyCited with 4 captures fails', () {
      final failures = checkBracketCount(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        capturePaths: const ['a.json', 'b.json', 'c.json', 'd.json'],
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('exactly 3'));
    });
  });

  group('checkCoveredThresholds', () {
    test('unvalidated tier is unaffected', () {
      expect(
          checkCoveredThresholds(
            label: 'x',
            tier: EvidenceTier.unvalidated,
            coveredThresholds: null,
          ),
          isEmpty);
    });

    test('reproducerOnly tier is unaffected', () {
      expect(
          checkCoveredThresholds(
            label: 'x',
            tier: EvidenceTier.reproducerOnly,
            coveredThresholds: null,
          ),
          isEmpty);
    });

    test('runtimeVerified with null coveredThresholds fails', () {
      final failures = checkCoveredThresholds(
        label: 'x',
        tier: EvidenceTier.runtimeVerified,
        coveredThresholds: null,
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('missing coveredThresholds'));
    });

    test('externallyCited with empty set fails', () {
      final failures = checkCoveredThresholds(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        coveredThresholds: const <String>{},
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('empty'));
    });

    test('whitespace-only entry fails', () {
      final failures = checkCoveredThresholds(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        coveredThresholds: const {'   '},
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('empty/whitespace'));
    });

    test('dotted severity-scoped entry passes', () {
      expect(
          checkCoveredThresholds(
            label: 'x',
            tier: EvidenceTier.externallyCited,
            coveredThresholds: const {'slow_request.warning'},
          ),
          isEmpty);
    });

    test('non-dotted entry passes (single-severity detector)', () {
      expect(
          checkCoveredThresholds(
            label: 'x',
            tier: EvidenceTier.runtimeVerified,
            coveredThresholds: const {'slow_request'},
          ),
          isEmpty);
    });

    // Malformed-entry negatives.
    test('entry with two dots is rejected as malformed', () {
      final failures = checkCoveredThresholds(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        coveredThresholds: const {'slow_request.warning.extra'},
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('dots'));
      expect(failures.single, contains('slow_request.warning.extra'));
    });

    test('entry with leading dot is rejected (empty stableId)', () {
      final failures = checkCoveredThresholds(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        coveredThresholds: const {'.warning'},
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('empty stableId'));
    });

    test('entry with trailing dot is rejected (empty severity)', () {
      final failures = checkCoveredThresholds(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        coveredThresholds: const {'slow_request.'},
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('empty severity'));
    });

    test('typoed severity is rejected', () {
      final failures = checkCoveredThresholds(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        coveredThresholds: const {'slow_request.warn'},
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('unrecognised severity'));
      expect(failures.single, contains('warn'));
    });

    test('stableId not in coveredStableIds is rejected', () {
      final failures = checkCoveredThresholds(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        coveredThresholds: const {'unknown_family.warning'},
        coveredStableIds: const {'slow_request'},
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('cross-scope drift'));
    });

    test('dotted entry with matching coveredStableIds passes', () {
      expect(
          checkCoveredThresholds(
            label: 'x',
            tier: EvidenceTier.externallyCited,
            coveredThresholds: const {'slow_request.warning'},
            coveredStableIds: const {'slow_request'},
          ),
          isEmpty);
    });

    test('non-dotted entry with bracketThreshold is rejected', () {
      final failures = checkCoveredThresholds(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        coveredThresholds: const {'slow_request'},
        coveredStableIds: const {'slow_request'},
        bracketThreshold: 1000,
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('bracketThreshold is set'));
      expect(failures.single, contains('ambient bracketing'));
    });

    test('non-dotted entry without bracketThreshold still passes', () {
      expect(
          checkCoveredThresholds(
            label: 'x',
            tier: EvidenceTier.externallyCited,
            coveredThresholds: const {'slow_request'},
            coveredStableIds: const {'slow_request'},
          ),
          isEmpty);
    });

    test('multiple entries surface multiple failures', () {
      final failures = checkCoveredThresholds(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        coveredThresholds: const {
          'slow_request.warning.extra',
          'other.warn',
          '.warning',
        },
      );
      expect(failures.length, greaterThanOrEqualTo(3));
    });
  });

  group('checkSeverityScopedCeiling', () {
    test('unvalidated tier is unaffected', () {
      expect(
          checkSeverityScopedCeiling(
            label: 'x',
            tier: EvidenceTier.unvalidated,
            coveredThresholds: const {'slow_request.warning'},
            aboveCeilingMultiplier: null,
          ),
          isEmpty);
    });

    test('reproducerOnly tier is unaffected', () {
      expect(
          checkSeverityScopedCeiling(
            label: 'x',
            tier: EvidenceTier.reproducerOnly,
            coveredThresholds: const {'slow_request.warning'},
            aboveCeilingMultiplier: null,
          ),
          isEmpty);
    });

    test(
        'null coveredThresholds is unaffected (checkCoveredThresholds already failed it)',
        () {
      expect(
          checkSeverityScopedCeiling(
            label: 'x',
            tier: EvidenceTier.runtimeVerified,
            coveredThresholds: null,
            aboveCeilingMultiplier: null,
          ),
          isEmpty);
    });

    test('non-dotted scope does not require explicit multiplier', () {
      expect(
          checkSeverityScopedCeiling(
            label: 'x',
            tier: EvidenceTier.runtimeVerified,
            coveredThresholds: const {'slow_request'},
            aboveCeilingMultiplier: null,
          ),
          isEmpty);
    });

    test('dotted scope without multiplier fails', () {
      final failures = checkSeverityScopedCeiling(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        coveredThresholds: const {'slow_request.warning'},
        aboveCeilingMultiplier: null,
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('severity-scoped'));
      expect(failures.single, contains('slow_request.warning'));
    });

    test('dotted scope with explicit multiplier passes', () {
      expect(
          checkSeverityScopedCeiling(
            label: 'x',
            tier: EvidenceTier.externallyCited,
            coveredThresholds: const {'slow_request.warning'},
            aboveCeilingMultiplier: 1.5,
          ),
          isEmpty);
    });

    test('mixed dotted + non-dotted entries require multiplier', () {
      final failures = checkSeverityScopedCeiling(
        label: 'x',
        tier: EvidenceTier.externallyCited,
        coveredThresholds: const {'slow_request', 'memory_pressure.critical'},
        aboveCeilingMultiplier: null,
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('memory_pressure.critical'));
    });
  });

  group('checkPerStableIdTier', () {
    test('null perStableIdTier is a no-op regardless of base tier', () {
      for (final t in EvidenceTier.values) {
        expect(
            checkPerStableIdTier(
              label: 'x',
              tier: t,
              perStableIdTier: null,
              coveredStableIds: null,
              bracketStableId: null,
            ),
            isEmpty);
      }
    });

    test('empty perStableIdTier map is rejected as misconfiguration', () {
      // Empty map is functionally equivalent to null but signals
      // in-progress edits or copy-paste errors. Reject explicitly.
      final failures = checkPerStableIdTier(
        label: 'x',
        tier: EvidenceTier.reproducerOnly,
        perStableIdTier: const {},
        coveredStableIds: const {'foo'},
        bracketStableId: null,
      );
      expect(failures, isNotEmpty);
      expect(failures.first, contains('empty map'));
      expect(failures.first, contains('use null instead'));
    });

    test('perStableIdTier key absent from coveredStableIds is rejected', () {
      final failures = checkPerStableIdTier(
        label: 'x',
        tier: EvidenceTier.reproducerOnly,
        perStableIdTier: const {'foo': EvidenceTier.runtimeVerified},
        coveredStableIds: const {'bar'},
        bracketStableId: 'foo',
      );
      expect(failures, isNotEmpty);
      expect(failures.first, contains('not in coveredStableIds'));
    });

    test('perStableIdTier value below base tier is rejected', () {
      final failures = checkPerStableIdTier(
        label: 'x',
        tier: EvidenceTier.runtimeVerified,
        perStableIdTier: const {'foo': EvidenceTier.reproducerOnly},
        coveredStableIds: const {'foo'},
        bracketStableId: null,
      );
      expect(failures, isNotEmpty);
      expect(failures.first, contains('BELOW base tier'));
    });

    test(
        'bracketStableId without runtimeVerified+ effective tier is '
        'rejected (regression guard for v0.18.3 audit-bypass)', () {
      // Reproduces the C1 audit-bypass: a hypothetical detector at base
      // unvalidated with a perStableIdTier raise targeting an unrelated
      // family — the bracket fields would otherwise validate against
      // captures while the bracketStableId family stays at unvalidated.
      final failures = checkPerStableIdTier(
        label: 'x',
        tier: EvidenceTier.unvalidated,
        perStableIdTier: const {'unrelated': EvidenceTier.runtimeVerified},
        coveredStableIds: const {'unrelated', 'bracket_target'},
        bracketStableId: 'bracket_target',
      );
      expect(failures, isNotEmpty);
      expect(
          failures.any((f) => f.contains('effective tier unvalidated')), isTrue,
          reason: 'bracketStableId effective tier must be runtimeVerified+ '
              'or the bracket evidence is unmoored from any raised family.');
    });

    test('valid raise (NetworkMonitor pattern) passes', () {
      expect(
          checkPerStableIdTier(
            label: 'x',
            tier: EvidenceTier.reproducerOnly,
            perStableIdTier: const {
              'slow_request': EvidenceTier.runtimeVerified
            },
            coveredStableIds: const {
              'slow_request',
              'large_response',
              'request_frequency',
              'http_error_spike',
              'high_frequency_same_path',
            },
            bracketStableId: 'slow_request',
            topLevelCoveredThresholds: const {'slow_request.warning'},
          ),
          isEmpty);
    });

    test('externallyCited per-family raise passes when key declared', () {
      expect(
          checkPerStableIdTier(
            label: 'x',
            tier: EvidenceTier.reproducerOnly,
            perStableIdTier: const {
              'slow_request': EvidenceTier.externallyCited
            },
            coveredStableIds: const {'slow_request'},
            bracketStableId: 'slow_request',
            topLevelCoveredThresholds: const {'slow_request.warning'},
          ),
          isEmpty);
    });

    test('multiple invalid entries surface multiple failures', () {
      final failures = checkPerStableIdTier(
        label: 'x',
        tier: EvidenceTier.runtimeVerified,
        perStableIdTier: const {
          'undeclared': EvidenceTier.externallyCited,
          'declared_but_lower': EvidenceTier.reproducerOnly,
        },
        coveredStableIds: const {'declared_but_lower'},
        bracketStableId: null,
      );
      expect(failures.length, greaterThanOrEqualTo(2));
      expect(
          failures.any((f) => f.contains('not in coveredStableIds')), isTrue);
      expect(failures.any((f) => f.contains('BELOW base tier')), isTrue);
    });
  });

  group('checkRationale', () {
    test('rejects empty', () {
      expect(checkRationale('x', ''), isNotEmpty);
      expect(checkRationale('x', '   '), isNotEmpty);
    });

    test('rejects short', () {
      expect(checkRationale('x', 'nope'), isNotEmpty);
    });

    test('rejects no-period', () {
      expect(
          checkRationale('x', 'A very long sentence without terminator here'),
          isNotEmpty);
    });

    test('accepts well-formed', () {
      expect(
          checkRationale('x', 'This rationale has enough length and a period.'),
          isEmpty);
    });
  });

  group('checkCaptureOrphans', () {
    late Directory tempRepo;
    late Directory capturesRoot;

    setUp(() {
      tempRepo = Directory.systemTemp.createTempSync('orphan_audit_');
      File(p.join(tempRepo.path, 'pubspec.yaml')).writeAsStringSync('name: t');
      capturesRoot = Directory(p.join(tempRepo.path, 'captures'))
        ..createSync(recursive: true);
    });

    tearDown(() {
      if (tempRepo.existsSync()) {
        tempRepo.deleteSync(recursive: true);
      }
    });

    File writeCapture(String relPath, {String body = '{}'}) {
      final f = File(p.join(capturesRoot.path, relPath));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(body);
      return f;
    }

    test('no-op when capturesRoot does not exist', () {
      final missing = Directory(p.join(tempRepo.path, 'does_not_exist'));
      final failures = checkCaptureOrphans(
        capturesRoot: missing,
        referencedPaths: const {},
        allowlist: const {},
        repoRoot: tempRepo.path,
      );
      expect(failures, isEmpty);
    });

    test('flags unreferenced, unallowlisted capture', () {
      writeCapture('network_monitor/orphan.json');
      final failures = checkCaptureOrphans(
        capturesRoot: capturesRoot,
        referencedPaths: const {},
        allowlist: const {},
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('orphan capture'));
      expect(failures.single, contains('orphan.json'));
    });

    test('accepts files referenced via profileCapturePaths', () {
      writeCapture('network_monitor/live.json');
      final failures = checkCaptureOrphans(
        capturesRoot: capturesRoot,
        referencedPaths: const {'captures/network_monitor/live.json'},
        allowlist: const {},
        repoRoot: tempRepo.path,
      );
      expect(failures, isEmpty);
    });

    test('accepts files listed on the retained-orphan allowlist', () {
      writeCapture('network_monitor/retained.json');
      final failures = checkCaptureOrphans(
        capturesRoot: capturesRoot,
        referencedPaths: const {},
        allowlist: const {'captures/network_monitor/retained.json'},
        repoRoot: tempRepo.path,
      );
      expect(failures, isEmpty);
    });

    test('skips files inside `_fixtures/` by default', () {
      writeCapture('_fixtures/negative_case.json');
      final failures = checkCaptureOrphans(
        capturesRoot: capturesRoot,
        referencedPaths: const {},
        allowlist: const {},
        repoRoot: tempRepo.path,
      );
      expect(failures, isEmpty,
          reason: '_fixtures/ carries negative-case data audited '
              'elsewhere; the orphan walk must skip it.');
    });

    test('ignores non-JSON files (README.md, etc.)', () {
      File(p.join(capturesRoot.path, 'README.md'))
          .writeAsStringSync('docs only');
      final failures = checkCaptureOrphans(
        capturesRoot: capturesRoot,
        referencedPaths: const {},
        allowlist: const {},
        repoRoot: tempRepo.path,
      );
      expect(failures, isEmpty);
    });

    test('surfaces every orphan in one pass (bucket-then-assert)', () {
      writeCapture('network_monitor/orphan_one.json');
      writeCapture('network_monitor/orphan_two.json');
      writeCapture('network_monitor/referenced.json');
      final failures = checkCaptureOrphans(
        capturesRoot: capturesRoot,
        referencedPaths: const {'captures/network_monitor/referenced.json'},
        allowlist: const {},
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(2));
      expect(failures.any((f) => f.contains('orphan_one.json')), isTrue);
      expect(failures.any((f) => f.contains('orphan_two.json')), isTrue);
    });

    test(
        'canonicalizes paths so trailing-slash / separator drift '
        'cannot mask a referenced file', () {
      writeCapture('network_monitor/live.json');
      final failures = checkCaptureOrphans(
        capturesRoot: capturesRoot,
        // Leading `./` + redundant separator — still the same file.
        referencedPaths: const {'./captures/network_monitor/live.json'},
        allowlist: const {},
        repoRoot: tempRepo.path,
      );
      expect(failures, isEmpty);
    });
  });

  group('checkRetainedOrphanManifest', () {
    late Directory tempRepo;

    setUp(() {
      tempRepo = Directory.systemTemp.createTempSync('orphan_manifest_');
      File(p.join(tempRepo.path, 'pubspec.yaml')).writeAsStringSync('name: t');
    });

    tearDown(() {
      if (tempRepo.existsSync()) {
        tempRepo.deleteSync(recursive: true);
      }
    });

    Map<String, Object?> validMetadata({
      String device = 'iPhone 12',
      String deviceOsVersion = 'iOS 17.5',
      String flutterVersion = '3.41.4',
      String unit = 'ms',
      num min = 900,
      num observed = 1000,
      num max = 1100,
    }) =>
        <String, Object?>{
          'device': device,
          'deviceOsVersion': deviceOsVersion,
          'flutterVersion': flutterVersion,
          'captureCommand': 'fvm flutter run --profile',
          'scenario': 'synthetic programmatic test body',
          'expectedMagnitude': {
            'min': min,
            'observed': observed,
            'max': max,
            'unit': unit,
          },
          'captureDate': '2026-04-18T16:00:00Z',
          'role': 'at',
        };

    List<Map<String, Object?>> validTraceEvents() => [
          {
            'ph': 'M',
            'name': 'process_name',
            'pid': 1,
            'tid': 0,
            'args': {'name': 't'}
          },
          {
            'ph': 'M',
            'name': 'thread_name',
            'pid': 1,
            'tid': 39,
            'args': {'name': '1.ui'}
          },
          {
            'ph': 'M',
            'name': 'thread_name',
            'pid': 1,
            'tid': 40,
            'args': {'name': '1.raster'}
          },
          {
            'ph': 'i',
            'cat': 'Sleuth',
            'name': 'sleuth.scenario.begin',
            'pid': 1,
            'tid': 39,
            'ts': 100,
            's': 'p'
          },
          {
            'ph': 'i',
            'cat': 'Sleuth',
            'name': 'sleuth.scenario.end',
            'pid': 1,
            'tid': 39,
            'ts': 1000100,
            's': 'p'
          },
          {
            'ph': 'X',
            'cat': 'Dart',
            'name': 'BUILD',
            'pid': 1,
            'tid': 39,
            'ts': 100,
            'dur': 50
          },
          {
            'ph': 'X',
            'cat': 'Dart',
            'name': 'LAYOUT',
            'pid': 1,
            'tid': 39,
            'ts': 150,
            'dur': 30
          },
          {
            'ph': 'X',
            'cat': 'Dart',
            'name': 'PAINT',
            'pid': 1,
            'tid': 39,
            'ts': 180,
            'dur': 20
          },
          {
            'ph': 'B',
            'cat': 'Dart',
            'name': 'frame',
            'pid': 1,
            'tid': 39,
            'ts': 200
          },
          {
            'ph': 'E',
            'cat': 'Dart',
            'name': 'frame',
            'pid': 1,
            'tid': 39,
            'ts': 300
          },
          {
            'ph': 'i',
            'cat': 'Embedder',
            'name': 'ShaderCompile',
            'pid': 1,
            'tid': 40,
            'ts': 320,
            's': 't'
          },
        ];

    File writeCaptureFile(String relPath, Map<String, Object?> metadata) {
      final f = File(p.join(tempRepo.path, relPath));
      f.parent.createSync(recursive: true);
      // Auto-derive scenario from filename so tempdir captures satisfy
      // the schema's basename-suffix cross-check without each caller
      // having to think about it.
      final basenameNoExt = p.basenameWithoutExtension(relPath);
      final patched = Map<String, Object?>.from(metadata)
        ..['scenario'] = 'synthetic_$basenameNoExt';
      f.writeAsStringSync(jsonEncode({
        'traceEvents': validTraceEvents(),
        'sleuthMetadata': patched,
      }));
      return f;
    }

    RetainedOrphanEntry entry({
      String role = 'below',
      String device = 'iPhone 12',
      String deviceOsVersion = 'iOS 17.5',
      String flutterMajorMinor = '3.41',
      String unit = 'ms',
      num observedMin = 900,
      num observedMax = 1100,
      String consumeBy = '0.16.5',
      String owningClaim = 'NetworkMonitorDetector.slow_request.warning',
      String rationale = 'v0.16.5 re-raise reuse.',
    }) =>
        RetainedOrphanEntry(
          role: role,
          device: device,
          deviceOsVersion: deviceOsVersion,
          flutterMajorMinor: flutterMajorMinor,
          unit: unit,
          observedMin: observedMin,
          observedMax: observedMax,
          consumeBy: consumeBy,
          owningClaim: owningClaim,
          rationale: rationale,
        );

    test('no-op on empty manifest', () {
      final failures = checkRetainedOrphanManifest(
        manifest: const {},
        currentReleaseVersion: '0.16.4',
        repoRoot: tempRepo.path,
      );
      expect(failures, isEmpty);
    });

    test('no-op when repo has no pubspec.yaml', () {
      final other = Directory.systemTemp.createTempSync('no_pubspec_');
      try {
        final failures = checkRetainedOrphanManifest(
          manifest: {'captures/x.json': entry()},
          currentReleaseVersion: '0.16.4',
          repoRoot: other.path,
        );
        expect(failures, isEmpty);
      } finally {
        other.deleteSync(recursive: true);
      }
    });

    test('happy path — capture on disk matches manifest, not yet expired', () {
      writeCaptureFile('captures/slow.json', validMetadata());
      final failures = checkRetainedOrphanManifest(
        manifest: {'captures/slow.json': entry()},
        currentReleaseVersion: '0.16.4',
        repoRoot: tempRepo.path,
      );
      expect(failures, isEmpty);
    });

    test('fails when capture file is missing from disk', () {
      final failures = checkRetainedOrphanManifest(
        manifest: {'captures/missing.json': entry()},
        currentReleaseVersion: '0.16.4',
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('file does not exist on disk'));
    });

    test('fails when capture file does not parse through schema', () {
      final f = File(p.join(tempRepo.path, 'captures/broken.json'));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync('{ not valid json');
      final failures = checkRetainedOrphanManifest(
        manifest: {'captures/broken.json': entry()},
        currentReleaseVersion: '0.16.4',
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('parseFile failed'));
    });

    test('fails when capture device disagrees with manifest', () {
      writeCaptureFile('captures/slow.json',
          validMetadata(device: 'Pixel 7', deviceOsVersion: 'Android 14'));
      final failures = checkRetainedOrphanManifest(
        manifest: {'captures/slow.json': entry()},
        currentReleaseVersion: '0.16.4',
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('device mismatch'));
    });

    test('fails when flutterVersion major.minor disagrees with manifest', () {
      writeCaptureFile(
          'captures/slow.json', validMetadata(flutterVersion: '3.41.4'));
      final failures = checkRetainedOrphanManifest(
        manifest: {
          'captures/slow.json': entry(flutterMajorMinor: '3.32'),
        },
        currentReleaseVersion: '0.16.4',
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('flutterVersion mismatch'));
    });

    test('fails when observed sits below manifest band', () {
      // Capture metadata is self-consistent (min <= observed <= max)
      // but the observed magnitude falls outside the manifest's
      // narrower tolerance band — the drift the manifest cross-check
      // is designed to catch.
      writeCaptureFile('captures/slow.json',
          validMetadata(min: 500, observed: 600, max: 700));
      final failures = checkRetainedOrphanManifest(
        manifest: {
          'captures/slow.json': entry(observedMin: 900, observedMax: 1100),
        },
        currentReleaseVersion: '0.16.4',
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('outside manifest band'));
    });

    test('fails when observed sits above manifest band', () {
      writeCaptureFile('captures/slow.json',
          validMetadata(min: 1400, observed: 1500, max: 1600));
      final failures = checkRetainedOrphanManifest(
        manifest: {
          'captures/slow.json': entry(observedMin: 900, observedMax: 1100),
        },
        currentReleaseVersion: '0.16.4',
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('outside manifest band'));
    });

    test('fails when unit disagrees with manifest', () {
      writeCaptureFile('captures/slow.json', validMetadata(unit: 'bytes'));
      final failures = checkRetainedOrphanManifest(
        manifest: {'captures/slow.json': entry(unit: 'ms')},
        currentReleaseVersion: '0.16.4',
        repoRoot: tempRepo.path,
      );
      expect(failures.any((f) => f.contains('unit mismatch')), isTrue);
    });

    test('fails when consumeBy release has been reached', () {
      writeCaptureFile('captures/slow.json', validMetadata());
      final failures = checkRetainedOrphanManifest(
        manifest: {
          'captures/slow.json': entry(consumeBy: '0.16.5'),
        },
        currentReleaseVersion: '0.16.5',
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('consumeBy "0.16.5" has been reached'));
    });

    test('fails when consumeBy release has been passed', () {
      writeCaptureFile('captures/slow.json', validMetadata());
      final failures = checkRetainedOrphanManifest(
        manifest: {
          'captures/slow.json': entry(consumeBy: '0.16.5'),
        },
        currentReleaseVersion: '0.16.6',
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('has been reached'));
    });

    test('surfaces multiple independent failures for one entry in one run', () {
      // Device + unit both wrong AND consumeBy reached — all three
      // should be reported in a single failure string.
      writeCaptureFile(
          'captures/slow.json',
          validMetadata(
              device: 'Pixel 7', deviceOsVersion: 'Android 14', unit: 'bytes'));
      final failures = checkRetainedOrphanManifest(
        manifest: {
          'captures/slow.json': entry(consumeBy: '0.16.4'),
        },
        currentReleaseVersion: '0.16.4',
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('device mismatch'));
      expect(failures.single, contains('unit mismatch'));
      expect(failures.single, contains('has been reached'));
    });

    test('surfaces failures across multiple entries in one run', () {
      writeCaptureFile('captures/a.json',
          validMetadata(device: 'Pixel 7', deviceOsVersion: 'Android 14'));
      final failures = checkRetainedOrphanManifest(
        manifest: {
          'captures/a.json': entry(),
          'captures/missing.json': entry(),
        },
        currentReleaseVersion: '0.16.4',
        repoRoot: tempRepo.path,
      );
      expect(failures, hasLength(2));
      expect(failures.any((f) => f.contains('a.json')), isTrue);
      expect(failures.any((f) => f.contains('missing.json')), isTrue);
    });
  });

  group('checkAdditionalBrackets (v0.19.8 schema extension)', () {
    BracketSpec mkSpec({
      String stableId = 'platform_channel_traffic',
      String severityLabel = 'warning',
      num threshold = 8,
      String unit = 'ms',
      Set<String>? coveredThresholds,
      List<String>? profileCapturePaths,
      String? observedAxisArgKey,
      double? aboveCeilingMultiplier = 1.5,
      String pathTag = 'x',
    }) =>
        BracketSpec(
          stableId: stableId,
          severityLabel: severityLabel,
          threshold: threshold,
          unit: unit,
          coveredThresholds: coveredThresholds ?? {'$stableId.$severityLabel'},
          profileCapturePaths: profileCapturePaths ??
              [
                'test/validation/captures/$pathTag/below.json',
                'test/validation/captures/$pathTag/at.json',
                'test/validation/captures/$pathTag/above.json',
              ],
          observedAxisArgKey: observedAxisArgKey,
          aboveCeilingMultiplier: aboveCeilingMultiplier,
        );

    test('null is a no-op', () {
      final failures = checkAdditionalBrackets(
        label: 'X',
        additionalBrackets: null,
      );
      expect(failures, isEmpty);
    });

    test('empty list is rejected', () {
      final failures = checkAdditionalBrackets(
        label: 'X',
        additionalBrackets: const <BracketSpec>[],
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('empty list'));
    });

    test('per-spec required-field structural failures surface', () {
      final spec = BracketSpec(
        stableId: '',
        severityLabel: '',
        threshold: 8,
        unit: '',
        coveredThresholds: const <String>{},
        profileCapturePaths: const ['only/one.json'],
      );
      final failures = checkAdditionalBrackets(
        label: 'X',
        additionalBrackets: [spec],
      );
      expect(failures.any((f) => f.contains('stableId is empty')), isTrue);
      expect(failures.any((f) => f.contains('severityLabel is empty')), isTrue);
      expect(failures.any((f) => f.contains('unit is empty')), isTrue);
      expect(failures.any((f) => f.contains('coveredThresholds is empty')),
          isTrue);
      expect(
          failures.any((f) => f.contains('profileCapturePaths must contain')),
          isTrue);
    });

    test('cross-spec collision rejected on identical (stableId, argKey)', () {
      final s1 = mkSpec(observedAxisArgKey: 'observedCount');
      final s2 = mkSpec(observedAxisArgKey: 'observedCount');
      final failures = checkAdditionalBrackets(
        label: 'X',
        additionalBrackets: [s1, s2],
      );
      expect(failures.any((f) => f.contains('cross-spec collision')), isTrue);
    });

    test('same stableId with distinct argKeys is accepted (multi-axis)', () {
      final s1 = mkSpec(observedAxisArgKey: 'observedCount', pathTag: 'a');
      final s2 = mkSpec(
        observedAxisArgKey: 'cumulativeDurationUs',
        pathTag: 'b',
      );
      final failures = checkAdditionalBrackets(
        label: 'X',
        additionalBrackets: [s1, s2],
      );
      expect(failures, isEmpty);
    });

    test('mixed-mode: top-level (spec #0) and additionalBrackets[0] collide',
        () {
      final extra = mkSpec(observedAxisArgKey: 'a');
      final failures = checkAdditionalBrackets(
        label: 'X',
        additionalBrackets: [extra],
        topLevelStableId: 'platform_channel_traffic',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'a',
      );
      expect(
          failures.any(
              (f) => f.contains('top-level (spec #0)') && f.contains('#1')),
          isTrue);
    });

    test('mixed-mode: top-level + additionalBrackets distinct argKeys accept',
        () {
      final extra = mkSpec(observedAxisArgKey: 'b');
      final failures = checkAdditionalBrackets(
        label: 'X',
        additionalBrackets: [extra],
        topLevelStableId: 'platform_channel_traffic',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'a',
      );
      expect(failures, isEmpty);
    });

    test(
        'mixed-mode: top-level warning + additionalBrackets critical with '
        'identical (stableId, argKey=null) accepted (tier-stack raise)', () {
      // Canonical shape for a detector that brackets BOTH the warning
      // and critical thresholds of a single family without exporting an
      // observed-axis arg (e.g. HeavyCompute's per-BUILD ms is read
      // directly off the BUILD `dur` field, not stamped into args). The
      // trace events differ by severity so there is no double-counting.
      final extra = mkSpec(
        severityLabel: 'critical',
        coveredThresholds: {'platform_channel_traffic.critical'},
        pathTag: 'critical',
      );
      final failures = checkAdditionalBrackets(
        label: 'X',
        additionalBrackets: [extra],
        topLevelStableId: 'platform_channel_traffic',
        topLevelSeverityLabel: 'warning',
      );
      expect(failures, isEmpty);
    });

    test(
        'two additionalBrackets specs on same stableId+argKey but different '
        'severities accepted (audit gap fix)', () {
      // Regression guard for the v0.19.13 audit-invariant patch: pre-fix
      // the seen tuple was (stableId, argKey) and this case threw a
      // false collision. Post-fix the seen tuple is (stableId,
      // severityLabel, argKey), so two specs that share stableId + argKey
      // but differ on severityLabel are disjoint.
      final s1 = mkSpec(severityLabel: 'warning', pathTag: 'w');
      final s2 = mkSpec(
        severityLabel: 'critical',
        coveredThresholds: {'platform_channel_traffic.critical'},
        pathTag: 'c',
      );
      final failures = checkAdditionalBrackets(
        label: 'X',
        additionalBrackets: [s1, s2],
      );
      expect(failures, isEmpty);
    });

    test('three specs: only the colliding pair is reported', () {
      final s1 = mkSpec(observedAxisArgKey: 'a', pathTag: 'p1');
      final s2 = mkSpec(observedAxisArgKey: 'b', pathTag: 'p2');
      final s3 = mkSpec(observedAxisArgKey: 'a', pathTag: 'p3');
      final failures = checkAdditionalBrackets(
        label: 'X',
        additionalBrackets: [s1, s2, s3],
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('#1'));
      expect(failures.single, contains('#3'));
    });
  });

  group('checkPerStableIdTier additionalBrackets coverage (v0.19.8)', () {
    test('runtimeVerified raise covered by canonical coveredThresholds passes',
        () {
      final failures = checkPerStableIdTier(
        label: 'X',
        tier: EvidenceTier.reproducerOnly,
        perStableIdTier: const {'foo': EvidenceTier.runtimeVerified},
        coveredStableIds: const {'foo'},
        bracketStableId: 'foo',
        topLevelCoveredThresholds: const {'foo.warning'},
      );
      expect(failures, isEmpty);
    });

    test('runtimeVerified raise covered by additionalBrackets passes', () {
      final spec = BracketSpec(
        stableId: 'bar',
        severityLabel: 'warning',
        threshold: 8,
        unit: 'ms',
        coveredThresholds: const {'bar.warning'},
        profileCapturePaths: const [
          'test/validation/captures/y/below.json',
          'test/validation/captures/y/at.json',
          'test/validation/captures/y/above.json',
        ],
      );
      final failures = checkPerStableIdTier(
        label: 'X',
        tier: EvidenceTier.reproducerOnly,
        perStableIdTier: const {
          'foo': EvidenceTier.runtimeVerified,
          'bar': EvidenceTier.runtimeVerified,
        },
        coveredStableIds: const {'foo', 'bar'},
        bracketStableId: 'foo',
        additionalBrackets: [spec],
        topLevelCoveredThresholds: const {'foo.warning'},
      );
      expect(failures, isEmpty);
    });

    test('runtimeVerified raise without coveredThresholds entry is rejected',
        () {
      final failures = checkPerStableIdTier(
        label: 'X',
        tier: EvidenceTier.reproducerOnly,
        perStableIdTier: const {
          'foo': EvidenceTier.runtimeVerified,
          'unmoored': EvidenceTier.runtimeVerified,
        },
        coveredStableIds: const {'foo', 'unmoored'},
        bracketStableId: 'foo',
        additionalBrackets: null,
        topLevelCoveredThresholds: const {'foo.warning'},
      );
      expect(failures.any((f) => f.contains('"unmoored"')), isTrue);
      expect(
          failures.any((f) => f.contains('no coveredThresholds entry of the '
              'form "unmoored.<severity>"')),
          isTrue);
    });

    test(
        'spec with mismatched stableId vs coveredThresholds does not cover '
        'perStableIdTier raise (drift guard)', () {
      // Spec declares stableId='X' but coveredThresholds={'Y.warning'} —
      // it does NOT cover a perStableIdTier raise on 'X' anymore (the
      // schema field is now load-bearing).
      final spec = BracketSpec(
        stableId: 'X',
        severityLabel: 'warning',
        threshold: 8,
        unit: 'ms',
        coveredThresholds: const {'Y.warning'},
        profileCapturePaths: const [
          'a.json',
          'b.json',
          'c.json',
        ],
      );
      final failures = checkPerStableIdTier(
        label: 'L',
        tier: EvidenceTier.reproducerOnly,
        perStableIdTier: const {'X': EvidenceTier.runtimeVerified},
        coveredStableIds: const {'X'},
        bracketStableId: null,
        additionalBrackets: [spec],
        topLevelCoveredThresholds: null,
      );
      expect(failures.any((f) => f.contains('"X"')), isTrue);
      expect(
          failures.any((f) => f.contains('no coveredThresholds entry of the '
              'form "X.<severity>"')),
          isTrue);
    });
  });

  group('checkCanonicalCoveredThresholdBacking (v0.19.15)', () {
    test('canonical self-backs its own severity', () {
      final failures = checkCanonicalCoveredThresholdBacking(
        label: 'L',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'X',
        topLevelSeverityLabel: 'warning',
        topLevelCoveredThresholds: const {'X.warning'},
        additionalBrackets: null,
      );
      expect(failures, isEmpty);
    });

    test('tier-stack backed by canonical + additionalBrackets[critical] passes',
        () {
      final critical = BracketSpec(
        stableId: 'X',
        severityLabel: 'critical',
        threshold: 16,
        unit: 'ms',
        coveredThresholds: const {'X.critical'},
        profileCapturePaths: const ['a.json', 'b.json', 'c.json'],
        aboveCeilingMultiplier: 1.5,
      );
      final failures = checkCanonicalCoveredThresholdBacking(
        label: 'L',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'X',
        topLevelSeverityLabel: 'warning',
        topLevelCoveredThresholds: const {'X.warning', 'X.critical'},
        additionalBrackets: [critical],
      );
      expect(failures, isEmpty);
    });

    test('canonical declares X.critical without backing fails', () {
      final failures = checkCanonicalCoveredThresholdBacking(
        label: 'L',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'X',
        topLevelSeverityLabel: 'warning',
        topLevelCoveredThresholds: const {'X.warning', 'X.critical'},
        additionalBrackets: null,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('"X.critical" has no backing'));
      expect(
          failures.single, contains('(stableId="X", severityLabel="warning")'));
    });

    test('cross-family entry without backing fails', () {
      final failures = checkCanonicalCoveredThresholdBacking(
        label: 'L',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'X',
        topLevelSeverityLabel: 'warning',
        topLevelCoveredThresholds: const {'X.warning', 'Y.critical'},
        additionalBrackets: null,
      );
      expect(failures.any((f) => f.contains('"Y.critical"')), isTrue);
    });

    test('bare-family entry skipped', () {
      final failures = checkCanonicalCoveredThresholdBacking(
        label: 'L',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'X',
        topLevelSeverityLabel: 'warning',
        topLevelCoveredThresholds: const {'X'},
        additionalBrackets: null,
      );
      expect(failures, isEmpty);
    });

    test('reproducerOnly tier is a no-op even with malformed thresholds', () {
      final failures = checkCanonicalCoveredThresholdBacking(
        label: 'L',
        tier: EvidenceTier.reproducerOnly,
        topLevelStableId: 'X',
        topLevelSeverityLabel: 'warning',
        topLevelCoveredThresholds: const {'X.warning', 'X.critical'},
        additionalBrackets: null,
      );
      expect(failures, isEmpty);
    });

    test('production NetworkMonitor metadata passes (anti-confirmation-bias)',
        () {
      final detector = NetworkMonitorDetector();
      final meta = detector.validationMetadata;
      final failures = checkCanonicalCoveredThresholdBacking(
        label: 'NetworkMonitorDetector',
        tier: meta.effectiveMaxTier,
        topLevelStableId: meta.bracketStableId,
        topLevelSeverityLabel: meta.bracketSeverityLabel,
        topLevelCoveredThresholds: meta.coveredThresholds,
        additionalBrackets: meta.additionalBrackets,
      );
      expect(failures, isEmpty,
          reason: 'Production NetworkMonitor metadata should be backed by '
              'matching specs across canonical + additionalBrackets: $failures');
    });

    test('production HeavyCompute metadata passes (tier-stack family)', () {
      final detector = HeavyComputeDetector();
      final meta = detector.validationMetadata;
      final failures = checkCanonicalCoveredThresholdBacking(
        label: 'HeavyComputeDetector',
        tier: meta.effectiveMaxTier,
        topLevelStableId: meta.bracketStableId,
        topLevelSeverityLabel: meta.bracketSeverityLabel,
        topLevelCoveredThresholds: meta.coveredThresholds,
        additionalBrackets: meta.additionalBrackets,
      );
      expect(failures, isEmpty,
          reason: 'Production HeavyCompute metadata should be backed across '
              'canonical + additionalBrackets: $failures');
    });

    test('production RebuildDetector metadata passes (perStableIdTier raise)',
        () {
      final detector = RebuildDetector();
      final meta = detector.validationMetadata;
      final failures = checkCanonicalCoveredThresholdBacking(
        label: 'RebuildDetector',
        tier: meta.effectiveMaxTier,
        topLevelStableId: meta.bracketStableId,
        topLevelSeverityLabel: meta.bracketSeverityLabel,
        topLevelCoveredThresholds: meta.coveredThresholds,
        additionalBrackets: meta.additionalBrackets,
      );
      expect(failures, isEmpty,
          reason: 'Production RebuildDetector metadata should be backed: '
              '$failures');
    });
  });

  group('checkBracketBoundsSanity (v0.19.15)', () {
    test('within-bounds canonical + spec passes', () {
      final spec = BracketSpec(
        stableId: 'X',
        severityLabel: 'critical',
        threshold: 16,
        unit: 'ms',
        coveredThresholds: const {'X.critical'},
        profileCapturePaths: const ['a.json', 'b.json', 'c.json'],
        atTolerance: 0.40,
        aboveCeilingMultiplier: 2.0,
        observedAxisTolerance: 0.10,
      );
      final failures = checkBracketBoundsSanity(
        label: 'L',
        tier: EvidenceTier.runtimeVerified,
        canonicalAtTolerance: 0.10,
        canonicalAboveCeilingMultiplier: 2.0,
        canonicalObservedAxisTolerance: 0.25,
        canonicalObservedAxisReduction: 'max',
        additionalBrackets: [spec],
      );
      expect(failures, isEmpty);
    });

    test('observedAxisTolerance > 0.25 rejected', () {
      final failures = checkBracketBoundsSanity(
        label: 'L',
        tier: EvidenceTier.runtimeVerified,
        canonicalAtTolerance: 0.10,
        canonicalAboveCeilingMultiplier: 2.0,
        canonicalObservedAxisTolerance: 0.30,
        canonicalObservedAxisReduction: 'max',
        additionalBrackets: null,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('observedAxisTolerance=0.3'));
    });

    test('atTolerance > 0.65 rejected', () {
      final failures = checkBracketBoundsSanity(
        label: 'L',
        tier: EvidenceTier.runtimeVerified,
        canonicalAtTolerance: 0.66,
        canonicalAboveCeilingMultiplier: 2.0,
        canonicalObservedAxisTolerance: 0.25,
        canonicalObservedAxisReduction: 'max',
        additionalBrackets: null,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('atTolerance=0.66'));
    });

    test('aboveCeilingMultiplier <= 1.0 rejected (inverts rule)', () {
      final failures = checkBracketBoundsSanity(
        label: 'L',
        tier: EvidenceTier.runtimeVerified,
        canonicalAtTolerance: 0.10,
        canonicalAboveCeilingMultiplier: 0.9,
        canonicalObservedAxisTolerance: 0.25,
        canonicalObservedAxisReduction: 'max',
        additionalBrackets: null,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('aboveCeilingMultiplier=0.9'));
    });

    test('observedAxisReduction not in approved set rejected', () {
      final failures = checkBracketBoundsSanity(
        label: 'L',
        tier: EvidenceTier.runtimeVerified,
        canonicalAtTolerance: 0.10,
        canonicalAboveCeilingMultiplier: 2.0,
        canonicalObservedAxisTolerance: 0.25,
        canonicalObservedAxisReduction: 'median',
        additionalBrackets: null,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('observedAxisReduction="median"'));
    });

    test('non-runtimeVerified tier is a no-op', () {
      final failures = checkBracketBoundsSanity(
        label: 'L',
        tier: EvidenceTier.reproducerOnly,
        canonicalAtTolerance: 99.0,
        canonicalAboveCeilingMultiplier: 0.0,
        canonicalObservedAxisTolerance: 99.0,
        canonicalObservedAxisReduction: 'bogus',
        additionalBrackets: null,
      );
      expect(failures, isEmpty);
    });

    test('bounds applied to additionalBrackets[*] entries too', () {
      final spec = BracketSpec(
        stableId: 'X',
        severityLabel: 'critical',
        threshold: 16,
        unit: 'ms',
        coveredThresholds: const {'X.critical'},
        profileCapturePaths: const ['a.json', 'b.json', 'c.json'],
        aboveCeilingMultiplier: 4.0, // above 3.0 ceiling
      );
      final failures = checkBracketBoundsSanity(
        label: 'L',
        tier: EvidenceTier.runtimeVerified,
        canonicalAtTolerance: 0.10,
        canonicalAboveCeilingMultiplier: 2.0,
        canonicalObservedAxisTolerance: 0.25,
        canonicalObservedAxisReduction: 'max',
        additionalBrackets: [spec],
      );
      expect(failures.any((f) => f.contains('additionalBrackets[0]')), isTrue);
      expect(failures.any((f) => f.contains('aboveCeilingMultiplier=4.0')),
          isTrue);
    });
  });

  group('checkCapturePathPerDirectoryNamingUniformity (v0.19.15)', () {
    late Directory tempRoot;
    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('sleuth_uniformity_');
    });
    tearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    File writeCapture(String relativePath, String scenario) {
      final f = File(p.join(tempRoot.path, relativePath));
      f.parent.createSync(recursive: true);
      // Minimal capture skeleton sufficient for parseFile success — uses
      // the anchor-fixture template as substrate.
      final base = File('test/validation/captures/_fixtures/'
              'anchor_devtools_export.json')
          .readAsStringSync();
      final mutated = base.replaceFirst(
          RegExp(r'"scenario"\s*:\s*"[^"]*"'), '"scenario": "$scenario"');
      f.writeAsStringSync(mutated);
      return f;
    }

    test('uniform exact-shape directory passes', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      writeCapture('det_a/foo_below.json', 'foo_below');
      writeCapture('det_a/foo_at.json', 'foo_at');
      writeCapture('det_a/foo_above.json', 'foo_above');
      final failures = checkCapturePathPerDirectoryNamingUniformity(
        capturesRoot: tempRoot,
      );
      expect(failures, isEmpty);
    });

    test('uniform suffix-shape directory passes', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      writeCapture('det_b/below.json', 'rebuild_activity_below');
      writeCapture('det_b/at.json', 'rebuild_activity_at');
      writeCapture('det_b/above.json', 'rebuild_activity_above');
      final failures = checkCapturePathPerDirectoryNamingUniformity(
        capturesRoot: tempRoot,
      );
      expect(failures, isEmpty);
    });

    test('mixed shapes within one directory rejected', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      writeCapture('det_c/foo_below.json', 'foo_below'); // exact
      writeCapture('det_c/at.json', 'family_at'); // suffix
      final failures = checkCapturePathPerDirectoryNamingUniformity(
        capturesRoot: tempRoot,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('captures/det_c'));
      expect(failures.single, contains('shape drift'));
    });

    test('_fixtures/ directory excluded from uniformity check', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      writeCapture('_fixtures/synth_a.json', 'arbitrary_unrelated_scenario');
      writeCapture('_fixtures/synth_b.json', 'totally_different_scenario');
      final failures = checkCapturePathPerDirectoryNamingUniformity(
        capturesRoot: tempRoot,
      );
      expect(failures, isEmpty);
    });

    test('suffix-shape directory with mismatched scenario prefix rejected', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      // Both files use suffix shape but with different prefix strings —
      // simulates a copy-paste typo where one file inherits the wrong
      // detector's scenario prefix while basenames stay short.
      writeCapture('det_d/below.json', 'rebuild_activity_below');
      writeCapture('det_d/at.json', 'slow_request_at');
      final failures = checkCapturePathPerDirectoryNamingUniformity(
        capturesRoot: tempRoot,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('captures/det_d'));
      expect(failures.single, contains('scenario-prefix drift'));
      expect(failures.single, contains('rebuild_activity_'));
      expect(failures.single, contains('slow_request_'));
    });
  });

  group('checkRuntimeVerifiedRequiresObservedAxisArgKey (v0.19.17)', () {
    BracketSpec mkSpec({
      required String stableId,
      required String severityLabel,
      String? observedAxisArgKey,
    }) {
      return BracketSpec(
        stableId: stableId,
        severityLabel: severityLabel,
        threshold: 10,
        unit: 'ms',
        coveredThresholds: {'$stableId.$severityLabel'},
        profileCapturePaths: const [
          'a/below.json',
          'a/at.json',
          'a/above.json',
        ],
        observedAxisArgKey: observedAxisArgKey,
      );
    }

    test('runtimeVerified canonical with non-null argKey passes', () {
      final failures = checkRuntimeVerifiedRequiresObservedAxisArgKey(
        label: 'TestDetector',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'foo',
        topLevelObservedAxisArgKey: 'observedFoo',
      );
      expect(failures, isEmpty);
    });

    test('runtimeVerified canonical with null argKey fails', () {
      final failures = checkRuntimeVerifiedRequiresObservedAxisArgKey(
        label: 'TestDetector',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'foo',
        topLevelObservedAxisArgKey: null,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('TestDetector'));
      expect(failures.single, contains('canonical bracket'));
      expect(failures.single, contains('observedAxisArgKey is null'));
      expect(failures.single, contains('demote'));
    });

    test('runtimeVerified additionalBrackets[i] with null argKey fails', () {
      final failures = checkRuntimeVerifiedRequiresObservedAxisArgKey(
        label: 'TestDetector',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'foo',
        topLevelObservedAxisArgKey: 'observedFoo',
        additionalBrackets: [
          mkSpec(stableId: 'bar', severityLabel: 'critical'),
        ],
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('additionalBrackets[0]'));
      expect(failures.single, contains('"bar"'));
      expect(failures.single, contains('"critical"'));
      expect(failures.single, contains('observedAxisArgKey is null'));
    });

    test('reproducerOnly canonical with null argKey is no-op', () {
      final failures = checkRuntimeVerifiedRequiresObservedAxisArgKey(
        label: 'TestDetector',
        tier: EvidenceTier.reproducerOnly,
        topLevelStableId: 'foo',
        topLevelObservedAxisArgKey: null,
      );
      expect(failures, isEmpty);
    });

    test('externallyCited canonical with null argKey fails', () {
      final failures = checkRuntimeVerifiedRequiresObservedAxisArgKey(
        label: 'TestDetector',
        tier: EvidenceTier.externallyCited,
        topLevelStableId: 'foo',
        topLevelObservedAxisArgKey: null,
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('canonical bracket'));
    });

    test(
        'runtimeVerified canonical OK + null argKey on additionalBrackets[0] '
        'fails on the bracket only', () {
      final failures = checkRuntimeVerifiedRequiresObservedAxisArgKey(
        label: 'TestDetector',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'foo',
        topLevelObservedAxisArgKey: 'observedFoo',
        additionalBrackets: [
          mkSpec(stableId: 'bar', severityLabel: 'warning'),
          mkSpec(
            stableId: 'baz',
            severityLabel: 'critical',
            observedAxisArgKey: 'observedBaz',
          ),
        ],
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('additionalBrackets[0]'));
      expect(failures.single, contains('"bar"'));
    });
  });

  group('checkCapturesCarryObservedAxisArg (v0.19.18)', () {
    // Positive case (real on-device captures that carry the arg) and
    // backward-compat allowlist behaviour are exercised against real
    // capture JSONs. Tier-gate + missing-arg failure paths use the
    // existing _fixtures stripped fixtures from the v0.19.18 schema
    // skip-semantics regression test.
    final repoRoot = Directory.current.path;
    File ensurePubspec(Directory dir) {
      final f = File(p.join(dir.path, 'pubspec.yaml'));
      if (!f.existsSync()) f.writeAsStringSync('name: stub\nversion: 0.0.1\n');
      return f;
    }

    test(
        'positive: NetworkMonitor slow_request captures carry the arg → '
        'passes', () {
      ensurePubspec(Directory(repoRoot));
      final failures = checkCapturesCarryObservedAxisArg(
        label: 'NetworkMonitorDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'slow_request',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedDurationMs',
        topLevelCapturePaths: const [
          'test/validation/captures/network_monitor/slow_request_below.json',
          'test/validation/captures/network_monitor/slow_request_at.json',
          'test/validation/captures/network_monitor/slow_request_above.json',
        ],
        repoRoot: repoRoot,
      );
      expect(failures, isEmpty,
          reason: 'NetworkMonitor slow_request captures DO carry '
              'observedDurationMs in every in-span warning event; the '
              'invariant must accept them. Failures: $failures');
    });

    test(
        'negative: stripped fixtures lack the arg → fails with actionable '
        'message naming the bracket', () {
      ensurePubspec(Directory(repoRoot));
      final stripped = File(p.join(
        repoRoot,
        'test/validation/captures/_fixtures/'
        'slow_request_at_no_observed_axis.json',
      ));
      if (!stripped.existsSync()) {
        markTestSkipped(
          'Stripped fixture not present; run profile_capture_schema_test.dart '
          'first to generate it.',
        );
        return;
      }
      final failures = checkCapturesCarryObservedAxisArg(
        label: 'TestDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'slow_request',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedDurationMs',
        topLevelCapturePaths: const [
          'test/validation/captures/_fixtures/'
              'slow_request_below_no_observed_axis.json',
          'test/validation/captures/_fixtures/'
              'slow_request_at_no_observed_axis.json',
          'test/validation/captures/_fixtures/'
              'slow_request_above_no_observed_axis.json',
        ],
        repoRoot: repoRoot,
      );
      expect(failures, isNotEmpty,
          reason: 'Stripped fixtures lack observedDurationMs; invariant '
              'must surface the dormant cross-check.');
      expect(failures.first, contains('TestDetector'));
      expect(failures.first, contains('"slow_request"'));
      expect(failures.first, contains('"warning"'));
      expect(failures.first, contains('"observedDurationMs"'));
      expect(failures.first, contains('legacyObservedAxisAllowlist'));
    });

    test(
        'allowlisted: bracket key in allowlist → no-op even with stripped '
        'captures', () {
      ensurePubspec(Directory(repoRoot));
      final failures = checkCapturesCarryObservedAxisArg(
        label: 'TestDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'slow_request',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedDurationMs',
        topLevelCapturePaths: const [
          'test/validation/captures/_fixtures/'
              'slow_request_below_no_observed_axis.json',
          'test/validation/captures/_fixtures/'
              'slow_request_at_no_observed_axis.json',
          'test/validation/captures/_fixtures/'
              'slow_request_above_no_observed_axis.json',
        ],
        legacyObservedAxisAllowlist: const {
          'TestDetector (tier=runtimeVerified):slow_request:warning',
        },
        repoRoot: repoRoot,
      );
      expect(failures, isEmpty,
          reason: 'Allowlist entry for the bracket key must skip the '
              'capture-fidelity check entirely.');
    });

    test(
        'tier gate: reproducerOnly bracket → no-op regardless of capture '
        'state', () {
      final failures = checkCapturesCarryObservedAxisArg(
        label: 'TestDetector (tier=reproducerOnly)',
        tier: EvidenceTier.reproducerOnly,
        topLevelStableId: 'slow_request',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedDurationMs',
        topLevelCapturePaths: const [
          'test/validation/captures/_fixtures/'
              'slow_request_below_no_observed_axis.json',
          'test/validation/captures/_fixtures/'
              'slow_request_at_no_observed_axis.json',
          'test/validation/captures/_fixtures/'
              'slow_request_above_no_observed_axis.json',
        ],
        repoRoot: repoRoot,
      );
      expect(failures, isEmpty,
          reason: 'reproducerOnly tier must not exercise the invariant.');
    });
  });

  group('checkDetectorAxisInRoleBand (v0.19.19)', () {
    // Builds a wrapped capture JSON with one in-span issue event whose
    // `args[axisKey]` carries [detectorValue]. The role-band check
    // reduces over those samples (max/last) and asserts the result lies
    // in the role's bracket band. We do not need the full Sleuth
    // export shape here — just enough trace events for the invariant's
    // begin/end scenario span and one issue event with the axis arg.
    File writeCaptureFixture(
      Directory dir, {
      required String filename,
      required String stableId,
      required String severityLabel,
      required String axisKey,
      required num detectorValue,
    }) {
      final scenarioName = '${stableId}_role_band_test';
      final eventName = 'sleuth.issue.$stableId.$severityLabel';
      final wrapped = <String, Object?>{
        'sleuthMetadata': <String, Object?>{
          'scenario': scenarioName,
          'role': 'at',
        },
        'traceEvents': <Map<String, Object?>>[
          {
            'name': 'sleuth.scenario.begin',
            'ph': 'i',
            'ts': 1000,
            'pid': 1,
            'tid': 1,
            'args': {'name': scenarioName},
          },
          {
            'name': eventName,
            'ph': 'i',
            'ts': 2000,
            'pid': 1,
            'tid': 1,
            'args': {
              'detectedAtMicros': '2000',
              axisKey: detectorValue.toString(),
            },
          },
          {
            'name': 'sleuth.scenario.end',
            'ph': 'i',
            'ts': 3000,
            'pid': 1,
            'tid': 1,
            'args': {'name': scenarioName},
          },
        ],
      };
      final f = File(p.join(dir.path, filename))
        ..createSync(recursive: true)
        ..writeAsStringSync(jsonEncode(wrapped));
      return f;
    }

    Directory makeTempRoot() {
      final dir = Directory.systemTemp.createTempSync('detector_role_band_');
      File(p.join(dir.path, 'pubspec.yaml'))
          .writeAsStringSync('name: stub\nversion: 0.0.1\n');
      return dir;
    }

    test('detector value inside at-band → passes', () {
      final root = makeTempRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      writeCaptureFixture(
        root,
        filename: 'below.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        // below: detector silent (no in-span issue event would carry
        // axis); satisfy the iteration by stamping a sub-threshold
        // value the invariant skips silently for below role anyway.
        detectorValue: 100000,
      );
      writeCaptureFixture(
        root,
        filename: 'at.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        detectorValue: 600000, // in [512000, 768000] for tol=0.50
      );
      writeCaptureFixture(
        root,
        filename: 'above.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        detectorValue: 900000, // > atUpper 768000, ≤ ceiling 1024000
      );
      final failures = checkDetectorAxisInRoleBand(
        label: 'TestDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'heap_growing',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedSlopeBytesPerSec',
        topLevelCapturePaths: const ['below.json', 'at.json', 'above.json'],
        topLevelBracketThreshold: 512000,
        topLevelAtTolerance: 0.50,
        topLevelAboveCeilingMultiplier: 2.0,
        topLevelObservedAxisReduction: 'max',
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: 'detector values in role bands must pass: $failures');
    });

    test(
        'detector value above at-band when role=at → fails (memory at-leg '
        'regression)', () {
      final root = makeTempRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      writeCaptureFixture(
        root,
        filename: 'below.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        detectorValue: 100000,
      );
      writeCaptureFixture(
        root,
        filename: 'at.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        // 897292 lands in above-band (>768000) — the v0.19.19 mislabel
        // this invariant exists to catch.
        detectorValue: 897292,
      );
      writeCaptureFixture(
        root,
        filename: 'above.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        detectorValue: 920000,
      );
      final failures = checkDetectorAxisInRoleBand(
        label: 'MemoryPressureDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'heap_growing',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedSlopeBytesPerSec',
        topLevelCapturePaths: const ['below.json', 'at.json', 'above.json'],
        topLevelBracketThreshold: 512000,
        topLevelAtTolerance: 0.50,
        topLevelAboveCeilingMultiplier: 2.0,
        topLevelObservedAxisReduction: 'max',
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty);
      expect(failures.first, contains('at capture'));
      expect(failures.first, contains('897292'));
      expect(failures.first, contains('outside at-band'));
    });

    test(
        'detector value inside at-band when role=above → fails (platform '
        'above-leg regression)', () {
      final root = makeTempRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      writeCaptureFixture(
        root,
        filename: 'below.json',
        stableId: 'platform_channel_traffic',
        severityLabel: 'warning',
        axisKey: 'observedCount',
        detectorValue: 5,
      );
      writeCaptureFixture(
        root,
        filename: 'at.json',
        stableId: 'platform_channel_traffic',
        severityLabel: 'warning',
        axisKey: 'observedCount',
        detectorValue: 25,
      );
      writeCaptureFixture(
        root,
        filename: 'above.json',
        stableId: 'platform_channel_traffic',
        severityLabel: 'warning',
        axisKey: 'observedCount',
        // 28 ≤ atUpper (30) — the platform above-leg mislabel pattern.
        detectorValue: 28,
      );
      final failures = checkDetectorAxisInRoleBand(
        label: 'PlatformChannelDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'platform_channel_traffic',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedCount',
        topLevelCapturePaths: const ['below.json', 'at.json', 'above.json'],
        topLevelBracketThreshold: 20,
        topLevelAtTolerance: 0.50,
        topLevelAboveCeilingMultiplier: 1.95,
        topLevelObservedAxisReduction: 'max',
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty);
      expect(failures.first, contains('above capture'));
      expect(failures.first, contains('28'));
      expect(failures.first, contains('at-band'));
    });

    test('detector value below threshold when role=at → fails', () {
      final root = makeTempRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      writeCaptureFixture(
        root,
        filename: 'below.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        detectorValue: 100000,
      );
      writeCaptureFixture(
        root,
        filename: 'at.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        // 400000 < threshold 512000 — at-leg detector should be ≥ T.
        detectorValue: 400000,
      );
      writeCaptureFixture(
        root,
        filename: 'above.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        detectorValue: 920000,
      );
      final failures = checkDetectorAxisInRoleBand(
        label: 'MemoryPressureDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'heap_growing',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedSlopeBytesPerSec',
        topLevelCapturePaths: const ['below.json', 'at.json', 'above.json'],
        topLevelBracketThreshold: 512000,
        topLevelAtTolerance: 0.50,
        topLevelAboveCeilingMultiplier: 2.0,
        topLevelObservedAxisReduction: 'max',
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty);
      expect(failures.first, contains('at capture'));
      expect(failures.first, contains('400000'));
    });

    test(
        'missing axis arg on every in-span event → role-band invariant '
        'rejects (defense-in-depth alongside checkCapturesCarryObservedAxisArg)',
        () {
      final root = makeTempRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      // Capture file with no axis arg in the issue event. The role-
      // band invariant rejects defensively: matchCount > 0 but
      // samples.length == 0 means a producer regression on every
      // emission path. checkCapturesCarryObservedAxisArg also catches
      // this; both invariants reject so the failure surfaces even if
      // one of them is bypassed via allowlist drift or refactor.
      final scenarioName = 'heap_growing_role_band_test';
      const eventName = 'sleuth.issue.heap_growing.warning';
      final wrapped = <String, Object?>{
        'sleuthMetadata': const <String, Object?>{
          'scenario': 'heap_growing_role_band_test',
          'role': 'at',
        },
        'traceEvents': <Map<String, Object?>>[
          {
            'name': 'sleuth.scenario.begin',
            'ph': 'i',
            'ts': 1000,
            'pid': 1,
            'tid': 1,
            'args': {'name': scenarioName},
          },
          {
            'name': eventName,
            'ph': 'i',
            'ts': 2000,
            'pid': 1,
            'tid': 1,
            'args': {'detectedAtMicros': '2000'},
          },
          {
            'name': 'sleuth.scenario.end',
            'ph': 'i',
            'ts': 3000,
            'pid': 1,
            'tid': 1,
            'args': {'name': scenarioName},
          },
        ],
      };
      File(p.join(root.path, 'at.json')).writeAsStringSync(jsonEncode(wrapped));
      File(p.join(root.path, 'below.json'))
          .writeAsStringSync(jsonEncode(wrapped));
      File(p.join(root.path, 'above.json'))
          .writeAsStringSync(jsonEncode(wrapped));
      final failures = checkDetectorAxisInRoleBand(
        label: 'MemoryPressureDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'heap_growing',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedSlopeBytesPerSec',
        topLevelCapturePaths: const ['below.json', 'at.json', 'above.json'],
        topLevelBracketThreshold: 512000,
        topLevelAtTolerance: 0.50,
        topLevelAboveCeilingMultiplier: 2.0,
        topLevelObservedAxisReduction: 'max',
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'role-band invariant must reject when matchCount > 0 '
              'but every event lacks the axis arg (defense-in-depth).');
      expect(failures.first, contains('only 0 carry'));
      expect(failures.first, contains('1 unstamped'));
    });

    test(
        "observedAxisReduction='last' picks the chronologically-last sample, "
        'not the numerical max', () {
      final root = Directory.systemTemp.createTempSync('detector_role_band_');
      addTearDown(() => root.deleteSync(recursive: true));
      File(p.join(root.path, 'pubspec.yaml'))
          .writeAsStringSync('name: stub\nversion: 0.0.1\n');
      // Multi-event in-span capture: ts ascending, value non-monotone.
      // For 'last' reduction the invariant must take ts=300 → value 25
      // (in at-band [20, 30]). For 'max' it would take 50 (out-of-band).
      // The test asserts 'last' picks 25 and passes; flipping to 'max'
      // in the same fixture would reject.
      const scenarioName = 'jank_detected_role_band_test';
      const eventName = 'sleuth.issue.jank_detected.warning';
      final wrapped = <String, Object?>{
        'sleuthMetadata': const <String, Object?>{
          'scenario': 'jank_detected_role_band_test',
          'role': 'at',
        },
        'traceEvents': <Map<String, Object?>>[
          {
            'name': 'sleuth.scenario.begin',
            'ph': 'i',
            'ts': 100,
            'pid': 1,
            'tid': 1,
            'args': {'name': scenarioName},
          },
          {
            'name': eventName,
            'ph': 'i',
            'ts': 200,
            'pid': 1,
            'tid': 1,
            'args': {'detectedAtMicros': '200', 'observedJankPercent': '50'},
          },
          {
            'name': eventName,
            'ph': 'i',
            'ts': 300,
            'pid': 1,
            'tid': 1,
            'args': {'detectedAtMicros': '300', 'observedJankPercent': '25'},
          },
          {
            'name': 'sleuth.scenario.end',
            'ph': 'i',
            'ts': 400,
            'pid': 1,
            'tid': 1,
            'args': {'name': scenarioName},
          },
        ],
      };
      // At-leg: multi-event fixture with non-monotone-by-ts values
      // (the test target). Below: empty (detector silent). Above:
      // single in-band event with value 35 (in (30, 40] above-band).
      File(p.join(root.path, 'at.json')).writeAsStringSync(jsonEncode(wrapped));
      final emptyBelow = <String, Object?>{
        'sleuthMetadata': const <String, Object?>{
          'scenario': 'jank_detected_below',
          'role': 'below',
        },
        'traceEvents': const <Map<String, Object?>>[],
      };
      File(p.join(root.path, 'below.json'))
          .writeAsStringSync(jsonEncode(emptyBelow));
      final aboveFixture = <String, Object?>{
        'sleuthMetadata': const <String, Object?>{
          'scenario': 'jank_detected_above',
          'role': 'above',
        },
        'traceEvents': <Map<String, Object?>>[
          {
            'name': 'sleuth.scenario.begin',
            'ph': 'i',
            'ts': 100,
            'pid': 1,
            'tid': 1,
            'args': {'name': 'jank_detected_above'},
          },
          {
            'name': eventName,
            'ph': 'i',
            'ts': 200,
            'pid': 1,
            'tid': 1,
            'args': {'detectedAtMicros': '200', 'observedJankPercent': '35'},
          },
          {
            'name': 'sleuth.scenario.end',
            'ph': 'i',
            'ts': 300,
            'pid': 1,
            'tid': 1,
            'args': {'name': 'jank_detected_above'},
          },
        ],
      };
      File(p.join(root.path, 'above.json'))
          .writeAsStringSync(jsonEncode(aboveFixture));
      final lastFailures = checkDetectorAxisInRoleBand(
        label: 'FrameTimingDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'jank_detected',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedJankPercent',
        topLevelCapturePaths: const ['below.json', 'at.json', 'above.json'],
        topLevelBracketThreshold: 20,
        topLevelAtTolerance: 0.50,
        topLevelAboveCeilingMultiplier: 2.0,
        topLevelObservedAxisReduction: 'last',
        repoRoot: root.path,
      );
      expect(lastFailures, isEmpty,
          reason: "'last' reduction must pick chronologically-last sample "
              'on at-leg (ts=300 → 25, in at-band); failures: $lastFailures');
      final maxFailures = checkDetectorAxisInRoleBand(
        label: 'FrameTimingDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'jank_detected',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedJankPercent',
        topLevelCapturePaths: const ['below.json', 'at.json', 'above.json'],
        topLevelBracketThreshold: 20,
        topLevelAtTolerance: 0.50,
        topLevelAboveCeilingMultiplier: 2.0,
        topLevelObservedAxisReduction: 'max',
        repoRoot: root.path,
      );
      expect(maxFailures, isNotEmpty,
          reason: "'max' reduction picks 50 (out of at-band [20, 30]) on the "
              'same at-leg fixture; sanity check that the reduction '
              'strategy meaningfully changes the verdict.');
    });

    test('additionalBrackets entry exercises invariant via spec.threshold', () {
      final root = Directory.systemTemp.createTempSync('detector_role_band_');
      addTearDown(() => root.deleteSync(recursive: true));
      File(p.join(root.path, 'pubspec.yaml'))
          .writeAsStringSync('name: stub\nversion: 0.0.1\n');
      // Construct an additionalBrackets entry mirroring the
      // HeavyComputeDetector critical-tier shape (threshold 16,
      // atTolerance 0.60 → at-band [16, 25.6], above-ceiling 1.875 →
      // above-band (25.6, 30]). Stamp an at-leg detector value of 19
      // (in-band) and an above-leg value of 18 (in at-band → fails
      // role=above check).
      const scenarioBase = 'heavy_compute_critical';
      const eventName = 'sleuth.issue.heavy_compute.critical';
      Map<String, Object?> wrappedFor(double detector, String roleLabel) =>
          <String, Object?>{
            'sleuthMetadata': <String, Object?>{
              'scenario': '${scenarioBase}_$roleLabel',
              'role': roleLabel,
            },
            'traceEvents': <Map<String, Object?>>[
              {
                'name': 'sleuth.scenario.begin',
                'ph': 'i',
                'ts': 100,
                'pid': 1,
                'tid': 1,
                'args': {'name': '${scenarioBase}_$roleLabel'},
              },
              {
                'name': eventName,
                'ph': 'i',
                'ts': 200,
                'pid': 1,
                'tid': 1,
                'args': {
                  'detectedAtMicros': '200',
                  'observedDurationMs': detector.toString(),
                },
              },
              {
                'name': 'sleuth.scenario.end',
                'ph': 'i',
                'ts': 300,
                'pid': 1,
                'tid': 1,
                'args': {'name': '${scenarioBase}_$roleLabel'},
              },
            ],
          };
      File(p.join(root.path, 'crit_below.json'))
          .writeAsStringSync(jsonEncode(wrappedFor(8, 'below')));
      File(p.join(root.path, 'crit_at.json'))
          .writeAsStringSync(jsonEncode(wrappedFor(19, 'at')));
      File(p.join(root.path, 'crit_above.json'))
          .writeAsStringSync(jsonEncode(wrappedFor(18, 'above')));
      final spec = BracketSpec(
        stableId: 'heavy_compute',
        severityLabel: 'critical',
        threshold: 16,
        unit: 'ms',
        coveredThresholds: const {'heavy_compute.critical'},
        profileCapturePaths: const [
          'crit_below.json',
          'crit_at.json',
          'crit_above.json',
        ],
        atTolerance: 0.60,
        aboveCeilingMultiplier: 1.875,
        observedAxisArgKey: 'observedDurationMs',
      );
      final failures = checkDetectorAxisInRoleBand(
        label: 'HeavyComputeDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: null,
        topLevelSeverityLabel: null,
        topLevelObservedAxisArgKey: null,
        topLevelCapturePaths: null,
        topLevelBracketThreshold: null,
        topLevelAtTolerance: null,
        topLevelAboveCeilingMultiplier: null,
        topLevelObservedAxisReduction: 'max',
        additionalBrackets: [spec],
        repoRoot: root.path,
      );
      expect(failures, isNotEmpty,
          reason: 'above-leg detector value 18 is ≤ at-band upper 25.6; '
              'invariant must surface via additionalBrackets[0] path.');
      expect(failures.first, contains('additionalBrackets[0]'));
      expect(failures.first, contains('above capture'));
      expect(failures.first, contains('18'));
    });

    test(
        'partial axis stamping (carrying < matched) fails with both '
        'invariants', () {
      final root = Directory.systemTemp.createTempSync('detector_role_band_');
      addTearDown(() => root.deleteSync(recursive: true));
      File(p.join(root.path, 'pubspec.yaml'))
          .writeAsStringSync('name: stub\nversion: 0.0.1\n');
      // 2 in-span heap_growing.warning events; first carries the axis
      // arg, second omits it. checkCapturesCarryObservedAxisArg used to
      // pass here (carrying=1 > 0); checkDetectorAxisInRoleBand used to
      // reduce over the parseable subset. Both must now reject so a
      // producer regression on one emission path can't ride on a
      // stamped sibling's in-band reduction.
      const scenarioName = 'heap_growing_at';
      const eventName = 'sleuth.issue.heap_growing.warning';
      final wrapped = <String, Object?>{
        'sleuthMetadata': const <String, Object?>{
          'scenario': 'heap_growing_at',
          'role': 'at',
        },
        'traceEvents': <Map<String, Object?>>[
          {
            'name': 'sleuth.scenario.begin',
            'ph': 'i',
            'ts': 100,
            'pid': 1,
            'tid': 1,
            'args': {'name': scenarioName},
          },
          {
            'name': eventName,
            'ph': 'i',
            'ts': 200,
            'pid': 1,
            'tid': 1,
            'args': {
              'detectedAtMicros': '200',
              'observedSlopeBytesPerSec': '600000',
            },
          },
          {
            'name': eventName,
            'ph': 'i',
            'ts': 300,
            'pid': 1,
            'tid': 1,
            'args': {'detectedAtMicros': '300'},
          },
          {
            'name': 'sleuth.scenario.end',
            'ph': 'i',
            'ts': 400,
            'pid': 1,
            'tid': 1,
            'args': {'name': scenarioName},
          },
        ],
      };
      final emptyAbove = <String, Object?>{
        'sleuthMetadata': const <String, Object?>{
          'scenario': 'heap_growing_above',
          'role': 'above',
        },
        'traceEvents': const <Map<String, Object?>>[],
      };
      final emptyBelow = <String, Object?>{
        'sleuthMetadata': const <String, Object?>{
          'scenario': 'heap_growing_below',
          'role': 'below',
        },
        'traceEvents': const <Map<String, Object?>>[],
      };
      File(p.join(root.path, 'at.json')).writeAsStringSync(jsonEncode(wrapped));
      File(p.join(root.path, 'above.json'))
          .writeAsStringSync(jsonEncode(emptyAbove));
      File(p.join(root.path, 'below.json'))
          .writeAsStringSync(jsonEncode(emptyBelow));

      final fidelityFailures = checkCapturesCarryObservedAxisArg(
        label: 'MemoryPressureDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'heap_growing',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedSlopeBytesPerSec',
        topLevelCapturePaths: const ['below.json', 'at.json', 'above.json'],
        repoRoot: root.path,
      );
      expect(fidelityFailures, isNotEmpty,
          reason: 'carrying=1 < matched=2 must surface; subset proof '
              'rejected.');
      expect(fidelityFailures.first, contains('only 1 carry'));
      expect(fidelityFailures.first, contains('1 unstamped'));
      expect(fidelityFailures.first, contains('Full coverage is required'));

      final roleBandFailures = checkDetectorAxisInRoleBand(
        label: 'MemoryPressureDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'heap_growing',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedSlopeBytesPerSec',
        topLevelCapturePaths: const ['below.json', 'at.json', 'above.json'],
        topLevelBracketThreshold: 512000,
        topLevelAtTolerance: 0.50,
        topLevelAboveCeilingMultiplier: 2.0,
        topLevelObservedAxisReduction: 'max',
        repoRoot: root.path,
      );
      expect(roleBandFailures, isNotEmpty,
          reason: 'Defense-in-depth: role-band invariant must also '
              'reject the partial-coverage capture even though the '
              'parseable single sample (600000) lands in band.');
      expect(roleBandFailures.first, contains('only 1 carry'));
      expect(roleBandFailures.first, contains('1 unstamped'));
    });

    test(
        "tied-ts samples under 'last' reduction resolve by insertion "
        'order (deterministic)', () {
      final root = Directory.systemTemp.createTempSync('detector_role_band_');
      addTearDown(() => root.deleteSync(recursive: true));
      File(p.join(root.path, 'pubspec.yaml'))
          .writeAsStringSync('name: stub\nversion: 0.0.1\n');
      // Two in-span events at the SAME ts. The second-written event
      // wins under 'last' because insertion order is the deterministic
      // tiebreaker. First event stamps a value (50) that would fall
      // OUT of the at-band [20, 30]; second event stamps an in-band
      // value (25). 'last' must pick the second (25, in-band). If the
      // tiebreaker were unspecified the test could pick either and
      // sometimes flake.
      const scenarioName = 'jank_detected_at';
      const eventName = 'sleuth.issue.jank_detected.warning';
      final atFixture = <String, Object?>{
        'sleuthMetadata': const <String, Object?>{
          'scenario': 'jank_detected_at',
          'role': 'at',
        },
        'traceEvents': <Map<String, Object?>>[
          {
            'name': 'sleuth.scenario.begin',
            'ph': 'i',
            'ts': 100,
            'pid': 1,
            'tid': 1,
            'args': {'name': scenarioName},
          },
          {
            'name': eventName,
            'ph': 'i',
            'ts': 200,
            'pid': 1,
            'tid': 1,
            'args': {'detectedAtMicros': '200a', 'observedJankPercent': '50'},
          },
          {
            'name': eventName,
            'ph': 'i',
            'ts': 200,
            'pid': 1,
            'tid': 1,
            'args': {'detectedAtMicros': '200b', 'observedJankPercent': '25'},
          },
          {
            'name': 'sleuth.scenario.end',
            'ph': 'i',
            'ts': 300,
            'pid': 1,
            'tid': 1,
            'args': {'name': scenarioName},
          },
        ],
      };
      final aboveFixture = <String, Object?>{
        'sleuthMetadata': const <String, Object?>{
          'scenario': 'jank_detected_above',
          'role': 'above',
        },
        'traceEvents': <Map<String, Object?>>[
          {
            'name': 'sleuth.scenario.begin',
            'ph': 'i',
            'ts': 100,
            'pid': 1,
            'tid': 1,
            'args': {'name': 'jank_detected_above'},
          },
          {
            'name': eventName,
            'ph': 'i',
            'ts': 200,
            'pid': 1,
            'tid': 1,
            'args': {'detectedAtMicros': '200', 'observedJankPercent': '35'},
          },
          {
            'name': 'sleuth.scenario.end',
            'ph': 'i',
            'ts': 300,
            'pid': 1,
            'tid': 1,
            'args': {'name': 'jank_detected_above'},
          },
        ],
      };
      final emptyBelow = <String, Object?>{
        'sleuthMetadata': const <String, Object?>{
          'scenario': 'jank_detected_below',
          'role': 'below',
        },
        'traceEvents': const <Map<String, Object?>>[],
      };
      File(p.join(root.path, 'at.json'))
          .writeAsStringSync(jsonEncode(atFixture));
      File(p.join(root.path, 'above.json'))
          .writeAsStringSync(jsonEncode(aboveFixture));
      File(p.join(root.path, 'below.json'))
          .writeAsStringSync(jsonEncode(emptyBelow));

      final failures = checkDetectorAxisInRoleBand(
        label: 'FrameTimingDetector (tier=runtimeVerified)',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: 'jank_detected',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedJankPercent',
        topLevelCapturePaths: const ['below.json', 'at.json', 'above.json'],
        topLevelBracketThreshold: 20,
        topLevelAtTolerance: 0.50,
        topLevelAboveCeilingMultiplier: 2.0,
        topLevelObservedAxisReduction: 'last',
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: "tied-ts 'last' reduction must pick second-inserted "
              'sample (value 25, in at-band [20, 30]); insertion-order '
              'tiebreaker pins the choice deterministically. failures: '
              '$failures');
    });

    test('reproducerOnly tier → no-op regardless of capture state', () {
      final root = makeTempRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      writeCaptureFixture(
        root,
        filename: 'at.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        // Out-of-band but tier gate must skip.
        detectorValue: 50,
      );
      writeCaptureFixture(
        root,
        filename: 'below.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        detectorValue: 50,
      );
      writeCaptureFixture(
        root,
        filename: 'above.json',
        stableId: 'heap_growing',
        severityLabel: 'warning',
        axisKey: 'observedSlopeBytesPerSec',
        detectorValue: 50,
      );
      final failures = checkDetectorAxisInRoleBand(
        label: 'TestDetector (tier=reproducerOnly)',
        tier: EvidenceTier.reproducerOnly,
        topLevelStableId: 'heap_growing',
        topLevelSeverityLabel: 'warning',
        topLevelObservedAxisArgKey: 'observedSlopeBytesPerSec',
        topLevelCapturePaths: const ['below.json', 'at.json', 'above.json'],
        topLevelBracketThreshold: 512000,
        topLevelAtTolerance: 0.50,
        topLevelAboveCeilingMultiplier: 2.0,
        topLevelObservedAxisReduction: 'max',
        repoRoot: root.path,
      );
      expect(failures, isEmpty,
          reason: 'reproducerOnly tier must not exercise the invariant.');
    });
  });

  group('checkLegacyObservedAxisManifest (v0.19.18)', () {
    test('expired entry (currentVersion >= consumeBy) fails', () {
      final failures = checkLegacyObservedAxisManifest(
        manifest: const {
          'X:foo:warning': LegacyObservedAxisEntry(
            consumeBy: '0.21.0',
            owningClaim: 'foo cross-check re-record',
            rationale: 'test',
          ),
        },
        currentReleaseVersion: '0.21.0',
      );
      expect(failures, hasLength(1));
      expect(failures.single, contains('"X:foo:warning"'));
      expect(failures.single, contains('consumeBy "0.21.0"'));
      expect(failures.single, contains('expired'));
    });

    test('non-expired entry (currentVersion < consumeBy) passes', () {
      final failures = checkLegacyObservedAxisManifest(
        manifest: const {
          'X:foo:warning': LegacyObservedAxisEntry(
            consumeBy: '0.21.0',
            owningClaim: 'foo cross-check re-record',
            rationale: 'test',
          ),
        },
        currentReleaseVersion: '0.19.18',
      );
      expect(failures, isEmpty);
    });
  });

  group('checkMinInBandSamplesPerSpec', () {
    // Build a synthetic capture JSON file at the given path with a
    // scenario span and N issue events whose `args.observedRebuildRate`
    // values are taken from `rates`. Used to drive the invariant
    // through controlled in-band / sub-band counts. `findScenarioSpan`
    // requires exactly one scenario.begin + scenario.end pair.
    void writeSyntheticCapture({
      required String filePath,
      required String stableId,
      required String severityLabel,
      required String argKey,
      required List<num> rates,
      String scenario = 'synthetic',
    }) {
      final events = <Map<String, Object?>>[
        {
          'name': 'sleuth.scenario.begin',
          'ph': 'i',
          's': 'p',
          'ts': 1000,
          'args': {'scenario': scenario},
        },
      ];
      var ts = 1100;
      for (final rate in rates) {
        events.add({
          'name': 'sleuth.issue.$stableId.$severityLabel',
          'ph': 'i',
          's': 'p',
          'ts': ts,
          'args': {argKey: rate.toString()},
        });
        ts += 100;
      }
      events.add({
        'name': 'sleuth.scenario.end',
        'ph': 'i',
        's': 'p',
        'ts': ts + 100,
        'args': {'scenario': scenario},
      });
      File(filePath).writeAsStringSync(json.encode({'traceEvents': events}));
    }

    Directory makeRepoRoot() {
      final root = Directory.systemTemp.createTempSync('min_in_band_');
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: test');
      return root;
    }

    BracketSpec spec({
      required List<String> capturePaths,
      int? minInBandSamples,
      String severityLabel = 'critical',
      double atTolerance = 0.65,
      double aboveCeilingMultiplier = 2.7,
      num threshold = 31,
    }) {
      return BracketSpec(
        stableId: 'rebuild_activity',
        severityLabel: severityLabel,
        threshold: threshold,
        unit: 'rebuilds',
        coveredThresholds: {'rebuild_activity.$severityLabel'},
        profileCapturePaths: capturePaths,
        atTolerance: atTolerance,
        aboveCeilingMultiplier: aboveCeilingMultiplier,
        observedAxisArgKey: 'observedRebuildRate',
        observedAxisReduction: 'max',
        minInBandSamples: minInBandSamples,
      );
    }

    test('null minInBandSamples skips the check (opt-in default)', () {
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      // 0 in-band events would normally fail; null = no enforcement.
      writeSyntheticCapture(
        filePath: p.join(root.path, 'at.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [10, 20], // both below threshold 31
      );
      writeSyntheticCapture(
        filePath: p.join(root.path, 'above.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [10], // below threshold
      );
      final failures = checkMinInBandSamplesPerSpec(
        label: 'X',
        tier: EvidenceTier.runtimeVerified,
        additionalBrackets: [
          spec(capturePaths: [
            'below.json',
            'at.json',
            'above.json',
          ]),
        ],
        repoRoot: root.path,
      );
      expect(failures, isEmpty);
    });

    test('fails when in-band count < minInBandSamples', () {
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      // at-leg: 1 in-band (40 ∈ [31,51]), 2 sub-band.
      writeSyntheticCapture(
        filePath: p.join(root.path, 'at.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [40, 20, 25],
      );
      // above-leg: 1 in-band (70 ∈ (51,83]), 2 sub-band.
      writeSyntheticCapture(
        filePath: p.join(root.path, 'above.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [70, 30, 25],
      );
      final failures = checkMinInBandSamplesPerSpec(
        label: 'X',
        tier: EvidenceTier.runtimeVerified,
        additionalBrackets: [
          spec(
            capturePaths: ['below.json', 'at.json', 'above.json'],
            minInBandSamples: 2,
          ),
        ],
        repoRoot: root.path,
      );
      // Both legs fail (per-leg semantics).
      expect(failures.length, equals(2));
      expect(
          failures.any((f) => f.contains('at-leg') && f.contains('1')), isTrue);
      expect(failures.any((f) => f.contains('above-leg') && f.contains('1')),
          isTrue);
    });

    test('passes at boundary count == minInBandSamples', () {
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      writeSyntheticCapture(
        filePath: p.join(root.path, 'at.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [35, 40], // exactly 2 in-band
      );
      writeSyntheticCapture(
        filePath: p.join(root.path, 'above.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [60, 70], // exactly 2 in-band
      );
      final failures = checkMinInBandSamplesPerSpec(
        label: 'X',
        tier: EvidenceTier.runtimeVerified,
        additionalBrackets: [
          spec(
            capturePaths: ['below.json', 'at.json', 'above.json'],
            minInBandSamples: 2,
          ),
        ],
        repoRoot: root.path,
      );
      expect(failures, isEmpty);
    });

    test('passes when in-band count > minInBandSamples', () {
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      writeSyntheticCapture(
        filePath: p.join(root.path, 'at.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [35, 40, 45, 50], // 4 in-band
      );
      writeSyntheticCapture(
        filePath: p.join(root.path, 'above.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [55, 60, 70, 80], // 4 in-band
      );
      final failures = checkMinInBandSamplesPerSpec(
        label: 'X',
        tier: EvidenceTier.runtimeVerified,
        additionalBrackets: [
          spec(
            capturePaths: ['below.json', 'at.json', 'above.json'],
            minInBandSamples: 2,
          ),
        ],
        repoRoot: root.path,
      );
      expect(failures, isEmpty);
    });

    test('per-leg semantics: 1 in-band per leg fails for both legs', () {
      // Sum across legs would be 2 (spuriously passing min=2). Per-leg
      // semantics catches this.
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      writeSyntheticCapture(
        filePath: p.join(root.path, 'at.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [40], // 1 in-band
      );
      writeSyntheticCapture(
        filePath: p.join(root.path, 'above.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [70], // 1 in-band
      );
      final failures = checkMinInBandSamplesPerSpec(
        label: 'X',
        tier: EvidenceTier.runtimeVerified,
        additionalBrackets: [
          spec(
            capturePaths: ['below.json', 'at.json', 'above.json'],
            minInBandSamples: 2,
          ),
        ],
        repoRoot: root.path,
      );
      expect(failures.length, equals(2));
    });

    test('cross-role: at-band events do not satisfy above-leg requirement', () {
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      // at-leg: 2 in-band events (passes its own check).
      writeSyntheticCapture(
        filePath: p.join(root.path, 'at.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [40, 45],
      );
      // above-leg: events fall in at-band [31, 51], NOT above-band
      // (51, 83]. above-leg has 0 in-band events.
      writeSyntheticCapture(
        filePath: p.join(root.path, 'above.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [40, 45],
      );
      final failures = checkMinInBandSamplesPerSpec(
        label: 'X',
        tier: EvidenceTier.runtimeVerified,
        additionalBrackets: [
          spec(
            capturePaths: ['below.json', 'at.json', 'above.json'],
            minInBandSamples: 2,
          ),
        ],
        repoRoot: root.path,
      );
      expect(failures.length, equals(1));
      expect(failures.first, contains('above-leg'));
      expect(failures.first, contains('0 in-band'));
    });

    test('at-band inclusive lower boundary (sample at threshold)', () {
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      writeSyntheticCapture(
        filePath: p.join(root.path, 'at.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [31, 32], // 31 == threshold; both in at-band
      );
      writeSyntheticCapture(
        filePath: p.join(root.path, 'above.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [60, 70],
      );
      final failures = checkMinInBandSamplesPerSpec(
        label: 'X',
        tier: EvidenceTier.runtimeVerified,
        additionalBrackets: [
          spec(
            capturePaths: ['below.json', 'at.json', 'above.json'],
            minInBandSamples: 2,
          ),
        ],
        repoRoot: root.path,
      );
      expect(failures, isEmpty);
    });

    test('at-band inclusive upper boundary (51 in at-band, 52 in above-band)',
        () {
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      // at-band upper for threshold 31, atTolerance 0.65 = 51.15.
      // 51 ∈ at-band; 52 ∈ above-band.
      writeSyntheticCapture(
        filePath: p.join(root.path, 'at.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [51, 51], // both at upper boundary, in at-band
      );
      writeSyntheticCapture(
        filePath: p.join(root.path, 'above.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [52, 52], // both at first integer past upper, in above-band
      );
      final failures = checkMinInBandSamplesPerSpec(
        label: 'X',
        tier: EvidenceTier.runtimeVerified,
        additionalBrackets: [
          spec(
            capturePaths: ['below.json', 'at.json', 'above.json'],
            minInBandSamples: 2,
          ),
        ],
        repoRoot: root.path,
      );
      expect(failures, isEmpty);
    });

    test('above-band inclusive ceiling boundary (83 in, 84 over)', () {
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      // above-ceiling = 31 * 2.7 = 83.7. 83 ∈ above-band; 84 over.
      writeSyntheticCapture(
        filePath: p.join(root.path, 'at.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [40, 45],
      );
      writeSyntheticCapture(
        filePath: p.join(root.path, 'above.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [83, 84], // 83 in-band; 84 over-ceiling
      );
      final failures = checkMinInBandSamplesPerSpec(
        label: 'X',
        tier: EvidenceTier.runtimeVerified,
        additionalBrackets: [
          spec(
            capturePaths: ['below.json', 'at.json', 'above.json'],
            minInBandSamples: 2,
          ),
        ],
        repoRoot: root.path,
      );
      // above-leg has only 1 in-band (83); 84 is over-ceiling, not in.
      expect(failures.length, equals(1));
      expect(failures.first, contains('above-leg'));
    });

    test('real-capture fixture: critical_above.json passes invariant', () {
      // End-to-end format-contract verification using the real
      // committed capture, not synthetic JSON. If RebuildDetector's
      // emission format ever drifts (arg name, value type, scenario
      // marker shape), this test catches it before audit gate fires.
      // Relative path requires CWD = package root; assert explicitly so
      // a non-standard runner cwd skips loudly instead of misleading.
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final realCapture = File(
        'test/validation/captures/rebuild_detector/critical_above.json',
      );
      if (!realCapture.existsSync()) {
        markTestSkipped('critical_above.json not present');
        return;
      }
      // Use the actual project root so the relative path resolves.
      final failures = checkMinInBandSamplesPerSpec(
        label: 'RebuildDetector',
        tier: EvidenceTier.runtimeVerified,
        additionalBrackets: [
          spec(
            capturePaths: const [
              'test/validation/captures/rebuild_detector/critical_below.json',
              'test/validation/captures/rebuild_detector/critical_at.json',
              'test/validation/captures/rebuild_detector/critical_above.json',
            ],
            minInBandSamples: 2,
          ),
        ],
        // No repoRoot override — uses Directory.current which the test
        // runner sets to the package root.
      );
      expect(failures, isEmpty,
          reason: 'committed critical_above.json must satisfy '
              'minInBandSamples=2; if this fails, either the capture '
              'regressed below 2 in-band emissions or the invariant '
              'misclassifies real captures.');
    });

    test('skips when capture file missing (delegated to other invariants)', () {
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      // No capture files written — paths point to non-existent files.
      final failures = checkMinInBandSamplesPerSpec(
        label: 'X',
        tier: EvidenceTier.runtimeVerified,
        additionalBrackets: [
          spec(
            capturePaths: ['below.json', 'at.json', 'above.json'],
            minInBandSamples: 2,
          ),
        ],
        repoRoot: root.path,
      );
      // Silent skip — checkAdditionalBrackets enforces existence.
      expect(failures, isEmpty);
    });

    test('runRuntimeTierAudit wires checkMinInBandSamplesPerSpec end-to-end',
        () {
      // Behavioral wire test: build a synthetic DetectorMetadata whose
      // additionalBrackets[0] carries minInBandSamples=2, write captures
      // with only 1 in-band sample per leg, route through
      // runRuntimeTierAudit, and assert the failure list contains the
      // minInBandSamples-specific message. Indirection-proof: a refactor
      // that extracts the call into a helper, gates it conditionally,
      // or removes it entirely all break this test, while the 12 unit
      // tests above (which invoke checkMinInBandSamplesPerSpec directly)
      // continue to pass.
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      writeSyntheticCapture(
        filePath: p.join(root.path, 'below.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [20], // below-leg silent by convention.
      );
      writeSyntheticCapture(
        filePath: p.join(root.path, 'at.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [40, 20, 25], // 1 in-band (40 ∈ [31, 51]), needs 2.
      );
      writeSyntheticCapture(
        filePath: p.join(root.path, 'above.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [70, 30, 25], // 1 in-band (70 ∈ (51, 83]), needs 2.
      );
      final meta = DetectorMetadata(
        tier: EvidenceTier.runtimeVerified,
        rationale: 'Synthetic metadata for behavioral wire verification.',
        reproducerPath: 'test/validation/_support/audit_invariants_test.dart',
        coveredStableIds: const {'rebuild_activity'},
        coveredThresholds: const {'rebuild_activity.critical'},
        additionalBrackets: [
          spec(
            capturePaths: ['below.json', 'at.json', 'above.json'],
            minInBandSamples: 2,
          ),
        ],
      );
      final failures = runRuntimeTierAudit(
        label: 'WireTest',
        meta: meta,
        repoRoot: root.path,
      );
      expect(
        failures.any((f) => f.contains('minInBandSamples=2')),
        isTrue,
        reason: 'runRuntimeTierAudit must invoke '
            'checkMinInBandSamplesPerSpec so the contract reaches the '
            'top-level audit gate. Removing, commenting out, or '
            'conditionally gating the wire turns every opt-in spec into '
            'a silent no-op.',
      );
    });

    test('reproducerOnly tier skips the check', () {
      final root = makeRepoRoot();
      addTearDown(() => root.deleteSync(recursive: true));
      writeSyntheticCapture(
        filePath: p.join(root.path, 'at.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [10], // 0 in-band — would fail at runtimeVerified
      );
      writeSyntheticCapture(
        filePath: p.join(root.path, 'above.json'),
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        argKey: 'observedRebuildRate',
        rates: [10],
      );
      final failures = checkMinInBandSamplesPerSpec(
        label: 'X',
        tier: EvidenceTier.reproducerOnly,
        additionalBrackets: [
          spec(
            capturePaths: ['below.json', 'at.json', 'above.json'],
            minInBandSamples: 2,
          ),
        ],
        repoRoot: root.path,
      );
      expect(failures, isEmpty);
    });
  });
}
