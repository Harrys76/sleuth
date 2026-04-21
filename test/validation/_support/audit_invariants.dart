// Shared audit-invariant helpers used by both
// `detector_metadata_audit_test.dart` and
// `component_metadata_audit_test.dart`.
//
// Before v0.16.2 hardening each audit test reimplemented the same five
// invariants side by side: rationale shape, tier-appropriate fields,
// reproducer-file shape (exists + contains tests + references the thing
// under claim), capture-file shape (exists + parses through the schema),
// and bracket-count ( runtimeVerified / externallyCited must carry three
// captures). The duplication hid three bugs surfaced by the
// /advanced-adversarial-review pass:
//
//   - CLAUDE-R4-1 — audit stripped `//` line comments but not `/* ... */`
//     block comments; a reproducer whose `test(...)` calls were all inside
//     a block comment passed the gate.
//   - CODEX-R6-1 — audit called `File(path)` with no canonicalization, so
//     absolute paths, `../../` traversal, or symlink escapes silently
//     passed when the target file happened to exist.
//   - CODEX-R3-2 — component audit never enforced that the reproducer
//     references the component by name (AB3 parity with the detector side).
//
// Centralizing the helpers lets a single fix close all three gaps on both
// audit surfaces, and gives future audits (ledger-sync, public-barrel
// coverage) a single source of truth to extend.
//
// Every helper returns a `List<String>` of human-readable failures. Empty
// list means the invariant held for the entry the helper was called with.
// Callers aggregate across metadata entries and assert the combined list
// is empty so one test failure surfaces every violation at once.

import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart' as dart_parse;
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;
import 'package:sleuth/sleuth.dart' show EvidenceTier, ProfileCaptureSchema;

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/// Strips Dart `//` line comments AND `/* ... */` block comments from
/// [source]. Used by audits that scan test files for `test(` / `testWidgets(`
/// invocations — without block-comment stripping, commented-out test bodies
/// satisfy the regex and mask an empty reproducer.
///
/// AB-10: a naive regex-only implementation mangles strings that happen to
/// contain comment-like text. A triple-quoted docstring that includes
/// `// example invocation` is real code, not a comment; a regex pass would
/// still strip it and the audit would fail a valid reproducer when the
/// required-token search ran against the mangled source. This walks the
/// source once and tracks state across Dart's five string forms:
///
///   - single-line single-quoted `'...'`
///   - single-line double-quoted `"..."`
///   - multi-line single-quoted `'''...'''`
///   - multi-line double-quoted `"""..."""`
///   - raw-prefixed variants of all four (raw strings also disable `\`
///     escaping, so the closer detection must not skip a delimiter after
///     `\` when the string is raw).
///
/// Inside a string, the walker writes bytes through unchanged. Outside, it
/// recognises `//` and `/* ... */` and drops them. Preserves newlines so
/// line numbers in any downstream regex error messages line up with the
/// original source.
String stripDartComments(String source) {
  final buf = StringBuffer();
  final len = source.length;
  var i = 0;
  while (i < len) {
    final c = source.codeUnitAt(i);

    // Outside a string: look for comments or string openings.
    if (c == 0x2f /* / */ && i + 1 < len) {
      final next = source.codeUnitAt(i + 1);
      if (next == 0x2f /* / */) {
        // Line comment — skip to EOL (preserve the newline itself).
        var j = i + 2;
        while (j < len && source.codeUnitAt(j) != 0x0a) {
          j++;
        }
        i = j;
        continue;
      }
      if (next == 0x2a /* * */) {
        // Block comment — skip to closing `*/`, preserving any newlines
        // inside so downstream line numbers stay aligned.
        var j = i + 2;
        while (j + 1 < len) {
          if (source.codeUnitAt(j) == 0x2a &&
              source.codeUnitAt(j + 1) == 0x2f) {
            j += 2;
            break;
          }
          if (source.codeUnitAt(j) == 0x0a) buf.writeCharCode(0x0a);
          j++;
        }
        i = j >= len ? len : j;
        continue;
      }
    }

    // String-literal opener? Optionally preceded by `r` for raw strings.
    var raw = false;
    var stringStart = i;
    if (c == 0x72 /* r */ && i + 1 < len) {
      final next = source.codeUnitAt(i + 1);
      if (next == 0x27 || next == 0x22) {
        raw = true;
        stringStart = i + 1;
      }
    }
    final openCu = source.codeUnitAt(stringStart);
    if (openCu == 0x27 || openCu == 0x22) {
      // Determine delimiter length (1 or 3).
      final triple = stringStart + 2 < len &&
          source.codeUnitAt(stringStart + 1) == openCu &&
          source.codeUnitAt(stringStart + 2) == openCu;
      final delimLen = triple ? 3 : 1;
      final bodyStart = stringStart + delimLen;
      // Echo `r` prefix if present, plus the opening delimiter.
      for (var k = i; k < bodyStart; k++) {
        buf.writeCharCode(source.codeUnitAt(k));
      }
      var j = bodyStart;
      while (j < len) {
        final ch = source.codeUnitAt(j);
        if (!raw && ch == 0x5c /* backslash */ && j + 1 < len) {
          // Copy the escape and the escaped char verbatim.
          buf.writeCharCode(ch);
          buf.writeCharCode(source.codeUnitAt(j + 1));
          j += 2;
          continue;
        }
        if (ch == openCu) {
          if (triple) {
            if (j + 2 < len &&
                source.codeUnitAt(j + 1) == openCu &&
                source.codeUnitAt(j + 2) == openCu) {
              buf.writeCharCode(ch);
              buf.writeCharCode(ch);
              buf.writeCharCode(ch);
              j += 3;
              break;
            }
          } else {
            // Single-line strings cannot span `\n`; Dart treats a bare
            // newline inside `'...'` as a compile error, but the audit
            // does not need to enforce that — just close on the quote.
            buf.writeCharCode(ch);
            j += 1;
            break;
          }
        }
        buf.writeCharCode(ch);
        j++;
      }
      i = j;
      continue;
    }

    // Plain code character — echo through.
    buf.writeCharCode(c);
    i++;
  }
  return buf.toString();
}

