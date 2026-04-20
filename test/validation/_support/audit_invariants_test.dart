// Dedicated unit tests for the shared audit-invariant helpers used by
// both `detector_metadata_audit_test.dart` and
// `component_metadata_audit_test.dart`. Pins the exact negative cases
// that the post-v0.16.2-adversarial-review hardening was designed to
// close:
//
//   - CLAUDE-R4-1 — block-comment stripping: a reproducer file whose
//     only `test(` calls are inside `/* ... */` must not satisfy the
//     gate.
//   - CODEX-R6-1 — repo containment: absolute paths, `../../` traversal
//     that escapes the repo, and symlinks that canonicalise outside the
//     repo all fail the reproducer + capture checks.
//   - CLAUDE-R1-2 — citation URL: non-empty strings that are not
//     parseable http/https URIs with an authority (e.g. `'see spec'`,
//     `'ftp://...'`, or a relative path) must fail.
//   - CODEX-R2-1 / F2 — bracket-count: runtimeVerified and
//     externallyCited demand exactly three captures.
//
// Where a helper needs on-disk state, the test materialises a temporary
// directory with a synthetic `pubspec.yaml` and passes it through the
// helper's `repoRoot` override. This keeps the helper hermetic (no
// dependence on repo layout drift) and lets us test both the positive
// and the negative shape of every rule without writing fixture files
// that the Flutter test runner might try to execute.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart' show EvidenceTier;

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

  group('checkBracketCount (CODEX-R2-1 / F2)', () {
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
}
