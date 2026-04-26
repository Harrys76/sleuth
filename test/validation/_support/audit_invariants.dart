// Shared audit-invariant helpers used by both
// `detector_metadata_audit_test.dart` and
// `component_metadata_audit_test.dart`.
//
// Before v0.16.2 hardening each audit test reimplemented the same five
// invariants side by side: rationale shape, tier-appropriate fields,
// reproducer-file shape (exists + contains tests + references the thing
// under claim), capture-file shape (exists + parses through the schema),
// and bracket-count ( runtimeVerified / externallyCited must carry three
// captures). Consolidating them closed three gaps:
//
//   - Block-comment stripping: stripping `//` line comments but not
//     `/* ... */` block comments let a reproducer whose `test(...)`
//     calls were all inside a block comment pass the gate.
//   - Path canonicalization: calling `File(path)` with no canonicalization
//     silently passed absolute paths, `../../` traversal, or symlink
//     escapes when the target file happened to exist.
//   - Component-side name reference: the component audit never enforced
//     that the reproducer references the component by name (AB3 parity
//     with the detector side).
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
  Set<String>? parametricFamilies,
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
      parametricFamilies: parametricFamilies ?? const <String>{},
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
    // Credit references that appear inside test-wrapper callback
    // bodies (test / testWidgets / setUp / setUpAll / tearDown /
    // tearDownAll / group). Top-level declarations / import re-exports
    // don't count.
    if (!visitor.tokensFoundInScope.contains(token)) {
      failures.add('$label: reproducer file does not reference "$token" '
          'by name inside a test/testWidgets/setUp/tearDown/group body — '
          'the reproducer must exercise the thing under claim from real '
          'test-harness code (file: $reproducerPath)');
      continue;
    }
    // The token must be instantiated at least once inside a test scope.
    // Components that publish metadata for a utility class with only
    // static methods opt out via `requireInstantiation: false`.
    if (requireInstantiation && !visitor.tokensInstantiated.contains(token)) {
      failures.add('$label: reproducer file never instantiates "$token" '
          '(no `$token(...)` construction found inside a test scope) — '
          'the reproducer must drive the detector through its real '
          'construction path (file: $reproducerPath)');
    }
  }
  // Bare/colon families and underscore-parametric families track in
  // independent namespaces — a literal credited under one does not
  // satisfy the other. Overlap between the two declaration sets is
  // rejected upstream at the metadata gate.
  final declaredBare = coveredStableIds ?? const <String>{};
  if (declaredBare.isNotEmpty) {
    final missing = declaredBare.difference(visitor.matchedBareFamilies);
    if (missing.isNotEmpty) {
      failures.add('$label: reproducer does not assert against every family '
          'declared in coveredStableIds. Missing: $missing. Each family '
          'must appear as a credited string literal where the assertion '
          'is AST-provable as detector-derived (argument to `hasStableId` '
          '/ `hasStableIdPrefix` / `lacksStableId`; operand of `==` against '
          '`<x>.stableId`; `<x>.stableId.startsWith/contains/endsWith`; or '
          '`expect(<x>.stableId, ...)` where the actual references '
          '`.stableId`). Bare/colon families: exact match or `<family>:` '
          'prefix. (file: $reproducerPath)');
    }
  }
  final declaredParametric = parametricFamilies ?? const <String>{};
  if (declaredParametric.isNotEmpty) {
    final missing =
        declaredParametric.difference(visitor.matchedParametricFamilies);
    if (missing.isNotEmpty) {
      failures.add('$label: reproducer does not assert against every family '
          'declared in parametricFamilies. Missing: $missing. Each family '
          'must appear as a credited string literal of the form '
          '`<family>_<non-empty-suffix>` where the assertion is AST-provable '
          'as detector-derived (see coveredStableIds message for accepted '
          'shapes). (file: $reproducerPath)');
    }
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
    required this.parametricFamilies,
  });

  final Set<String> requiredTokens;
  final Set<String> coveredStableIds;
  final Set<String> parametricFamilies;

  bool hasTestInvocation = false;
  final Set<String> tokensFoundInScope = <String>{};
  final Set<String> tokensInstantiated = <String>{};

  /// Bare / colon-parametric families observed as credited string literals.
  /// Every entry in `coveredStableIds` must appear here.
  final Set<String> matchedBareFamilies = <String>{};

  /// Underscore-parametric families observed as credited string literals.
  /// Every entry in `parametricFamilies` must appear here.
  final Set<String> matchedParametricFamilies = <String>{};

  /// Identifiers bound to detector-derived values. Added by variable
  /// declarations, assignments, `for-in` loop binders, and whitelisted
  /// closure parameters whose initializer/RHS/iterable passes the
  /// structural walk. Removed on non-derived re-bindings and pattern
  /// destructuring. Sticky across test-wrapper callbacks so the
  /// `late detector; setUp(() { detector = ...; })` pattern survives.
  final Set<String> detectorBoundIdentifiers = <String>{};

  /// True when the file locally declares `hasStableId` /
  /// `hasStableIdPrefix` / `lacksStableId` (as function, method, or
  /// variable). Rule-1 rejects credit in that file — a local stub
  /// could always-return-true and bypass the detector-output check.
  bool hasStableIdShadow = false;

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

  /// Methods that preserve element identity on a detector-derived
  /// iterable. Transform methods (`map`, `expand`, `followedBy`,
  /// `reduce`, `fold`, `whereType`) are excluded — they can inject
  /// synthesized values.
  static const _elementPreservingMethods = <String>{
    'where',
    'firstWhere',
    'lastWhere',
    'singleWhere',
    'take',
    'skip',
    'takeWhile',
    'skipWhile',
    'toList',
    'toSet',
    'toIterable',
    'first',
    'last',
    'single',
    'elementAt',
    'reversed',
  };

  /// Methods on a required-token instance that emit detector output.
  /// `scanTree` / `scanFrame` are `BaseDetector` APIs; `issues` covers
  /// both the getter form and the rare method-invocation form.
  static const _producerMethods = <String>{
    'scanTree',
    'scanFrame',
    'issues',
  };

  /// Parameter position that iterates over detector elements per
  /// method. Filter/map methods → position 0. `reduce` / `fold` →
  /// position 1 (position 0 is the accumulator). Methods not listed
  /// here bind no closure parameters.
  static const Map<String, int> _closureParamPositions = {
    'where': 0,
    'firstWhere': 0,
    'lastWhere': 0,
    'singleWhere': 0,
    'any': 0,
    'every': 0,
    'map': 0,
    'forEach': 0,
    'expand': 0,
    'takeWhile': 0,
    'skipWhile': 0,
    'reduce': 1,
    'fold': 1,
  };

  /// Canonical matcher-helper names. A local shadow (function, method,
  /// or variable) would let Rule-1 credit by name alone.
  static const _shadowNames = <String>{
    'hasStableId',
    'hasStableIdPrefix',
    'lacksStableId',
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

    // Bind closure parameters only when the enclosing call is in the
    // whitelist and its receiver is detector-derived. Only the
    // element-iteration position binds — `fold((acc, item) => ...)`
    // binds `item`, not the accumulator `acc`.
    final addedParamNames = <String>[];
    final parent = node.parent;
    if (parent is ArgumentList) {
      final invocation = parent.parent;
      if (invocation is MethodInvocation) {
        final methodName = invocation.methodName.name;
        final position = _closureParamPositions[methodName];
        if (position != null &&
            _expressionIsDetectorDerived(invocation.realTarget)) {
          final params = node.parameters?.parameters;
          if (params != null && position < params.length) {
            final name = params[position].name?.lexeme;
            if (name != null && !detectorBoundIdentifiers.contains(name)) {
              detectorBoundIdentifiers.add(name);
              addedParamNames.add(name);
            }
          }
        }
      }
    }

    super.visitFunctionExpression(node);

    // Remove scoped closure-param bindings so they don't leak into sibling
    // closures or later tests.
    for (final name in addedParamNames) {
      detectorBoundIdentifiers.remove(name);
    }

    if (isWrapper) _scopeDepth--;
  }

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final init = node.initializer;
    final name = node.name.lexeme;
    if (_shadowNames.contains(name)) {
      hasStableIdShadow = true;
    }
    if (init != null) {
      if (_expressionIsDetectorDerived(init)) {
        detectorBoundIdentifiers.add(name);
      } else {
        detectorBoundIdentifiers.remove(name);
      }
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    // Covers `late detector; detector = XyzDetector(...);` AND
    // reassignment to a non-derived value. Any operator counts.
    final lhs = node.leftHandSide;
    if (lhs is SimpleIdentifier) {
      if (_expressionIsDetectorDerived(node.rightHandSide)) {
        detectorBoundIdentifiers.add(lhs.name);
      } else {
        detectorBoundIdentifiers.remove(lhs.name);
      }
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitPatternVariableDeclaration(PatternVariableDeclaration node) {
    // Dart 3 destructuring (`final (a, b) = (x, y);`) rebinds multiple
    // names at once. Per-slot derivation cannot be proven here, so
    // every declared name is conservatively cleared.
    final declaredNames = <String>[];
    _collectPatternNames(node.pattern, declaredNames);
    for (final name in declaredNames) {
      detectorBoundIdentifiers.remove(name);
    }
    super.visitPatternVariableDeclaration(node);
  }

  @override
  void visitPatternAssignment(PatternAssignment node) {
    // `(a, b) = (x, y);` overwrites existing bindings — same kill.
    final assignedNames = <String>[];
    _collectPatternNames(node.pattern, assignedNames);
    for (final name in assignedNames) {
      detectorBoundIdentifiers.remove(name);
    }
    super.visitPatternAssignment(node);
  }

  /// Recursively collects every declared or assigned identifier name
  /// from a [DartPattern] into [out].
  void _collectPatternNames(DartPattern pattern, List<String> out) {
    if (pattern is DeclaredVariablePattern) {
      out.add(pattern.name.lexeme);
      return;
    }
    if (pattern is AssignedVariablePattern) {
      out.add(pattern.name.lexeme);
      return;
    }
    if (pattern is RecordPattern) {
      for (final field in pattern.fields) {
        _collectPatternNames(field.pattern, out);
      }
      return;
    }
    if (pattern is ListPattern) {
      for (final element in pattern.elements) {
        if (element is DartPattern) _collectPatternNames(element, out);
      }
      return;
    }
    if (pattern is MapPattern) {
      for (final element in pattern.elements) {
        if (element is MapPatternEntry) {
          _collectPatternNames(element.value, out);
        }
      }
      return;
    }
    if (pattern is ObjectPattern) {
      for (final field in pattern.fields) {
        _collectPatternNames(field.pattern, out);
      }
      return;
    }
    if (pattern is CastPattern) {
      _collectPatternNames(pattern.pattern, out);
      return;
    }
    if (pattern is NullCheckPattern) {
      _collectPatternNames(pattern.pattern, out);
      return;
    }
    if (pattern is NullAssertPattern) {
      _collectPatternNames(pattern.pattern, out);
      return;
    }
    if (pattern is ParenthesizedPattern) {
      _collectPatternNames(pattern.pattern, out);
      return;
    }
    if (pattern is LogicalAndPattern) {
      _collectPatternNames(pattern.leftOperand, out);
      _collectPatternNames(pattern.rightOperand, out);
      return;
    }
    if (pattern is LogicalOrPattern) {
      _collectPatternNames(pattern.leftOperand, out);
      _collectPatternNames(pattern.rightOperand, out);
      return;
    }
  }

  @override
  void visitForStatement(ForStatement node) {
    // `for (final issue in <iterable>)` uses `DeclaredIdentifier`, so
    // the normal variable-declaration hook doesn't fire. Rebind here
    // around the entire body visit; restore prior state on exit.
    final parts = node.forLoopParts;
    String? name;
    bool wasPriorBound = false;
    if (parts is ForEachPartsWithDeclaration) {
      name = parts.loopVariable.name.lexeme;
      wasPriorBound = detectorBoundIdentifiers.contains(name);
      if (_expressionIsDetectorDerived(parts.iterable)) {
        detectorBoundIdentifiers.add(name);
      } else {
        detectorBoundIdentifiers.remove(name);
      }
    }

    super.visitForStatement(node);

    if (name != null) {
      if (wasPriorBound) {
        detectorBoundIdentifiers.add(name);
      } else {
        detectorBoundIdentifiers.remove(name);
      }
    }
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (_shadowNames.contains(node.name.lexeme)) {
      hasStableIdShadow = true;
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (_shadowNames.contains(node.name.lexeme)) {
      hasStableIdShadow = true;
    }
    super.visitMethodDeclaration(node);
  }

  /// True iff [node] is structurally provable as detector-derived.
  /// Recurses through aliasing shapes (`PropertyAccess`,
  /// `PrefixedIdentifier`, `IndexExpression`, parenthesis/await/cast),
  /// required-token constructors, element-preserving iterable methods
  /// on a derived receiver, and producer methods on a detector instance.
  /// Composite expressions (list/map/record/set literals, conditionals,
  /// binary ops, spreads, collection-if/for, unknown methods, transform
  /// methods like `map`/`expand`/`followedBy`/`reduce`/`fold`) return
  /// false.
  bool _expressionIsDetectorDerived(AstNode? node) {
    if (node == null) return false;

    if (node is ParenthesizedExpression) {
      return _expressionIsDetectorDerived(node.expression);
    }
    if (node is AwaitExpression) {
      return _expressionIsDetectorDerived(node.expression);
    }
    if (node is AsExpression) {
      return _expressionIsDetectorDerived(node.expression);
    }
    if (node is SimpleIdentifier) {
      return detectorBoundIdentifiers.contains(node.name);
    }
    if (node is PrefixedIdentifier) {
      return detectorBoundIdentifiers.contains(node.prefix.name);
    }
    if (node is PropertyAccess) {
      if (_producerMethods.contains(node.propertyName.name) &&
          _expressionIsDetectorDerived(node.target)) {
        return true;
      }
      return _expressionIsDetectorDerived(node.target);
    }
    if (node is IndexExpression) {
      return _expressionIsDetectorDerived(node.target);
    }
    if (node is InstanceCreationExpression) {
      return requiredTokens.contains(node.constructorName.type.name2.lexeme);
    }
    if (node is MethodInvocation) {
      // Implicit-new constructor call parses as MethodInvocation with
      // null target under `parseString` (no type resolution).
      if (node.target == null &&
          requiredTokens.contains(node.methodName.name)) {
        return true;
      }
      final methodName = node.methodName.name;
      if ((_producerMethods.contains(methodName) ||
              _elementPreservingMethods.contains(methodName)) &&
          _expressionIsDetectorDerived(node.realTarget)) {
        return true;
      }
      return false;
    }
    return false;
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
    // Credit a literal as a family-coverage observation only when its
    // AST position proves detector-derived provenance (see
    // [_isCreditedLiteral]).
    final anyDeclared =
        coveredStableIds.isNotEmpty || parametricFamilies.isNotEmpty;
    if (_scopeDepth > 0 && anyDeclared && _isCreditedLiteral(node)) {
      final value = node.value;
      // Bare / colon-parametric families.
      for (final id in coveredStableIds) {
        if (id.isEmpty) continue;
        if (value == id || value.startsWith('$id:')) {
          matchedBareFamilies.add(id);
        }
      }
      // Underscore-parametric families: require `<family>_<non-empty>`.
      for (final family in parametricFamilies) {
        if (family.isEmpty) continue;
        final prefix = '${family}_';
        if (value.startsWith(prefix) && value.length > prefix.length) {
          matchedParametricFamilies.add(family);
        }
      }
    }
    super.visitSimpleStringLiteral(node);
  }

  /// True when the literal's AST position proves detector-derived
  /// provenance. Four accepted shapes, any of which credit:
  ///
  ///   1. Arg to `hasStableId` / `hasStableIdPrefix` / `lacksStableId`
  ///      (rejected when the file locally shadows those names).
  ///   2. Operand of `==` / `!=` whose other operand references
  ///      `.stableId` (covers `i.stableId == '...'` predicates).
  ///   3. Arg to `<x>.stableId.startsWith` / `.endsWith` / `.contains`.
  ///   4. Arg to `expect(<actual>, ...)` / `expectLater(<actual>, ...)`
  ///      where `<actual>` references `.stableId` anywhere in its
  ///      subtree.
  ///
  /// A literal under `NamedExpression` (e.g. `reason:` / `skip:`) is
  /// rejected regardless of the rules above.
  bool _isCreditedLiteral(AstNode startNode) {
    AstNode? cur = startNode.parent;
    var hops = 0;
    while (cur != null && hops < 20) {
      if (cur is NamedExpression) return false;
      // Rule 1.
      if (cur is MethodInvocation && cur.target == null) {
        final name = cur.methodName.name;
        if (_shadowNames.contains(name)) {
          return !hasStableIdShadow;
        }
      }
      // Rule 2.
      if (cur is BinaryExpression) {
        final op = cur.operator.lexeme;
        if (op == '==' || op == '!=') {
          if (_mentionsStableId(cur.leftOperand) ||
              _mentionsStableId(cur.rightOperand)) {
            return true;
          }
        }
      }
      // Rule 3.
      if (cur is MethodInvocation && cur.target != null) {
        final name = cur.methodName.name;
        if ((name == 'startsWith' ||
                name == 'endsWith' ||
                name == 'contains') &&
            _mentionsStableId(cur.target!)) {
          return true;
        }
      }
      // Rule 4.
      if (cur is MethodInvocation && cur.target == null) {
        final name = cur.methodName.name;
        if (name == 'expect' || name == 'expectLater') {
          final args = cur.argumentList.arguments;
          if (args.isNotEmpty && _mentionsStableId(args.first)) {
            return true;
          }
        }
      }
      cur = cur.parent;
      hops++;
    }
    return false;
  }

  /// True iff [node] contains a `.stableId` property read whose
  /// receiver is structurally detector-derived. A bare
  /// `SimpleIdentifier` named `stableId` (e.g. a local variable) does
  /// not fire — only reads through a receiver count.
  bool _mentionsStableId(AstNode node) {
    final v = _StableIdReferenceVisitor(
      isReceiverDerived: _expressionIsDetectorDerived,
    );
    node.accept(v);
    return v.found;
  }
}

/// Visitor that flips `found` when it sees a `.stableId` property read
/// whose receiver passes [isReceiverDerived]. Used by
/// `_ReproducerAstVisitor._mentionsStableId`.
class _StableIdReferenceVisitor extends RecursiveAstVisitor<void> {
  _StableIdReferenceVisitor({required this.isReceiverDerived});

  final bool Function(AstNode?) isReceiverDerived;
  bool found = false;

  @override
  void visitPropertyAccess(PropertyAccess node) {
    if (node.propertyName.name == 'stableId' &&
        isReceiverDerived(node.target)) {
      found = true;
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    if (node.identifier.name == 'stableId' && isReceiverDerived(node.prefix)) {
      found = true;
    }
    super.visitPrefixedIdentifier(node);
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
      // v0.18.3: schema-driven role plumbing replaces the filename-suffix
      // heuristic. ProfileCaptureSchema.parseFile reads
      // `sleuthMetadata.role` directly and applies AB-1 inverse-ratio
      // bypass when role == 'below'. No filename inspection here.
      ProfileCaptureSchema.parseFile(file);
    } on FormatException catch (e) {
      failures.add('$label: $capture — ${e.message}');
    }
  }
  return failures;
}

/// Invariant 3b (shared): `runtimeVerified` and `externallyCited`
/// must carry exactly three captures (below / at / above threshold).
/// Any other length is either a deferred bracket or a
/// silently-widened claim. Sharing this helper between the detector
/// and component audits keeps the bracket contract in one place.
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

/// `runtimeVerified` and `externallyCited` tiers must declare
/// `coveredThresholds` so a detector with multiple severity boundaries
/// (e.g. slow/warning vs critical on the same stable ID) cannot
/// silently imply evidence for every tier when the captured data
/// covers only one. A detector-level tier claim without severity scope
/// recreates the v0.16.4 revert's ambient-bracketing symptom: a single
/// `above` capture at 3117 ms brackets both the 1000 ms warning AND
/// the 3000 ms critical threshold, and the prose scope boundary can't
/// un-bracket the artifact on disk.
///
/// Structural contract:
///   * Each entry is either `<stableId>` (single-severity family) or
///     `<stableId>.<severity>` (severity-scoped). Dotted entries must
///     split on EXACTLY one `.` into two non-empty parts — `.warning`,
///     `slow_request.`, `slow_request..warning`, and any form with a
///     second dot are rejected as malformed.
///   * `<severity>` must be a member of [knownSeverityTags]
///     (`info` / `warning` / `critical`). A typo like
///     `slow_request.warn` no longer passes the string-set gate.
///   * `<stableId>` must match an entry in `coveredStableIds` (exact
///     or as the prefix of a parameterised form per the `:<param>`
///     convention used by the `coveredStableIds` field). Catches
///     cross-family typos (`slow_equest.warning`) and drift between
///     the two scopes.
///   * When `bracketThreshold` is set, non-dotted entries are rejected
///     for the family the bracket scopes. The numeric bracket claim
///     targets a specific severity boundary by construction — an
///     un-scoped family entry next to a bracketThreshold silently
///     overclaims. Matches the shape of the v0.16.4 revert: the
///     bracket triad's `above` ambient-bracketed both severity tiers
///     exactly because the scope was implicit.
///
/// Kept permissive: a bare `coveredStableIds`-style entry (no dot) is
/// still valid when no `bracketThreshold` is declared. Single-severity
/// detectors (e.g. `ImageMemoryDetector` at structural tier only) do
/// not need a severity suffix.
List<String> checkCoveredThresholds({
  required String label,
  required EvidenceTier tier,
  required Set<String>? coveredThresholds,
  Set<String>? coveredStableIds,
  Set<String>? parametricFamilies,
  num? bracketThreshold,
}) {
  if (tier != EvidenceTier.runtimeVerified &&
      tier != EvidenceTier.externallyCited) {
    return const [];
  }
  if (coveredThresholds == null) {
    return [
      '$label: missing coveredThresholds — runtimeVerified/externallyCited '
          'tiers must name which thresholds the evidence covers (e.g. '
          '{"slow_request.warning"}) so the claim cannot silently imply '
          'evidence for an adjacent higher-severity threshold.',
    ];
  }
  if (coveredThresholds.isEmpty) {
    return [
      '$label: coveredThresholds is empty — declare the scoped thresholds '
          'this evidence covers, or demote the tier',
    ];
  }
  final failures = <String>[];
  for (final raw in coveredThresholds) {
    final entry = raw.trim();
    if (entry.isEmpty) {
      failures
          .add('$label: coveredThresholds contains an empty/whitespace entry');
      continue;
    }
    final parts = entry.split('.');
    final isDotted = parts.length > 1;
    if (isDotted) {
      if (parts.length != 2) {
        failures.add('$label: coveredThresholds entry "$entry" has '
            '${parts.length - 1} dots — must be "<stableId>.<severity>" '
            'with exactly one separator');
        continue;
      }
      final stableId = parts[0];
      final severity = parts[1];
      if (stableId.isEmpty) {
        failures.add('$label: coveredThresholds entry "$entry" has an '
            'empty stableId prefix before "."');
        continue;
      }
      if (severity.isEmpty) {
        failures.add('$label: coveredThresholds entry "$entry" has an '
            'empty severity suffix after "."');
        continue;
      }
      if (!knownSeverityTags.contains(severity)) {
        failures.add('$label: coveredThresholds entry "$entry" uses '
            'unrecognised severity "$severity" (must be one of '
            '$knownSeverityTags) — typo or non-canonical tag');
        continue;
      }
      if ((coveredStableIds != null || parametricFamilies != null) &&
          !_stableIdCovers(coveredStableIds ?? const {}, stableId,
              parametricFamilies: parametricFamilies)) {
        failures.add('$label: coveredThresholds entry "$entry" references '
            'stableId "$stableId" not declared in coveredStableIds '
            '($coveredStableIds) or parametricFamilies '
            '($parametricFamilies) — cross-scope drift');
        continue;
      }
      continue;
    }
    // Non-dotted entry.
    if ((coveredStableIds != null || parametricFamilies != null) &&
        !_stableIdCovers(coveredStableIds ?? const {}, entry,
            parametricFamilies: parametricFamilies)) {
      failures.add('$label: coveredThresholds entry "$entry" is non-dotted '
          'but does not match any coveredStableIds '
          '($coveredStableIds) or parametricFamilies '
          '($parametricFamilies) entry');
      continue;
    }
    if (bracketThreshold != null) {
      failures.add('$label: coveredThresholds entry "$entry" is non-dotted '
          'but bracketThreshold is set ($bracketThreshold) — a numeric '
          'threshold claim is inherently severity-scoped, so the entry '
          'must be "$entry.<severity>" to prevent ambient bracketing '
          'of an adjacent tier');
      continue;
    }
  }
  return failures;
}

/// Canonical severity-tag vocabulary used by [checkCoveredThresholds].
/// Mirrors the `IssueSeverity` enum values the detector pipeline emits.
const Set<String> knownSeverityTags = {'info', 'warning', 'critical'};

bool _stableIdCovers(
  Set<String> coveredStableIds,
  String candidate, {
  Set<String>? parametricFamilies,
}) {
  if (coveredStableIds.contains(candidate)) return true;
  for (final id in coveredStableIds) {
    if (candidate.startsWith('$id:')) return true;
  }
  if (parametricFamilies != null) {
    // Family-scoped form: candidate equals a declared family (e.g.
    // `repaint_debug.warning` → stableId prefix `repaint_debug`).
    if (parametricFamilies.contains(candidate)) return true;
    // Concrete-instance form: candidate is `<family>_<non-empty-suffix>`
    // (e.g. `repaint_debug_CustomPaint.warning` → stableId prefix
    // `repaint_debug_CustomPaint`).
    for (final fam in parametricFamilies) {
      if (fam.isEmpty) continue;
      final prefix = '${fam}_';
      if (candidate.startsWith(prefix) && candidate.length > prefix.length) {
        return true;
      }
    }
  }
  return false;
}

/// When `coveredThresholds` contains a severity-scoped entry (dotted
/// form like `slow_request.warning`), an explicit
/// `aboveCeilingMultiplier` must be set on the detector metadata. The
/// schema default
/// [ProfileCaptureSchema.defaultAboveCeilingMultiplier] (2.0) is a safe
/// upper bound for detectors whose severity tiers are spaced by more
/// than 2× — but a detector with warning=800 / critical=1500 has a
/// ratio of 1.875, and a default 2.0× ceiling on the warning `above`
/// capture silently accepts magnitudes that ambiently bracket the
/// critical tier. Requiring an explicit value forces the author to
/// pick a ceiling appropriate for the specific tier layout, not
/// inherit a convenience default.
List<String> checkSeverityScopedCeiling({
  required String label,
  required EvidenceTier tier,
  required Set<String>? coveredThresholds,
  required double? aboveCeilingMultiplier,
}) {
  if (tier != EvidenceTier.runtimeVerified &&
      tier != EvidenceTier.externallyCited) {
    return const [];
  }
  if (coveredThresholds == null) return const [];
  final scopedEntries =
      coveredThresholds.where((e) => e.contains('.')).toList();
  if (scopedEntries.isEmpty) return const [];
  if (aboveCeilingMultiplier == null) {
    return [
      '$label: coveredThresholds names severity-scoped entries '
          '$scopedEntries so aboveCeilingMultiplier must be set explicitly '
          '— the schema default (2.0) is convenience; pick a value '
          'appropriate for the spacing of this detector\'s tiers to '
          'prevent the `above` capture from ambiently bracketing an '
          'adjacent severity tier.',
    ];
  }
  return const [];
}

/// Validates the `perStableIdTier` per-family raise contract.
///
/// Fires whenever [perStableIdTier] is non-null, regardless of base
/// [tier]. This independence is load-bearing: a base-`unvalidated`
/// detector that uses `perStableIdTier` to claim runtimeVerified
/// evidence on a single family would otherwise bypass every audit gate
/// scoped on `meta.tier != unvalidated`. With this helper, the
/// per-family raise contract is enforced even when the surrounding
/// "covered stable IDs must be declared" gate is dormant.
///
/// Invariants:
///   1. Every key in [perStableIdTier] must be in [coveredStableIds].
///      Parametric families don't get per-family raises.
///   2. Every value must be `>= tier` (raises only, never downgrades).
///   3. When [bracketStableId] is set, its effective tier (with raise
///      applied) must be `runtimeVerified` or stronger; otherwise the
///      bracket evidence is unmoored from the family it claims to
///      validate.
List<String> checkPerStableIdTier({
  required String label,
  required EvidenceTier tier,
  required Map<String, EvidenceTier>? perStableIdTier,
  required Set<String>? coveredStableIds,
  required String? bracketStableId,
}) {
  if (perStableIdTier == null) return const [];
  if (perStableIdTier.isEmpty) {
    return [
      '$label: perStableIdTier is an empty map — declare at least one '
          'family raise or use null instead. Empty map is functionally '
          'a no-op and signals an in-progress edit or copy-paste error.',
    ];
  }
  final failures = <String>[];
  for (final entry in perStableIdTier.entries) {
    if (coveredStableIds == null || !coveredStableIds.contains(entry.key)) {
      failures.add('$label: perStableIdTier key "${entry.key}" is not '
          'in coveredStableIds. Per-family raises target a specific '
          'stableId; declare the family in coveredStableIds first.');
    }
    if (entry.value.index < tier.index) {
      failures.add('$label: perStableIdTier["${entry.key}"] = '
          '${entry.value.name} is BELOW base tier ${tier.name}. '
          'Overrides raise only — base tier is the per-family minimum. '
          'Lower the base tier instead of downgrading a single family.');
    }
  }
  if (bracketStableId != null) {
    final bracketEffective = perStableIdTier[bracketStableId] ?? tier;
    if (bracketEffective.index < EvidenceTier.runtimeVerified.index) {
      failures.add('$label: bracketStableId "$bracketStableId" has '
          'effective tier ${bracketEffective.name} but bracket fields '
          '(profileCapturePaths/bracketThreshold) require the targeted '
          'family to be runtimeVerified or stronger. Either drop the '
          'bracket fields or add a perStableIdTier entry raising the '
          'family.');
    }
  }
  return failures;
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
  double? aboveCeilingMultiplier,
  double? bracketAtTolerance,
  String? bracketStableId,
  String? bracketSeverityLabel,
  bool requireTraceRecord = false,
  bool requireUniqueDetectedAtMicros = false,
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
  // runtimeVerified detector tier raises must prove the detector
  // actually fired AT THE CLAIMED SEVERITY. Without bracketStableId +
  // bracketSeverityLabel the schema cannot search for the trace
  // record. Components (e.g. ProfileCaptureSchema itself) do not emit
  // issue records, so they pass requireTraceRecord: false.
  if (requireTraceRecord) {
    if (bracketStableId == null || bracketStableId.trim().isEmpty) {
      failures.add('$label: missing bracketStableId — runtimeVerified/'
          'externallyCited detector tiers require the detector\'s '
          'stableId so the audit can require a '
          '`sleuth.issue.<id>.<severity>` trace record inside the '
          'at+above captures (proof the detector actually fired during '
          'the captured scenario)');
    }
    if (bracketSeverityLabel == null || bracketSeverityLabel.trim().isEmpty) {
      failures.add('$label: missing bracketSeverityLabel — '
          'runtimeVerified/externallyCited detector tiers require '
          'either "warning" or "critical" so the trace-record check '
          'matches the SAME severity the bracket validates (e.g. an '
          '8 ms bracket pairs with severityLabel="warning"; a '
          '`.critical` event must not satisfy a warning audit)');
    }
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
      atTolerance:
          bracketAtTolerance ?? ProfileCaptureSchema.defaultAtTolerance,
      aboveCeilingMultiplier: aboveCeilingMultiplier ??
          ProfileCaptureSchema.defaultAboveCeilingMultiplier,
      requireDetectorTraceRecord: requireTraceRecord,
      requireUniqueDetectedAtMicros: requireUniqueDetectedAtMicros,
      stableId: bracketStableId,
      severityLabel: bracketSeverityLabel,
    );
  } on FormatException catch (e) {
    failures.add('$label: bracket validation failed — ${e.message}');
  }
  return failures;
}

/// Walks [capturesRoot] for every committed `.json` capture and
/// returns a failure entry for any file
/// that is neither declared in some detector/component's
/// `profileCapturePaths` nor explicitly allowlisted.
///
/// Motivation: v0.16.4 reverted `NetworkMonitorDetector` from a staged
/// `externallyCited` raise back to `reproducerOnly` but kept two
/// below/at capture files on disk (for v0.16.5 re-raise reuse). Without
/// this audit, a future drift that forgets the files or deletes the
/// wrong one silently passes CI — the cross-check against
/// `profileCapturePaths` only fires for referenced files, not for
/// orphans.
///
/// [referencedPaths] is a set of repo-relative paths harvested from
/// every detector/component metadata the caller walks. [allowlist] is
/// a closed set of repo-relative orphan paths that are deliberately
/// retained (e.g. future-release placeholders); every entry must carry
/// a human-readable rationale in the calling test's comment so a
/// reviewer can audit the reason the file exists without a live claim.
///
/// Paths are compared after `path.canonicalize` on an absolute form so
/// forward/back slash and trailing-slash drift cannot mask an orphan.
/// Subdirectories listed in [excludedSubdirectoryNames] are skipped
/// (default `{'_fixtures'}` — fixtures are negative-case data, not
/// captures-under-claim, and have their own audit surfaces).
List<String> checkCaptureOrphans({
  required Directory capturesRoot,
  required Set<String> referencedPaths,
  required Set<String> allowlist,
  String? repoRoot,
  Set<String> excludedSubdirectoryNames = const {'_fixtures'},
}) {
  if (!capturesRoot.existsSync()) return const [];
  final rootDirPath = repoRoot ?? Directory.current.path;
  String canonicalize(String raw) {
    final absolute = p.isAbsolute(raw) ? raw : p.join(rootDirPath, raw);
    try {
      return p.canonicalize(absolute);
    } on FileSystemException {
      return p.normalize(absolute);
    }
  }

  final canonicalReferenced = referencedPaths.map(canonicalize).toSet();
  final canonicalAllowlist = allowlist.map(canonicalize).toSet();
  final canonicalCapturesRoot = canonicalize(capturesRoot.path);
  final failures = <String>[];
  for (final entity in capturesRoot.listSync(recursive: true)) {
    if (entity is! File) continue;
    if (!entity.path.toLowerCase().endsWith('.json')) continue;
    final canonicalEntityPath = canonicalize(entity.path);
    final rel = p.relative(canonicalEntityPath, from: canonicalCapturesRoot);
    final parts = p.split(rel);
    if (parts.any(excludedSubdirectoryNames.contains)) continue;
    if (canonicalReferenced.contains(canonicalEntityPath)) continue;
    if (canonicalAllowlist.contains(canonicalEntityPath)) continue;
    final displayRel = p.relative(
      canonicalEntityPath,
      from: canonicalize(rootDirPath),
    );
    failures.add(
      'orphan capture: $displayRel is not referenced by any detector/'
      'component profileCapturePaths and is not on the retained-orphan '
      'allowlist. Either reference it from a metadata entry, delete it, '
      'or add it to the allowlist with a rationale explaining why it is '
      'retained (e.g. v0.16.N re-raise reuse).',
    );
  }
  return failures;
}

/// Typed retained-orphan manifest entry. Each field pins a dimension
/// of the capture so the audit can cross-check the file on disk
/// against the manifest and fail on silent drift (wrong device, stale
/// Flutter
/// version, observed magnitude outside declared band) rather than
/// waving the file through based on filename alone.
///
/// Lifecycle: every entry declares the release it expects to be
/// consumed by (`consumeBy`, semver string like `"0.16.5"`) and the
/// planned claim that will consume it (`owningClaim`, e.g.
/// `"NetworkMonitorDetector.slow_request.warning"`). When the repo's
/// current release reaches or passes `consumeBy`, the audit fails the
/// entry — allowlisted orphans cannot outlive their promised
/// consumption window.
class RetainedOrphanEntry {
  const RetainedOrphanEntry({
    required this.role,
    required this.device,
    required this.deviceOsVersion,
    required this.flutterMajorMinor,
    required this.unit,
    required this.observedMin,
    required this.observedMax,
    required this.consumeBy,
    required this.owningClaim,
    required this.rationale,
  });

  /// Role in the bracket triad — `'below'` / `'at'` / `'above'` — or
  /// any short descriptive label for non-bracket orphans. Surfaced in
  /// failure messages so the reviewer sees which slot the file was
  /// meant to fill.
  final String role;

  /// Expected `sleuthMetadata.device` value (e.g. `"iPhone 12"`).
  final String device;

  /// Expected `sleuthMetadata.deviceOsVersion` value.
  final String deviceOsVersion;

  /// Expected `sleuthMetadata.flutterVersion` major.minor prefix
  /// (e.g. `"3.41"`). Full patch level drifts across recordings; the
  /// audit only pins the major.minor.
  final String flutterMajorMinor;

  /// Expected `sleuthMetadata.expectedMagnitude.unit`.
  final String unit;

  /// Lower bound (inclusive) of the acceptable
  /// `expectedMagnitude.observed` band.
  final num observedMin;

  /// Upper bound (inclusive) of the acceptable
  /// `expectedMagnitude.observed` band.
  final num observedMax;

  /// Semver string naming the release the entry expects to land in.
  /// When the audit's `currentReleaseVersion` reaches or passes this,
  /// the entry is declared expired and fails.
  final String consumeBy;

  /// Descriptive identifier for the planned claim that will consume
  /// the capture — surfaced verbatim in failure messages so a
  /// reviewer can jump from audit output to the roadmap row.
  final String owningClaim;

  /// Human-readable rationale. Matches the freeform string form that
  /// existed before the manifest shape — still required so the list
  /// reads as intent, not just data.
  final String rationale;
}

/// Parses every entry in a typed retained-orphan manifest,
/// cross-checks parsed `sleuthMetadata` against the manifest's
/// declared device / OS / Flutter / unit / observed band, and fails
/// entries whose `consumeBy` release has been reached or passed.
///
/// Motivation: v0.16.4 introduced a freeform `Map<String, String>`
/// allowlist for the two `slow_request` below/at captures held for
/// v0.16.5 re-raise reuse. The freeform shape had three rot surfaces:
/// (1) no schema parse ran against the files on disk, so a corrupted
/// or edited capture could sit dormant for releases until v0.16.5
/// tried to wire it in; (2) no lifecycle — the rationale could
/// quietly reference a milestone that was skipped, leaving the files
/// as permanent orphans; (3) no cross-check on device / Flutter /
/// unit / observed, so a future recording drift would not surface
/// until the next time a human reviewed the allowlist. The typed
/// manifest closes all three by contract.
///
/// Returns a `List<String>` of human-readable failures. Empty list
/// means the manifest held. Failure categories surfaced per entry:
/// missing file, schema parse failure, device/OS/Flutter/unit
/// mismatch against the manifest declaration, observed magnitude
/// outside `[observedMin, observedMax]` band, expired `consumeBy`.
///
/// Any entry that fails for any reason is reported with the full
/// set of violations for that entry so one audit run surfaces every
/// drift source at once — no "fix one, run it again, fix the next"
/// round-tripping.
///
/// [currentReleaseVersion] is the repo's active release semver
/// string (e.g. from `pubspec.yaml`). When `_compareSemver(current,
/// entry.consumeBy) >= 0`, the entry is expired.
List<String> checkRetainedOrphanManifest({
  required Map<String, RetainedOrphanEntry> manifest,
  required String currentReleaseVersion,
  String? repoRoot,
}) {
  if (manifest.isEmpty) return const [];
  final rootDirPath = repoRoot ?? Directory.current.path;
  if (!File(p.join(rootDirPath, 'pubspec.yaml')).existsSync()) {
    return const [];
  }
  final failures = <String>[];
  manifest.forEach((relPath, entry) {
    final perEntry = <String>[];
    final file =
        File(p.isAbsolute(relPath) ? relPath : p.join(rootDirPath, relPath));
    if (!file.existsSync()) {
      perEntry.add('file does not exist on disk');
    } else {
      Map<String, Object?>? metadata;
      try {
        metadata = ProfileCaptureSchema.parseFile(file);
      } on FormatException catch (e) {
        perEntry.add('ProfileCaptureSchema.parseFile failed: ${e.message}');
      }
      if (metadata != null) {
        final device = metadata['device'];
        if (device != entry.device) {
          perEntry.add('device mismatch — manifest declares '
              '"${entry.device}" but capture says "$device"');
        }
        final osVersion = metadata['deviceOsVersion'];
        if (osVersion != entry.deviceOsVersion) {
          perEntry.add('deviceOsVersion mismatch — manifest declares '
              '"${entry.deviceOsVersion}" but capture says "$osVersion"');
        }
        final flutterVersion = metadata['flutterVersion'];
        if (flutterVersion is! String ||
            !flutterVersion.startsWith('${entry.flutterMajorMinor}.')) {
          perEntry.add('flutterVersion mismatch — manifest declares '
              'major.minor "${entry.flutterMajorMinor}" but capture says '
              '"$flutterVersion"');
        }
        final magnitude = metadata['expectedMagnitude'];
        if (magnitude is Map<String, Object?>) {
          final unit = magnitude['unit'];
          if (unit != entry.unit) {
            perEntry.add('expectedMagnitude.unit mismatch — manifest '
                'declares "${entry.unit}" but capture says "$unit"');
          }
          final observed = magnitude['observed'];
          if (observed is num) {
            if (observed < entry.observedMin || observed > entry.observedMax) {
              perEntry.add('expectedMagnitude.observed $observed outside '
                  'manifest band [${entry.observedMin}, '
                  '${entry.observedMax}] — recording drift or wrong manifest '
                  'entry');
            }
          } else {
            perEntry.add('expectedMagnitude.observed is not a number '
                '(got $observed)');
          }
        } else {
          perEntry.add('expectedMagnitude is not a Map (got $magnitude)');
        }
      }
    }
    final cmp = _compareSemver(currentReleaseVersion, entry.consumeBy);
    if (cmp >= 0) {
      perEntry.add('consumeBy "${entry.consumeBy}" has been reached by '
          'current release "$currentReleaseVersion" — entry is expired. '
          'Either consume the capture in the owning claim '
          '("${entry.owningClaim}") or delete the file and remove this '
          'manifest entry');
    }
    if (perEntry.isNotEmpty) {
      failures.add('retained orphan "$relPath" (role=${entry.role}, '
          'owningClaim=${entry.owningClaim}): ${perEntry.join('; ')}');
    }
  });
  return failures;
}

/// Compares two dotted-numeric semver strings. Returns a negative int
/// when [a] < [b], zero when equal, positive when [a] > [b]. Handles
/// differing segment counts ( `"0.16" < "0.16.5"` ) by zero-padding.
/// Pre-release and build suffixes (`-pre.1`, `+build`) are stripped
/// with a plain `indexOf` — the manifest's consumeBy is expected to
/// be a canonical release number, not a pre-release identifier.
int _compareSemver(String a, String b) {
  List<int> parts(String v) {
    var trimmed = v.trim();
    final dash = trimmed.indexOf('-');
    if (dash != -1) trimmed = trimmed.substring(0, dash);
    final plus = trimmed.indexOf('+');
    if (plus != -1) trimmed = trimmed.substring(0, plus);
    return trimmed
        .split('.')
        .map((s) => int.tryParse(s) ?? 0)
        .toList(growable: false);
  }

  final pa = parts(a);
  final pb = parts(b);
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < len; i++) {
    final ai = i < pa.length ? pa[i] : 0;
    final bi = i < pb.length ? pb[i] : 0;
    if (ai != bi) return ai - bi;
  }
  return 0;
}