/// Canonical repo-root path for path-containment checks. Resolves symlinks
/// so the macOS `/var` ↔ `/private/var` alias does not cause false
/// negatives on `isPathInsideRepo`.
String _canonicalRoot(String? override) {
  final raw = override ?? Directory.current.path;
  try {
    return p.canonicalize(raw);
  } on FileSystemException {
    return p.normalize(p.absolute(raw));
  }
}

/// Whether [candidatePath] resolves to a location inside the repo rooted
/// at [repoRoot] (defaults to `Directory.current.path`).
///
/// Rejects absolute paths outside the repo, `..` traversal that escapes,
/// and symlink targets that resolve outside. Accepts the repo root itself
/// as inside. Non-existent paths are tested lexically — the check is
/// preserved on paths that have not been committed yet.
bool isPathInsideRepo(String candidatePath, {String? repoRoot}) {
  if (candidatePath.isEmpty) return false;
  final root = _canonicalRoot(repoRoot);
  final absolute = p.isAbsolute(candidatePath)
      ? candidatePath
      : p.join(repoRoot ?? Directory.current.path, candidatePath);
  String resolved;
  try {
    resolved = p.canonicalize(absolute);
  } on FileSystemException {
    // Path does not exist yet — fall back to lexical normalization so
    // the check still catches `../../` traversal on not-yet-created files.
    resolved = p.normalize(absolute);
  }
  if (p.equals(resolved, root)) return true;
  return p.isWithin(root, resolved);
}

// ---------------------------------------------------------------------------
// Invariant checkers
// ---------------------------------------------------------------------------

/// Minimum rationale length enforced by both audit gates. Chosen to
/// reject one-word placeholders and very short fragments; real rationales
/// are 1–2 sentences and land comfortably above the floor.
const int minRationaleLength = 20;

/// Invariant 2 (shared): non-empty rationale with minimum length and at
/// least one terminating period. Returns one entry per failure.
List<String> checkRationale(String label, String rationale) {
  final failures = <String>[];
  final trimmed = rationale.trim();
  if (trimmed.isEmpty) {
    failures.add('$label: empty rationale');
  } else if (trimmed.length < minRationaleLength) {
    failures.add('$label: rationale too short '
        '(${trimmed.length} chars, need >= $minRationaleLength)');
  } else if (!trimmed.contains('.')) {
    failures.add('$label: rationale must contain at least one period '
        '(should read as one or more sentences)');
  }
  return failures;
}

/// Invariant: `citationUrl`, when non-null, parses as an HTTP/HTTPS URI
/// with an external-looking authority. Closes CLAUDE-R1-2 — the prior
/// check only asserted non-empty, so `citationUrl: 'see spec'` or
/// `citationUrl: '   '` satisfied the gate.
///
/// AB-11: external citation means a public source of truth, so also
/// reject single-label hosts (`http://intranet`) and loopback hostnames
/// (`localhost`, `127.0.0.1`, `::1`, and their variants). None of those
/// can be an externally resolvable citation by construction; accepting
/// them let a `externallyCited` tier raise ship with a URL that only
/// resolves on the author's machine.
List<String> checkCitationUrl(
  String label,
  String? url, {
  required bool required,
}) {
  if (url == null || url.trim().isEmpty) {
    return required ? ['$label: missing citationUrl'] : const [];
  }
  final parsed = Uri.tryParse(url.trim());
  if (parsed == null) {
    return ['$label: citationUrl is not a parseable URI: $url'];
  }
  if (!parsed.hasScheme ||
      (parsed.scheme != 'http' && parsed.scheme != 'https')) {
    return [
      '$label: citationUrl must use http or https scheme (got '
          '"${parsed.scheme}"): $url'
    ];
  }
  if (!parsed.hasAuthority || parsed.host.isEmpty) {
    return ['$label: citationUrl must include a non-empty host: $url'];
  }
  // Uri.parse lower-cases registered names (reg-names) but leaves bracketed
  // IP-literal hosts as their canonical form; lower-case again defensively
  // so the loopback match hits `LOCALHOST`, `127.000.000.001`-style aliases
  // are NOT auto-canonicalised by Uri, so we keep the match literal.
  final host = parsed.host.toLowerCase();
  // Strip the surrounding brackets IPv6 literal hosts retain.
  final rawHost = host.startsWith('[') && host.endsWith(']')
      ? host.substring(1, host.length - 1)
      : host;
  const loopback = {'localhost', '127.0.0.1', '::1', '0:0:0:0:0:0:0:1'};
  if (loopback.contains(rawHost)) {
    return [
      '$label: citationUrl must point at an external source; loopback '
          'hosts ($rawHost) are rejected: $url',
    ];
  }
  // NEW-CODEX-2 (Bundle H): reject RFC1918 private-range IPv4 addresses
  // (10/8, 172.16/12, 192.168/16), IPv4 link-local (169.254/16), IPv6
  // link-local (fe80::/10), and IPv6 unique-local (fc00::/7). An
  // `externallyCited` tier is, by definition, backed by a citation a
  // third-party reviewer can fetch off the author's network; private-
  // range and link-local literals can't by construction. The host set
  // below carries both the obvious `192.168.x.x` forms and IPv6
  // literals so `[fe80::1]` and `[fc00::beef]` fail consistently with
  // their dotted-quad counterparts.
  final privateRangeFailure = _rejectPrivateRangeHost(label, rawHost, url);
  if (privateRangeFailure != null) {
    return [privateRangeFailure];
  }
  // An external citation must have a dotted host — `http://intranet`, raw
  // single-label hosts, and non-literal IPs with no dots cannot resolve
  // off-machine.
  if (!rawHost.contains('.') && !rawHost.contains(':')) {
    return [
      '$label: citationUrl host "$rawHost" is a single-label / bare-word '
          'identifier; external citations need a dotted hostname or an IP '
          'literal: $url',
    ];
  }
  return const [];
}

/// Returns a non-null failure message if [rawHost] is an IP literal
/// inside any of the private / link-local ranges Bundle H rejects.
/// `null` means "not an IP literal or not in a blocked range" — the
/// caller keeps walking its other host checks.
String? _rejectPrivateRangeHost(String label, String rawHost, String url) {
  // IPv4 dotted-quad. `InternetAddress.tryParse` accepts both IPv4 and
  // IPv6 forms; discriminate on `type` so the range checks below stay
  // family-specific.
  final addr = InternetAddress.tryParse(rawHost);
  if (addr == null) return null;
  if (addr.type == InternetAddressType.IPv4) {
    final parts = rawHost.split('.');
    if (parts.length != 4) return null;
    final octets = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null || n < 0 || n > 255) return null;
      octets.add(n);
    }
    final first = octets[0];
    final second = octets[1];
    final isRfc1918 = first == 10 ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 168);
    final isLinkLocal = first == 169 && second == 254;
    if (isRfc1918 || isLinkLocal) {
      final kind = isLinkLocal ? 'link-local' : 'RFC1918 private-range';
      return '$label: citationUrl points at a $kind IPv4 host ($rawHost); '
          'externally cited claims must resolve off-network: $url';
    }
    return null;
  }
  if (addr.type == InternetAddressType.IPv6) {
    // Compare against the canonical form to avoid string-level drift
    // between `FE80:0:0::1` vs `fe80::1`.
    final canonical = addr.address.toLowerCase();
    // fe80::/10 — first 10 bits are 1111 1110 10, so the first hextet
    // falls in the range `fe80` .. `febf`.
    if (RegExp(r'^fe[89ab][0-9a-f]:').hasMatch(canonical)) {
      return '$label: citationUrl points at a link-local IPv6 host '
          '($rawHost); externally cited claims must resolve off-network: $url';
    }
    // fc00::/7 — first 7 bits are 1111 110, so the first hextet falls
    // in the range `fc00` .. `fdff`.
    if (RegExp(r'^f[cd][0-9a-f]{2}:').hasMatch(canonical)) {
      return '$label: citationUrl points at a unique-local IPv6 host '
          '($rawHost); externally cited claims must resolve off-network: $url';
    }
    return null;
  }
  return null;
}

/// Invariant 4 (shared): reproducer file exists inside the repo, contains
/// at least one `test(` or `testWidgets(` call outside of comments, and
/// textually references every token in [requiredTokens].
///
/// `requiredTokens` is plural to support the component side, where the
/// reproducer should mention the component's `componentName`. Detector
/// side passes a single-element list with the detector's `runtimeType`.
///
/// If the working directory is not the repo root (`pubspec.yaml` absent),
/// the check is skipped with an empty return — mirrors the legacy
/// `markTestSkipped` path but keeps the helper side-effect-free.
List<String> checkReproducerFile({
  required String label,
  required String reproducerPath,
  required Iterable<String> requiredTokens,
  Set<String>? coveredStableIds,
  bool requireInstantiation = true,
  String? repoRoot,
}) {
  if (reproducerPath.trim().isEmpty) return const [];
  final rootDirPath = repoRoot ?? Directory.current.path;
  if (!File(p.join(rootDirPath, 'pubspec.yaml')).existsSync()) {
    return const [];
  }
  final failures = <String>[];
  if (!isPathInsideRepo(reproducerPath, repoRoot: rootDirPath)) {
    failures.add('$label: reproducerPath escapes the repo root: '
        '$reproducerPath (absolute / ".." traversal / symlink target '
        'outside the repo are rejected — reproducers must live in-tree '
        'so the audit is hermetic)');
    return failures;
  }
  final file = File(p.isAbsolute(reproducerPath)
      ? reproducerPath
      : p.join(rootDirPath, reproducerPath));
  if (!file.existsSync()) {
    failures.add('$label: reproducerPath does not exist: $reproducerPath');
    return failures;
  }
  // AGR-3 + R3-NEW-2 (Bundle I): parse the reproducer as Dart AST and
  // walk it with a recursive visitor. String literals carry no
  // `SimpleIdentifier` or `MethodInvocation` AST nodes, so an author
  // cannot satisfy the gate by writing `test('uses XyzDetector')` — the
  // `test` there is a real `MethodInvocation` but its single argument
  // is a `SimpleStringLiteral` whose text contributes no identifiers
  // to the visitor. `${expr}` interpolation segments ARE real code and
  // are visited correctly by the default `RecursiveAstVisitor`
  // descent into `StringInterpolation.elements`. This closes two gaps
  // that the previous regex+contains approach left open:
  //
  //   - AGR-3: the mini-lexer did not enter `${...}` as code, so a
  //     `/* */` block comment inside interpolation survived in the
  //     stripped output as string content rather than being stripped.
  //     With AST, comments are structurally absent.
  //   - R3-NEW-2: `contains('XyzDetector')` matched inside surviving
  //     string literals, so the gate was lexical and satisfiable by
  //     writing the token in a string body rather than using it in
  //     code. With AST, the visitor only observes identifier nodes
  //     the parser built — string text does not create them.
  final source = file.readAsStringSync();
  final _ReproducerAstVisitor visitor;
  try {
    final result = dart_parse.parseString(
      content: source,
      featureSet: FeatureSet.latestLanguageVersion(),
      throwIfDiagnostics: false,
    );
    visitor = _ReproducerAstVisitor(
      requiredTokens: requiredTokens.toSet(),
      coveredStableIds: coveredStableIds ?? const <String>{},
    );
    result.unit.visitChildren(visitor);
  } on ArgumentError catch (e) {
    failures.add('$label: reproducer file failed to parse as Dart '
        '(file: $reproducerPath): $e');
    return failures;
  }
  if (!visitor.hasTestInvocation) {
    failures.add('$label: reproducer file has no test()/testWidgets() calls '
        'outside of comments (line or block): $reproducerPath');
    return failures;
  }
  for (final token in requiredTokens) {
    if (token.isEmpty) continue;
    // B4 Bundle K: credit identifier occurrences ONLY inside test-wrapper
    // callback bodies (test / testWidgets / setUp / setUpAll / tearDown /
    // tearDownAll / group). A top-level `late XyzDetector _unused;` or a
    // dangling import re-export no longer satisfies the reproducer gate.
    if (!visitor.tokensFoundInScope.contains(token)) {
      failures.add('$label: reproducer file does not reference "$token" '
          'by name inside a test/testWidgets/setUp/tearDown/group body — '
          'the reproducer must exercise the thing under claim from real '
          'test-harness code (file: $reproducerPath)');
      continue;
    }
    // B4 Bundle K: the token must be instantiated (`XyzDetector(...)`)
    // at least once inside a test scope so a stale type annotation that
    // never constructs the detector cannot satisfy the gate. Components
    // that publish metadata for a utility class (e.g. a schema with only
    // static methods) opt out via `requireInstantiation: false`.
    if (requireInstantiation && !visitor.tokensInstantiated.contains(token)) {
      failures.add('$label: reproducer file never instantiates "$token" '
          '(no `$token(...)` construction found inside a test scope) — '
          'the reproducer must drive the detector through its real '
          'construction path (file: $reproducerPath)');
    }
  }
  if ((coveredStableIds ?? const <String>{}).isNotEmpty &&
      !visitor.hasCoveredStableIdLiteralInScope) {
    failures.add('$label: reproducer file does not reference any '
        'coveredStableIds entry ($coveredStableIds) as a string literal '
        'inside a test scope — the reproducer must assert against the '
        'detector\'s declared stable-id family, not just construct the '
        'detector and walk away (file: $reproducerPath)');
  }
  return failures;
}

/// AST visitor used by [checkReproducerFile] to distinguish real
/// `test(...)` / `testWidgets(...)` invocations from string literals
/// containing those words, and real identifier references from string
/// text that happens to match a required token.
///
/// The default `RecursiveAstVisitor` descent already handles the two
/// structural concerns we care about:
///
///   - Comments are never attached as children of code-bearing nodes;
///     the visitor never observes them.
///   - `SimpleStringLiteral` has no child AST nodes for its text — the
///     text is a `Token` field, not a node — so the visitor never
///     descends into string text.
///   - `StringInterpolation` has `elements: NodeList<InterpolationElement>`
///     where `InterpolationString` (the text parts) carries no child
///     nodes and `InterpolationExpression` contains a real Dart
///     expression; default descent visits the expression but skips the
///     text, which is exactly what we want.
class _ReproducerAstVisitor extends RecursiveAstVisitor<void> {
  _ReproducerAstVisitor({
    required this.requiredTokens,
    required this.coveredStableIds,
  });

  final Set<String> requiredTokens;
  final Set<String> coveredStableIds;

  bool hasTestInvocation = false;
  final Set<String> tokensFoundInScope = <String>{};
  final Set<String> tokensInstantiated = <String>{};
  bool hasCoveredStableIdLiteralInScope = false;

  /// Test-harness wrapper names whose body callback counts as a
  /// "test scope" for the purposes of crediting identifier references
  /// and stable-id string literals. `group` is included because the
  /// 4 v0.16.3 reproducers all declare `late XyzDetector detector;`
  /// and `setUp(() { detector = XyzDetector(); })` at group scope.
  /// `setUp` / `setUpAll` / `tearDown` / `tearDownAll` are the other
  /// canonical fixture entry points.
  static const _wrapperNames = <String>{
    'test',
    'testWidgets',
    'group',
    'setUp',
    'setUpAll',
    'tearDown',
    'tearDownAll',
  };

  int _scopeDepth = 0;

  bool _isTestWrapperCallback(FunctionExpression node) {
    final parent = node.parent;
    if (parent is! ArgumentList) return false;
    final invocation = parent.parent;
    if (invocation is! MethodInvocation) return false;
    return _wrapperNames.contains(invocation.methodName.name);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    final isWrapper = _isTestWrapperCallback(node);
    if (isWrapper) _scopeDepth++;
    super.visitFunctionExpression(node);
    if (isWrapper) _scopeDepth--;
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    if (name == 'test' || name == 'testWidgets') {
      hasTestInvocation = true;
    }
    // Credit implicit-new constructor calls like `XyzDetector()` which
    // `parseString` (syntactic-only, no element resolution) parses as a
    // `MethodInvocation` rather than an `InstanceCreationExpression`
    // because it has no type info to disambiguate. Required tokens are
    // by contract type names, so any call whose method-name matches
    // counts as instantiation.
    if (_scopeDepth > 0 && requiredTokens.contains(name)) {
      tokensInstantiated.add(name);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (_scopeDepth > 0 && requiredTokens.contains(node.name)) {
      tokensFoundInScope.add(node.name);
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    // `NamedType.name2` is a Token (not a child node) in analyzer 6.x,
    // so default `RecursiveAstVisitor` descent does NOT fire
    // `visitSimpleIdentifier` on type names. Without this explicit
    // visit, `late XyzDetector detector;` inside a `group(() { ... })`
    // callback would not credit the `XyzDetector` scope reference and
    // the audit would spuriously fail on a well-formed reproducer.
    if (_scopeDepth > 0) {
      final typeToken = node.name2.lexeme;
      if (requiredTokens.contains(typeToken)) {
        tokensFoundInScope.add(typeToken);
      }
    }
    super.visitNamedType(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (_scopeDepth > 0) {
      final typeToken = node.constructorName.type.name2.lexeme;
      if (requiredTokens.contains(typeToken)) {
        tokensInstantiated.add(typeToken);
      }
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    if (_scopeDepth > 0 && coveredStableIds.isNotEmpty) {
      final value = node.value;
      for (final id in coveredStableIds) {
        if (id.isEmpty) continue;
        if (value == id || value.startsWith('$id:')) {
          hasCoveredStableIdLiteralInScope = true;
          break;
        }
      }
    }
    super.visitSimpleStringLiteral(node);
  }
}

/// Invariant 5 (shared): every capture file listed exists inside the
/// repo and parses cleanly via `ProfileCaptureSchema.parseFile`. The
/// parse step is a strict hardening over "file exists" — a malformed
/// `sleuthMetadata`, off-matrix device, duplicate-key shadowing, or
/// invalid ISO date now fails CI rather than silently passing.
List<String> checkCapturePaths({
  required String label,
  required List<String>? capturePaths,
  String? repoRoot,
}) {
  if (capturePaths == null) return const [];
  final rootDirPath = repoRoot ?? Directory.current.path;
  if (!File(p.join(rootDirPath, 'pubspec.yaml')).existsSync()) {
    return const [];
  }
  final failures = <String>[];
  for (final capture in capturePaths) {
    if (capture.trim().isEmpty) continue;
    if (!isPathInsideRepo(capture, repoRoot: rootDirPath)) {
      failures.add('$label: profileCapturePath escapes the repo root: '
          '$capture');
      continue;
    }
    final file =
        File(p.isAbsolute(capture) ? capture : p.join(rootDirPath, capture));
    if (!file.existsSync()) {
      failures.add('$label: profileCapturePath does not exist: $capture');
      continue;
    }
    try {
      ProfileCaptureSchema.parseFile(file);
    } on FormatException catch (e) {
      failures.add('$label: $capture — ${e.message}');
    }
  }
  return failures;
}

/// Invariant 3b (shared, F2 contract): `runtimeVerified` and
/// `externallyCited` must carry exactly three captures (below / at /
/// above threshold). Any other length is either a deferred bracket or a
/// silently-widened claim.
///
/// The detector audit added this post-v0.16.2-review; the component
/// audit did not. Sharing this helper closes CODEX-R2-1 (component
/// audit enforces no bracket count/semantics — share
/// `_expectBracketCaptures`).
List<String> checkBracketCount({
  required String label,
  required EvidenceTier tier,
  required List<String>? capturePaths,
}) {
  if (tier != EvidenceTier.runtimeVerified &&
      tier != EvidenceTier.externallyCited) {
    return const [];
  }
  if (capturePaths == null || capturePaths.isEmpty) {
    return [
      '$label: missing profileCapturePaths — tier requires a three-capture '
          'bracket (below / at / above threshold) on top of the reproducer',
    ];
  }
  if (capturePaths.length != 3) {
    return [
      '$label: profileCapturePaths must contain exactly 3 entries (the '
          'bracketing rule requires below / at / above threshold), got '
          '${capturePaths.length}: $capturePaths',
    ];
  }
  return const [];
}

/// CODEX-R1-2: Invariant wiring the audit gate to
/// `ProfileCaptureSchema.validateBracket`. For `runtimeVerified` /
/// `externallyCited` tiers, `bracketThreshold` + `bracketUnit` must be
/// present AND the declared three captures must actually bracket the
/// threshold (below < t, threshold <= at <= t*1.1, above > t). Without
/// this, a tier raise could ship three captures all recorded on the same
/// side of the threshold and the audit would never notice.
///
/// [capturePaths] is assumed to have passed [checkBracketCount] — this
/// helper runs only if length == 3, so the caller should still invoke
/// [checkBracketCount] first for the length failure message.
List<String> checkBracketValidation({
  required String label,
  required EvidenceTier tier,
  required List<String>? capturePaths,
  required num? bracketThreshold,
  required String? bracketUnit,
  String? repoRoot,
}) {
  if (tier != EvidenceTier.runtimeVerified &&
      tier != EvidenceTier.externallyCited) {
    return const [];
  }
  final failures = <String>[];
  if (bracketThreshold == null) {
    failures.add('$label: missing bracketThreshold — runtimeVerified/'
        'externallyCited tiers require a numeric threshold so the audit '
        'can call ProfileCaptureSchema.validateBracket and confirm the '
        'three captures actually bracket it');
  }
  if (bracketUnit == null || bracketUnit.trim().isEmpty) {
    failures.add('$label: missing bracketUnit (e.g. "ms", "bytes", "frames") '
        '— required alongside bracketThreshold');
  }
  if (failures.isNotEmpty) return failures;
  if (capturePaths == null || capturePaths.length != 3) {
    // Length failure already reported by checkBracketCount; don't
    // duplicate it here.
    return const [];
  }
  final rootDirPath = repoRoot ?? Directory.current.path;
  if (!File(p.join(rootDirPath, 'pubspec.yaml')).existsSync()) {
    return const [];
  }
  File resolve(String raw) =>
      File(p.isAbsolute(raw) ? raw : p.join(rootDirPath, raw));
  try {
    ProfileCaptureSchema.validateBracket(
      belowFile: resolve(capturePaths[0]),
      atFile: resolve(capturePaths[1]),
      aboveFile: resolve(capturePaths[2]),
      threshold: bracketThreshold!,
      unit: bracketUnit!,
    );
  } on FormatException catch (e) {
    failures.add('$label: bracket validation failed — ${e.message}');
  }
  return failures;
}
