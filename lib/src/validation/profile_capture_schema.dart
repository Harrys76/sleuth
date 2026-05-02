import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'capture_event_constants.dart';
import 'detector_metadata.dart' show BracketSpec;

/// Schema + validator for Sleuth profile-mode captures.
///
/// A Sleuth capture is a DevTools Chrome Trace Event Format export with a
/// hand-annotated `sleuthMetadata` wrapper. DevTools does not auto-emit
/// device, OS, or Flutter-version information, so the wrapper is a
/// deliberate deviation from vanilla exports: it pins the capture to a
/// known reference device and scenario so the audit gate can verify the
/// evidence is provably from a pinned environment.
///
/// `parse` is the single entry point. It:
///
/// 1. UTF-8 decodes raw bytes (rejects non-UTF-8).
/// 2. Strips a UTF-8 BOM if present.
/// 3. Normalises CRLF line endings to LF.
/// 4. JSON-decodes.
/// 5. Validates required top-level + metadata keys.
/// 6. Enforces pinned-device / pinned-OS / pinned-Flutter policy.
/// 7. Asserts `expectedMagnitude.{min, observed, max}` are numeric and
///    satisfy `min <= observed <= max`.
/// 8. Parses `captureDate` as ISO-8601.
///
/// `validateBracket` runs the triad rule on three captures bracketing a
/// threshold: below < threshold, at within a ±10% band, above > threshold.
///
/// Both entry points throw [FormatException] with a precise message on any
/// violation so the audit gate can surface actionable failures.
class ProfileCaptureSchema {
  ProfileCaptureSchema._();

  /// Keys that must appear at the top level of a capture export.
  static const Set<String> requiredTopLevel = {
    'traceEvents',
    'sleuthMetadata',
  };

  /// Keys that must appear inside the `sleuthMetadata` wrapper.
  static const Set<String> requiredMetadata = {
    'device',
    'deviceOsVersion',
    'flutterVersion',
    'captureCommand',
    'scenario',
    'expectedMagnitude',
    'captureDate',
    'role',
  };

  /// Allowed values for `sleuthMetadata.role` — exact, case-sensitive
  /// allowlist. Replaces the v0.18.2 filename-suffix heuristic for
  /// below-leg detection. Strict union enforcement: typos like
  /// 'Below', 'BELOW', 'sub' fail fast at parse time so audit-side
  /// role-driven logic can rely on the value being exactly one of
  /// these three strings.
  static const Set<String> allowedRoles = {'below', 'at', 'above'};

  /// Pinned device → approved OS versions map. Reference-device policy is
  /// documented in `doc/reference_devices.md`. The matrix rotates once per
  /// calendar year in a dedicated release — not silently.
  static const Map<String, Set<String>> approvedDevicePairs = {
    'iPhone 13 mini': {'iOS 17.6.1'},
    'iPhone 12': {'iOS 17.5'},
    'Pixel 7': {'Android 14'},
  };

  /// Captures must be recorded under a Flutter stable release matching
  /// this major.minor pin. Rotated together with the device matrix.
  static const String approvedFlutterMajorMinor = '3.41';

  /// Default bracket tolerance for the `_at` capture — observed may lie
  /// anywhere in `[threshold, threshold * (1 + defaultAtTolerance)]`.
  static const double defaultAtTolerance = 0.10;

  /// Decodes raw capture bytes, normalises encoding, and validates the
  /// schema. Returns the parsed `sleuthMetadata` object for convenient
  /// downstream access; the full JSON root is recoverable via
  /// `json['sleuthMetadata']`'s container.
  ///
  /// Throws [FormatException] with a precise message on any violation.
  ///
  /// The inverse-ratio half of the AB-1 cross-check is skipped when the
  /// capture's `sleuthMetadata.role` is `'below'`. Below-leg semantics
  /// intentionally pair a tiny `expectedMagnitude.observed`
  /// (sub-threshold workload, e.g. 0.5 ms) with a normal-sized scenario
  /// span (~250 ms including flushTimelineNow + dwell), producing
  /// inverse-ratios well above the 100× ceiling that would otherwise
  /// rightly catch fabricated at/above captures. Sub-threshold roles
  /// have no markers-bracket-the-work invariant; the
  /// `_requireNoIssueTraceRecord` check protects below-leg honesty.
  static Map<String, Object?> parse(List<int> rawBytes) {
    final decoded = _decodeUtf8(rawBytes);
    final normalised = _stripBomAndNormaliseLineEndings(decoded);

    // CODEX-R6-2: Detect duplicate JSON keys before jsonDecode collapses
    // them. RFC 8259 §4 permits duplicates; Dart's `jsonDecode` silently
    // takes the last write. Without this check an attacker (or a
    // well-meaning contributor with an editor glitch) can craft a fixture
    // that presents one value to a human reviewer and certifies a
    // different value to the schema validator — a review-bypass surface.
    _detectDuplicateKeys(normalised);

    final Object? root;
    try {
      root = jsonDecode(normalised);
    } on FormatException catch (e) {
      throw FormatException('Capture is not valid JSON: ${e.message}');
    }
    if (root is! Map<String, Object?>) {
      throw const FormatException(
          'Capture root must be a JSON object, not an array or primitive.');
    }

    for (final key in requiredTopLevel) {
      if (!root.containsKey(key)) {
        throw FormatException('Missing required top-level key: "$key". '
            'Expected: ${requiredTopLevel.toList()..sort()}.');
      }
    }
    _validateTraceEvents(root['traceEvents']);

    final sleuthMetadata = root['sleuthMetadata'];
    if (sleuthMetadata is! Map<String, Object?>) {
      throw const FormatException('"sleuthMetadata" must be a JSON object.');
    }
    for (final key in requiredMetadata) {
      if (!sleuthMetadata.containsKey(key)) {
        throw FormatException('Missing required sleuthMetadata key: "$key". '
            'Expected: ${requiredMetadata.toList()..sort()}.');
      }
    }

    _validateDevicePolicy(sleuthMetadata);
    _validateFlutterVersion(sleuthMetadata);
    _validateCaptureCommandAndScenario(sleuthMetadata);
    _validateExpectedMagnitude(sleuthMetadata);
    _validateCaptureDate(sleuthMetadata);
    final role = sleuthMetadata['role'];
    if (role is! String || !allowedRoles.contains(role)) {
      throw FormatException(
          'Invalid `sleuthMetadata.role`: ${role == null ? 'null' : '"$role"'}. '
          'Must be exactly one of ${allowedRoles.toList()..sort()} '
          '(case-sensitive). Below-leg AB-1 inverse-ratio bypass is '
          'driven by this field — typos default to enforcement and '
          'will surface as false-positive failures.');
    }
    // Below-leg semantics: sub-threshold workload paired with normal-
    // sized scenario span (workload + flushTimelineNow + dwell). The
    // AB-1 inverse-ratio half false-positives on this shape — its 100×
    // ceiling is meant to catch fabricated at/above captures
    // (markers bracketing unrelated work). _requireNoIssueTraceRecord
    // is the actual contract for below-role honesty.
    final isBelowRole = role == 'below';
    _crossCheckTraceVsObserved(root['traceEvents'] as List, sleuthMetadata,
        skipInverseRatio: isBelowRole);

    return sleuthMetadata;
  }

  /// Minimum number of trace events a `runtimeVerified` capture must
  /// contain. Flutter profile-mode runs emit thousands of events per
  /// second; an export with a handful of entries is either truncated,
  /// captured outside profile mode, or synthetic. Set conservatively low
  /// so that very short scenarios still pass but an empty wrapper fails.
  /// The anchor fixture contains ~20 hand-rolled events; real captures
  /// run into the thousands.
  static const int minTraceEvents = 10;

  /// Chrome Trace Event Format phase codes accepted in a capture. The
  /// superset includes sync (B/E/X), async (b/e/n/i/I), metadata (M),
  /// counter (C), and flow (s/f/t) phases. Unknown phases fail the
  /// schema so a fabricated export cannot sneak through with `ph: 'z'`
  /// entries.
  ///
  /// `'n'` — async nestable instant — is the form Perfetto's `traceconv`
  /// (the conversion path from DevTools' on-disk `.pftrace` binary to
  /// Chrome Trace JSON) emits for Dart's `Timeline.instantSync(...)`;
  /// the Chrome-native path uses `'i'`/`'I'`. Accepting both keeps the
  /// schema agnostic to which DevTools export path produced the capture.
  static const Set<String> allowedTracePhases = {
    'B',
    'E',
    'X',
    'b',
    'e',
    'n',
    'i',
    'I',
    'M',
    'C',
    's',
    'f',
    't',
  };

  /// Phase codes that represent actual captured work — durations the
  /// detector under test can observe. Metadata (`M`), instant (`i`/`I`),
  /// counter (`C`), and flow (`s`/`f`/`t`) phases do NOT count: a capture
  /// composed entirely of those phases has no runtime evidence, only
  /// annotations.
  static const Set<String> workTracePhases = {'B', 'E', 'X', 'b', 'e'};

  /// Minimum count of work-phase events a capture must contain. Anchor
  /// and dormant-bracket fixtures have 5–8 work events; real profile-mode
  /// runs emit thousands. Set conservatively so short scenarios still pass
  /// while wrappers composed of metadata/instant events fail.
  static const int minWorkPhaseEvents = 3;

  static void _validateTraceEvents(Object? raw) {
    if (raw is! List) {
      throw const FormatException(
          '"traceEvents" must be a JSON array of Chrome Trace events.');
    }
    // CODEX-R3-1: an empty or near-empty traceEvents array means the
    // capture is a hollow wrapper — the `runtimeVerified` claim can then
    // be fabricated without any actual profile-mode data backing it.
    if (raw.length < minTraceEvents) {
      throw FormatException(
          '"traceEvents" has only ${raw.length} entries — a real profile-'
          'mode capture emits thousands. A wrapper with fewer than '
          '$minTraceEvents events is rejected so runtimeVerified claims '
          'cannot be fabricated from empty exports.');
    }
    // Every entry must be an object with a recognized `ph` field. We
    // don't validate per-phase field presence (that's Chrome's problem,
    // not ours); we just confirm the array isn't padded with nulls,
    // strings, or objects lacking `ph`.
    var workPhaseCount = 0;
    for (var i = 0; i < raw.length; i++) {
      final event = raw[i];
      if (event is! Map<String, Object?>) {
        throw FormatException(
            '"traceEvents[$i]" is not a JSON object; each entry must be '
            'a Chrome Trace Event record.');
      }
      final ph = event['ph'];
      if (ph is! String || !allowedTracePhases.contains(ph)) {
        throw FormatException('"traceEvents[$i].ph" is missing or unknown (got '
            '${ph is String ? '"$ph"' : ph.runtimeType}). Allowed phases: '
            '${(allowedTracePhases.toList()..sort()).join(', ')}. '
            'Fabricated events with unknown phases are rejected to keep '
            'runtimeVerified claims honest.');
      }
      if (workTracePhases.contains(ph)) workPhaseCount++;
    }
    // AB-1 phase-set assertion: without this, a wrapper of 11 `M`-phase
    // metadata events or 11 `i`-phase instant markers satisfied every
    // other check in this routine yet carried zero runtime evidence. A
    // capture that claims profile-mode bracketing must actually contain
    // captured work.
    if (workPhaseCount < minWorkPhaseEvents) {
      throw FormatException(
          '"traceEvents" contains only $workPhaseCount work-phase entries '
          '(B/E/X/b/e); at least $minWorkPhaseEvents are required. '
          'A capture composed entirely of metadata (M), instant (i/I), '
          'counter (C), or flow (s/f/t) events carries no runtime '
          'evidence for the claim and is rejected.');
    }
  }

  /// AB-1 cross-check: a capture that pairs a hand-authored
  /// `expectedMagnitude.observed` with a trace whose scenario-marker
  /// span is orders of magnitude smaller than the claim almost certainly
  /// describes a fabricated export. For time-unit magnitudes (`ms`,
  /// `us`, `s`, `ns`) we bind the span to the two scenario-marker
  /// instant events (see [scenarioBeginMarker] / [scenarioEndMarker]),
  /// convert the claimed observed into the same unit (microseconds),
  /// and reject if the claim exceeds the span by more than
  /// [maxObservedToSpanRatio]. For non-time units (bytes, frames,
  /// requests, …) no cross-check is attempted — the trace cannot
  /// meaningfully certify those.
  ///
  /// Bundle F tightened the ratio from 100_000 → 100. The prior bound
  /// admitted realistic 100×–10_000× fabrication (observed: 1000 ms
  /// paired with a 1–10 ms span). A real profile-mode capture of a
  /// 1000 ms scenario emits markers bracketing the full 1000 ms;
  /// 100× allows modest instrumentation overhead (marker emission
  /// just before/after the scenario, driver framework preamble) but
  /// not order-of-magnitude drift.
  ///
  /// R3-NEW-1 (Bundle F): span is now bound to scenario markers, not
  /// the global `minTs/maxTs` over every work-phase event. The prior
  /// implementation iterated the full trace, so an attacker could
  /// pad a single unrelated event at `ts=1_000_000` and inflate the
  /// denominator until any observed claim fit.
  static const double maxObservedToSpanRatio = 100;

  /// Canonical name for the "begin" scenario-marker instant event.
  /// Exactly one must appear in a time-unit capture. Its `ts` is the
  /// start of the scoped work window used for the AB-1 cross-check.
  static const String scenarioBeginMarker = 'sleuth.scenario.begin';

  /// Canonical name for the "end" scenario-marker instant event.
  /// Exactly one must appear in a time-unit capture. Its `ts` is the
  /// end of the scoped work window used for the AB-1 cross-check.
  static const String scenarioEndMarker = 'sleuth.scenario.end';

  static void _crossCheckTraceVsObserved(
      List events, Map<String, Object?> metadata,
      {bool skipInverseRatio = false}) {
    final magnitude = metadata['expectedMagnitude'] as Map<String, Object?>;
    // AGR-1 (Bundle E): these early-returns used to be silent opt-outs
    // that fired on `unit: null`, `unit: 42`, or a novel spelling —
    // the most important cross-check this schema runs was one typo
    // away from being disabled. `_validateExpectedMagnitude` now
    // enforces that `unit` is a non-empty String in the approved set
    // before this function is called, so a non-String unit here is a
    // programming error, not a data error. Convert to an explicit
    // assert so any future reorder of the parse pipeline fails loudly
    // in debug and profile builds.
    final unit = magnitude['unit'];
    assert(
        unit is String && unit.trim().isNotEmpty,
        '_crossCheckTraceVsObserved called before _validateExpectedMagnitude '
        'enforced `unit` — reorder bug in parse().');
    final unitMicros = _unitToMicroseconds(unit as String);
    if (unitMicros == null) {
      // Non-time unit (bytes, frames, requests, …). The trace cannot
      // certify these quantities — their "runtime evidence" lives in
      // the non-temporal axis — so the ratio assertion is genuinely
      // inapplicable. Still an explicit branch rather than a bare
      // `return;` so the reason is visible at the call site.
      return;
    }

    int? beginTs;
    int? endTs;
    var beginCount = 0;
    var endCount = 0;
    for (final event in events) {
      if (event is! Map) continue;
      final ph = event['ph'];
      // Scenario markers are instant events. Chrome Trace uses lowercase
      // `i` canonically and uppercase `I` legacy. Perfetto's `traceconv`
      // — the conversion path from DevTools' on-disk `.pftrace` binary to
      // Chrome Trace JSON — emits Dart's `Timeline.instantSync(...)` as
      // `ph: 'n'` (async nestable instant) rather than `'i'`. Accept all
      // three so a capture round-trips regardless of which export path
      // produced it. The AB-1 assertion (scenario markers must be 0-dur
      // instant-class events, one begin + one end, inside the scenario
      // window) remains intact across the expanded set.
      if (ph != 'i' && ph != 'I' && ph != 'n') continue;
      final name = event['name'];
      if (name is! String) continue;
      final ts = event['ts'];
      if (ts is! num) continue;
      if (name == scenarioBeginMarker) {
        beginTs = ts.toInt();
        beginCount++;
      } else if (name == scenarioEndMarker) {
        endTs = ts.toInt();
        endCount++;
      }
    }
    if (beginCount == 0 || endCount == 0) {
      throw FormatException(
          'Capture is missing scenario markers. A time-unit capture must '
          'emit exactly one "$scenarioBeginMarker" and one '
          '"$scenarioEndMarker" instant event (ph="i", "I", or "n") so '
          'the AB-1 cross-check can bound the observed magnitude against a '
          'scoped work window. The global min/max over every work-phase '
          'event was bypassable by padding unrelated events to inflate '
          'the denominator. Got begin=$beginCount, end=$endCount.');
    }
    if (beginCount != 1 || endCount != 1) {
      throw FormatException(
          'Capture has duplicate scenario markers (begin=$beginCount, '
          'end=$endCount). Exactly one "$scenarioBeginMarker" and one '
          '"$scenarioEndMarker" are permitted; more than one creates '
          'ambiguity about which span to validate against.');
    }
    if (endTs! < beginTs!) {
      throw FormatException(
          'Scenario markers inverted: end ts ($endTs) precedes begin ts '
          '($beginTs). The capture declares a negative-duration '
          'scenario — reject rather than silently flip.');
    }
    final spanMicros = (endTs - beginTs).toDouble();
    if (spanMicros <= 0) {
      throw FormatException(
          'Scenario-marker span is non-positive ($spanMicros µs) — '
          'cannot have produced the claimed expectedMagnitude.observed '
          'of ${magnitude['observed']} $unit.');
    }
    final observed = (magnitude['observed'] as num).toDouble();
    final observedMicros = observed * unitMicros;
    // Belt-and-suspenders non-finite guard.
    // `_validateExpectedMagnitude` already rejects non-finite observed and
    // `spanMicros > 0` is checked above, so the derived ratios should be
    // finite positive today. If any upstream change regresses that,
    // comparing a non-finite ratio against `maxObservedToSpanRatio` would
    // silently bypass the AB-1 assertion (`NaN > x` is false, and
    // `Infinity > x` short-circuits without revealing which side blew up).
    // Reject explicitly so the diagnostic surfaces the offending derived
    // value before the threshold check.
    if (!observedMicros.isFinite) {
      throw FormatException(
          'Derived "observed × unit" is non-finite ($observedMicros µs). '
          'Upstream finite-positive guard on expectedMagnitude.observed '
          'regressed; AB-1 cross-check cannot proceed.');
    }
    final ratio = observedMicros / spanMicros;
    if (!ratio.isFinite) {
      throw FormatException('Derived trace-vs-observed ratio is non-finite '
          '($observedMicros µs / $spanMicros µs = $ratio). AB-1 '
          'cross-check cannot proceed.');
    }
    if (ratio > maxObservedToSpanRatio) {
      throw FormatException(
          'Trace-vs-observed cross-check failed: expectedMagnitude.observed '
          '= $observed $unit is ${ratio.toStringAsFixed(0)}× larger than '
          'the scenario-marker span ($spanMicros µs, bounded by '
          '"$scenarioBeginMarker" → "$scenarioEndMarker"). A real '
          'profile-mode capture of a $observed$unit scenario emits '
          'markers bracketing the full duration; a ratio above '
          '${maxObservedToSpanRatio.toInt()}× indicates a fabricated '
          'export or misplaced markers. Widen the scenario window to '
          'match the claim.');
    }
    // v0.16.4 post-review LOW-2: symmetric guard. If the scenario span
    // is wildly larger than the observed magnitude, the markers are
    // placed too wide — the window contains unrelated work (cold-start
    // warmup, idle dwell, follow-up requests), and the "observed"
    // claim no longer corresponds to what's inside the span. Same
    // ratio ceiling, inverted direction.
    if (skipInverseRatio) return;
    final inverseRatio = spanMicros / observedMicros;
    if (!inverseRatio.isFinite) {
      throw FormatException(
          'Derived inverse trace-vs-observed ratio is non-finite '
          '($spanMicros µs / $observedMicros µs = $inverseRatio). AB-1 '
          'cross-check cannot proceed.');
    }
    if (inverseRatio > maxObservedToSpanRatio) {
      throw FormatException(
          'Trace-vs-observed cross-check failed: scenario-marker span '
          '($spanMicros µs, bounded by "$scenarioBeginMarker" → '
          '"$scenarioEndMarker") is ${inverseRatio.toStringAsFixed(0)}× '
          'larger than expectedMagnitude.observed = $observed $unit. A '
          'span this much wider than the observed magnitude means the '
          'markers bracket unrelated work (warmup, dwell, other '
          'requests); a ratio above ${maxObservedToSpanRatio.toInt()}× '
          'indicates misplaced markers. Tighten the scenario window to '
          'match the claim.');
    }
  }

  static double? _unitToMicroseconds(String unit) {
    switch (unit.toLowerCase()) {
      case 'ns':
        return 0.001;
      case 'us':
      case 'µs':
        return 1.0;
      case 'ms':
        return 1000.0;
      case 's':
      case 'sec':
      case 'seconds':
        return 1000000.0;
      default:
        return null; // Non-time unit.
    }
  }

  static void _validateCaptureCommandAndScenario(
      Map<String, Object?> metadata) {
    final captureCommand = metadata['captureCommand'];
    if (captureCommand is! String || captureCommand.trim().isEmpty) {
      throw const FormatException(
          '"captureCommand" must be a non-empty string recording the '
          'command that produced the capture.');
    }
    // CLAUDE-R1-3: without this check, `captureCommand: "fvm flutter run"`
    // (no --profile) or `captureCommand: "."` satisfied the schema. The
    // whole point of runtimeVerified is that the capture came from
    // profile mode on a pinned device — the captured command must say so.
    if (!captureCommand.contains('--profile')) {
      throw FormatException(
          '"captureCommand" "$captureCommand" does not contain '
          '"--profile". Runtime-verified captures must be recorded in '
          'profile mode (e.g. `fvm flutter run --profile`). Debug-mode '
          'timings are not representative of production.');
    }
    final scenario = metadata['scenario'];
    if (scenario is! String || scenario.trim().length < 8) {
      throw FormatException(
          '"scenario" must be a non-empty string of at least 8 '
          'characters describing what the capture exercises (got '
          '${scenario is String ? '"$scenario"' : scenario.runtimeType}). '
          'One-word placeholders are rejected.');
    }
  }

  /// CODEX-R6-2: Minimal JSON scanner that walks the normalised text
  /// and flags duplicate keys within the same object. `dart:convert`'s
  /// `jsonDecode` takes the last write on duplicate keys silently, so
  /// an attacker can hide a second value from a human reviewer. This
  /// scanner runs before `jsonDecode` and throws a precise
  /// [FormatException] identifying the offending key.
  ///
  /// The scanner only tracks object and array nesting plus string
  /// tokens — scalars (numbers, true/false/null) are skipped because
  /// duplicate-key detection doesn't depend on their content.
  static void _detectDuplicateKeys(String jsonText) {
    final stack = <_JsonFrame>[];
    var pos = 0;
    final length = jsonText.length;

    while (pos < length) {
      final c = jsonText.codeUnitAt(pos);

      // Whitespace.
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        pos++;
        continue;
      }

      if (c == 0x7B /* { */) {
        stack.add(_JsonFrame(isObject: true));
        pos++;
        continue;
      }
      if (c == 0x7D /* } */) {
        if (stack.isNotEmpty) stack.removeLast();
        _advanceAfterValue(stack);
        pos++;
        continue;
      }
      if (c == 0x5B /* [ */) {
        stack.add(_JsonFrame(isObject: false));
        pos++;
        continue;
      }
      if (c == 0x5D /* ] */) {
        if (stack.isNotEmpty) stack.removeLast();
        _advanceAfterValue(stack);
        pos++;
        continue;
      }
      if (c == 0x22 /* " */) {
        final scanEnd = _findStringEnd(jsonText, pos);
        final raw = jsonText.substring(pos + 1, scanEnd);
        final decoded = _decodeJsonStringContent(raw);
        pos = scanEnd + 1;
        if (stack.isNotEmpty && stack.last.isObject && stack.last.nextIsKey) {
          if (!stack.last.keys.add(decoded)) {
            throw FormatException(
                'Duplicate JSON key "$decoded" in the same object. RFC '
                '8259 permits duplicate keys; Sleuth rejects them '
                'because `jsonDecode` silently takes the last write, '
                'which is a review-bypass surface — an attacker can '
                'show one value to a reviewer and certify another.');
          }
          stack.last.nextIsKey = false;
        } else {
          // String value — treat like any other value.
          _advanceAfterValue(stack);
        }
        continue;
      }
      if (c == 0x3A /* : */) {
        pos++;
        continue;
      }
      if (c == 0x2C /* , */) {
        if (stack.isNotEmpty && stack.last.isObject) {
          stack.last.nextIsKey = true;
        }
        pos++;
        continue;
      }
      // Any other char is the start of a scalar (number / true / false /
      // null). Skip to the next structural character.
      pos++;
      while (pos < length) {
        final cc = jsonText.codeUnitAt(pos);
        if (cc == 0x2C ||
            cc == 0x7D ||
            cc == 0x5D ||
            cc == 0x20 ||
            cc == 0x09 ||
            cc == 0x0A ||
            cc == 0x0D) {
          break;
        }
        pos++;
      }
      _advanceAfterValue(stack);
    }
  }

  static void _advanceAfterValue(List<_JsonFrame> stack) {
    // After consuming a value we remain in the same object context
    // waiting for ',' or '}'; the comma path flips `nextIsKey` back on.
    if (stack.isNotEmpty && stack.last.isObject) {
      stack.last.nextIsKey = false;
    }
  }

  /// Finds the closing `"` for a JSON string starting at [start] (which
  /// must point at the opening quote). Returns the index of the closing
  /// quote. Handles `\\` and `\"` escapes.
  static int _findStringEnd(String s, int start) {
    var i = start + 1;
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 0x5C /* \ */) {
        i += 2; // skip escape sequence
        continue;
      }
      if (c == 0x22 /* " */) return i;
      i++;
    }
    throw const FormatException(
        'Unterminated JSON string while scanning for duplicate keys.');
  }

  /// Decodes the content of a JSON string (between the quotes). Handles
  /// every escape sequence the JSON spec defines — including `\uXXXX`
  /// Unicode escapes and `\uD800\uDC00` surrogate pairs — so two keys
  /// that `jsonDecode` treats as identical are also treated as identical
  /// here.
  ///
  /// AB-2: the previous implementation fell back to the verbatim raw
  /// bytes on `\u…`, so `"captureDate"` and `"\u0063aptureDate"` compared
  /// as distinct in our scanner while `jsonDecode` collapsed them to the
  /// same key and silently took last-write-wins. That is precisely the
  /// review-bypass surface the duplicate-key scanner exists to close, so
  /// full `\u` decoding is required for soundness.
  static String _decodeJsonStringContent(String raw) {
    if (!raw.contains(r'\')) return raw;
    final buf = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (c == r'\' && i + 1 < raw.length) {
        final next = raw[i + 1];
        switch (next) {
          case '"':
            buf.write('"');
            i++;
            break;
          case r'\':
            buf.write(r'\');
            i++;
            break;
          case '/':
            buf.write('/');
            i++;
            break;
          case 'b':
            buf.writeCharCode(0x08);
            i++;
            break;
          case 'f':
            buf.writeCharCode(0x0C);
            i++;
            break;
          case 'n':
            buf.writeCharCode(0x0A);
            i++;
            break;
          case 'r':
            buf.writeCharCode(0x0D);
            i++;
            break;
          case 't':
            buf.writeCharCode(0x09);
            i++;
            break;
          case 'u':
            if (i + 5 >= raw.length) {
              throw const FormatException(
                  'Malformed \\u escape in JSON string (truncated).');
            }
            final hex = raw.substring(i + 2, i + 6);
            final code = int.tryParse(hex, radix: 16);
            if (code == null) {
              throw FormatException(
                  'Malformed \\u escape "$hex" in JSON string.');
            }
            // Surrogate pair: if this is a high surrogate and another
            // `\uXXXX` follows, combine them into one astral code point
            // so the decoded form matches what `jsonDecode` produces.
            if (code >= 0xD800 &&
                code <= 0xDBFF &&
                i + 11 < raw.length &&
                raw[i + 6] == r'\' &&
                raw[i + 7] == 'u') {
              final lowHex = raw.substring(i + 8, i + 12);
              final low = int.tryParse(lowHex, radix: 16);
              if (low != null && low >= 0xDC00 && low <= 0xDFFF) {
                final codePoint =
                    0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                buf.writeCharCode(codePoint);
                i += 11;
                break;
              }
            }
            buf.writeCharCode(code);
            i += 5;
            break;
          default:
            // Preserve unknown escape verbatim — the JSON spec has no
            // other escapes, so this path implies malformed input that
            // `jsonDecode` will reject downstream.
            buf.write(c);
            buf.write(next);
            i++;
        }
      } else {
        buf.write(c);
      }
    }
    return buf.toString();
  }

  /// Convenience wrapper that reads a file and calls [parse]. Adds a
  /// scenario-name ↔ file-path cross-check the byte-only [parse] cannot
  /// run (it has no path context). Captures placed in `_fixtures/`
  /// subdirectories are skipped — those are negative-test fixtures with
  /// deliberately unrelated scenarios.
  static Map<String, Object?> parseFile(File file) {
    if (!file.existsSync()) {
      throw FormatException('Capture file does not exist: ${file.path}');
    }
    final metadata = parse(file.readAsBytesSync());
    _validateScenarioMatchesPath(file, metadata);
    return metadata;
  }

  /// Cross-checks `metadata.scenario` against the file's basename. A
  /// capture's scenario field has to relate to its file by one of two
  /// shapes:
  ///
  ///   * Basename-exact: `scenario == basenameWithoutExtension(file)`.
  ///   * Suffix-of-scenario:
  ///     `scenario.endsWith("_${basenameWithoutExtension(file)}")` —
  ///     admits both directory-prefixed
  ///     (`frame_timing_jank_detected_below`) and family-prefixed
  ///     (`rebuild_activity_below`) shapes.
  ///
  /// Without the cross-check a capture file can be moved or copied with
  /// its scenario field stale — the schema accepts it and the bracket
  /// audit certifies the wrong scenario as evidence. Per-directory
  /// uniformity (every file in one directory uses the same shape) is
  /// enforced separately by the audit-set walker.
  ///
  /// Only escape: an immediate parent directory named `_fixtures`
  /// (negative-test fixtures with deliberately unrelated scenarios).
  /// All other captures — including ones whose scenario is prose with
  /// whitespace or Unicode punctuation — must satisfy the basename-exact
  /// or suffix shape. A content-shape escape would let a stale
  /// committed capture pass simply by phrasing its scenario as prose,
  /// re-opening exactly the gap the cross-check exists to close.
  static void _validateScenarioMatchesPath(
      File file, Map<String, Object?> metadata) {
    // Route through `package:path` for cross-platform consistency and
    // correct trailing-separator handling. Hand-rolled `split(separator)`
    // returns an empty trailing element when the parent path ends with a
    // separator (e.g. `/foo/bar/`); `p.basename` strips the separator
    // first and returns `'bar'`, matching the audit-side helper.
    final parentName = p.basename(file.parent.path);
    if (parentName == '_fixtures') return;
    final scenario = metadata['scenario'];
    if (scenario is! String) return;
    // `package:path` treats `.json` (no name before the extension) as a
    // dotfile basename, returning `.json` itself rather than an empty
    // string. That makes the suffix rule below strict (`endsWith('_.json')`)
    // and rejects operator-typo files with the standard cross-check
    // error — no separate empty-basename guard needed.
    final basenameNoExt = p.basenameWithoutExtension(file.path);
    if (scenario == basenameNoExt) return;
    if (scenario.endsWith('_$basenameNoExt')) return;
    throw FormatException(
        '"sleuthMetadata.scenario" "$scenario" does not match the capture '
        'file path. Expected either "$basenameNoExt" (basename-exact) or '
        'a value ending in "_$basenameNoExt" (e.g. '
        '"${parentName}_$basenameNoExt") for file ${file.path}. A scenario '
        'that disagrees with the file name silently certifies the wrong '
        'evidence when the file is moved or copied with a stale field.');
  }

  /// Validates a three-capture bracket against [threshold] in [unit].
  ///
  /// - `below.observed <  threshold`
  /// - `threshold <= at.observed <= threshold * (1 + atTolerance)`
  /// - `above.observed >  threshold`
  ///
  /// Each file must exist and parse cleanly. Any violation throws
  /// [FormatException] with the failing file identified.
  ///
  /// [atTolerance] defaults to [defaultAtTolerance] (10%). Pass a smaller
  /// value for detectors whose captures cluster tightly.
  /// Default ceiling multiplier applied to the `above` capture's observed
  /// magnitude. Guards against an `above` capture whose magnitude drifts
  /// so far past [threshold] that it ambiently brackets an adjacent
  /// higher-severity threshold. Added in v0.16.4.
  static const double defaultAboveCeilingMultiplier = 2.0;

  static void validateBracket({
    required File belowFile,
    required File atFile,
    required File aboveFile,
    required num threshold,
    required String unit,
    double atTolerance = defaultAtTolerance,
    double aboveCeilingMultiplier = defaultAboveCeilingMultiplier,
    bool requireDetectorTraceRecord = false,
    String? stableId,
    String? severityLabel,
    bool requireUniqueDetectedAtMicros = false,
    String? observedAxisArgKey,
    double observedAxisTolerance = 0.25,
    String observedAxisReduction = 'max',
  }) {
    _validateOneBracket(
      BracketSpec(
        stableId: stableId ?? '',
        severityLabel: severityLabel ?? '',
        threshold: threshold,
        unit: unit,
        coveredThresholds: const <String>{},
        profileCapturePaths: const <String>[],
        atTolerance: atTolerance,
        aboveCeilingMultiplier: aboveCeilingMultiplier,
        observedAxisArgKey: observedAxisArgKey,
        observedAxisTolerance: observedAxisTolerance,
        observedAxisReduction: observedAxisReduction,
        requireUniqueDetectedAtMicros: requireUniqueDetectedAtMicros,
        requireDetectorTraceRecord: requireDetectorTraceRecord,
      ),
      belowFile: belowFile,
      atFile: atFile,
      aboveFile: aboveFile,
    );
  }

  /// Spec-driven bracket validation entry point. Audit-side iteration over
  /// `DetectorMetadata.additionalBrackets` calls this once per spec; the
  /// public `validateBracket(...)` is preserved for existing test/audit
  /// call sites that pass named args.
  ///
  /// Behavior is identical to `validateBracket` — same error messages,
  /// same numeric checks, same trace-record search. The only difference
  /// is the call shape: spec-driven instead of named-args.
  static void validateBracketSpec(
    BracketSpec spec, {
    required File belowFile,
    required File atFile,
    required File aboveFile,
  }) {
    _validateOneBracket(
      spec,
      belowFile: belowFile,
      atFile: atFile,
      aboveFile: aboveFile,
    );
  }

  static void _validateOneBracket(
    BracketSpec spec, {
    required File belowFile,
    required File atFile,
    required File aboveFile,
  }) {
    final stableId = spec.stableId.isEmpty ? null : spec.stableId;
    final severityLabel =
        spec.severityLabel.isEmpty ? null : spec.severityLabel;
    final threshold = spec.threshold;
    final unit = spec.unit;
    final atTolerance = spec.atTolerance ?? defaultAtTolerance;
    final aboveCeilingMultiplier =
        spec.aboveCeilingMultiplier ?? defaultAboveCeilingMultiplier;
    final requireDetectorTraceRecord = spec.requireDetectorTraceRecord;
    final requireUniqueDetectedAtMicros = spec.requireUniqueDetectedAtMicros;
    final observedAxisArgKey = spec.observedAxisArgKey;
    final observedAxisTolerance = spec.observedAxisTolerance;
    final observedAxisReduction = spec.observedAxisReduction;

    if (requireDetectorTraceRecord && (stableId == null || stableId.isEmpty)) {
      throw const FormatException(
          '`validateBracket` was called with requireDetectorTraceRecord: true '
          'but stableId was null or empty. Trace-record search needs the '
          'detector\'s stableId to compose the expected event name.');
    }
    if (requireDetectorTraceRecord &&
        (severityLabel == null || severityLabel.isEmpty)) {
      throw const FormatException(
          '`validateBracket` was called with requireDetectorTraceRecord: true '
          'but severityLabel was null or empty. The bracket validates a '
          'specific severity threshold (e.g. warning at 8 ms vs critical at '
          '16 ms); the trace-record proof must match THAT severity, not just '
          'any emission on the same stableId. Pass IssueSeverity.warning.name '
          'or .critical.name (the wire-format string).');
    }
    // Reject non-finite numeric inputs before any comparison. Dart's
    // NaN-comparison semantics return false for every comparison
    // against NaN, which silently bypasses the bracket, at-band, and
    // ceiling guards below. Infinity disables the ceiling similarly
    // (threshold * Infinity = Infinity; observed > Infinity = false).
    _requireFinitePositive(threshold, 'bracketThreshold');
    _requireFiniteNonNegative(atTolerance, 'atTolerance');
    _requireFinitePositive(aboveCeilingMultiplier, 'aboveCeilingMultiplier');

    final below = _parseOrThrowWithLabel(belowFile, 'below');
    final at = _parseOrThrowWithLabel(atFile, 'at');
    final above = _parseOrThrowWithLabel(aboveFile, 'above');

    // AGR-1 (Bundle E): cross-check that all three captures declare the
    // same unit AND it equals the caller's `unit`. Without this a tier
    // raise could assemble a bracket from captures in mismatched scales
    // (`below` in ms, `at` in µs, `above` in s) and the observed-vs-
    // threshold comparison downstream silently compared numbers on
    // different axes. `_validateExpectedMagnitude` enforces unit
    // presence per-capture; this step enforces bracket-level agreement.
    final normalisedBracketUnit = unit.trim().toLowerCase();
    if (normalisedBracketUnit.isEmpty) {
      throw const FormatException(
          '`validateBracket` was called with an empty `unit` — bracketing '
          'requires a non-empty unit string matching every capture\'s '
          'expectedMagnitude.unit.');
    }
    final triad = <(String, Map<String, Object?>, File)>[
      ('below', below, belowFile),
      ('at', at, atFile),
      ('above', above, aboveFile),
    ];
    for (final entry in triad) {
      final captureUnit = _readUnit(entry.$2);
      if (captureUnit.trim().toLowerCase() != normalisedBracketUnit) {
        throw FormatException(
            'Bracket unit mismatch: "${entry.$1}" capture declares '
            'expectedMagnitude.unit "$captureUnit" but validateBracket '
            'was called with unit "$unit". All three captures and the '
            'caller must agree on the unit. File: ${entry.$3.path}');
      }
    }

    // NEW-CODEX-1 (Bundle G): provenance cross-check. Three captures
    // bracketing a threshold are only comparable if they came from the
    // same reference environment — same device, same OS version, same
    // Flutter major.minor.patch. Before Bundle G, `validateBracket`
    // checked only the numeric observed vs threshold relationship, so a
    // bracket could assemble `below` from a Pixel 7 / Android 14 run,
    // `at` from an iPhone 13 mini / iOS 17.6.1 run, and `above` from
    // yet a third environment. `_validateExpectedMagnitude` +
    // `_validateDevicePolicy` enforce that each capture individually
    // names an approved (device, OS) pair and pinned Flutter major.minor,
    // but neither step cross-references the triad. This loop closes
    // that gap: any mismatch on device, OS, or full Flutter version
    // across the three captures is a provenance error, and the
    // bracketing rule should not be interpreted against the claimed
    // threshold.
    for (final field in const <String>[
      'device',
      'deviceOsVersion',
      'flutterVersion',
    ]) {
      final belowValue = below[field];
      final atValue = at[field];
      final aboveValue = above[field];
      if (belowValue != atValue || belowValue != aboveValue) {
        throw FormatException('Bracket provenance mismatch on "$field": below='
            '${belowValue is String ? '"$belowValue"' : belowValue}, at='
            '${atValue is String ? '"$atValue"' : atValue}, above='
            '${aboveValue is String ? '"$aboveValue"' : aboveValue}. '
            'Bracketing a threshold requires the three captures to come '
            'from the same reference environment — otherwise the '
            'observed values are not comparable. Files: '
            '${belowFile.path}, ${atFile.path}, ${aboveFile.path}.');
      }
    }

    final belowObs = _readObserved(below);
    final atObs = _readObserved(at);
    final aboveObs = _readObserved(above);

    if (belowObs >= threshold) {
      throw FormatException(
          'Bracket violation: $unit "below" observed ($belowObs) must be '
          'strictly less than threshold ($threshold). File: ${belowFile.path}');
    }
    final atUpper = threshold * (1 + atTolerance);
    if (atObs < threshold || atObs > atUpper) {
      throw FormatException(
          'Bracket violation: $unit "at" observed ($atObs) must lie in '
          '[$threshold, $atUpper] (threshold × ${1 + atTolerance}). '
          'File: ${atFile.path}');
    }
    if (aboveObs <= threshold) {
      throw FormatException(
          'Bracket violation: $unit "above" observed ($aboveObs) must be '
          'strictly greater than threshold ($threshold). '
          'File: ${aboveFile.path}');
    }
    // Upper bound on `above` so a bracket cannot drift into an
    // adjacent higher-severity threshold.
    // A NetworkMonitor warning-tier raise (threshold 1000 ms) whose
    // `above` is recorded at 3117 ms ambiently brackets the 3000 ms
    // critical tier too — the prose scope boundary can't un-bracket
    // the artifact on disk.
    if (aboveCeilingMultiplier <= 1.0) {
      throw FormatException(
          'aboveCeilingMultiplier ($aboveCeilingMultiplier) must be > 1.0 — '
          'a ceiling at or below the threshold makes the "above" bracket '
          'unreachable.');
    }
    // Guard against a ceiling that collides with the at-band upper
    // bound. If `aboveCeilingMultiplier <=
    // 1 + atTolerance`, the "above" band (threshold, threshold ×
    // aboveCeilingMultiplier] either collapses (equal) or is entirely
    // nested inside the at-band (less), making the triad unsatisfiable
    // without the error message naming the real cause. Reject at call
    // time so the misuse is obvious.
    final atUpperMultiplier = 1 + atTolerance;
    if (aboveCeilingMultiplier <= atUpperMultiplier) {
      throw FormatException(
          'aboveCeilingMultiplier ($aboveCeilingMultiplier) must exceed '
          '1 + atTolerance ($atUpperMultiplier) to leave a non-empty '
          '"above" band. At or below this value the above bracket '
          'collapses into the at-band and the triad is unsatisfiable. '
          'Either lower atTolerance or raise aboveCeilingMultiplier.');
    }
    final aboveCeiling = threshold * aboveCeilingMultiplier;
    if (aboveObs > aboveCeiling) {
      throw FormatException(
          'Bracket violation: $unit "above" observed ($aboveObs) exceeds '
          'ceiling ($aboveCeiling = threshold × $aboveCeilingMultiplier). '
          'Re-record within (threshold, ceiling] so the artifact cannot '
          'provide ambient evidence for an adjacent higher-severity '
          'threshold. File: ${aboveFile.path}');
    }
    // Monotonic-ordering invariant. With a wide `atTolerance` (e.g.
    // 0.50 → at-band [threshold, threshold × 1.50]) and the schema's
    // permissive above-band lower bound (just-above-threshold), an at
    // capture can land numerically ABOVE an above capture even though
    // each individually satisfies its own bracket — semantically
    // inverted but otherwise schema-conformant. Reject the inversion
    // explicitly. (The `below < at` half is already implied by
    // `below < threshold ≤ at`, so the only non-trivial check is
    // `above > at`.)
    if (aboveObs <= atObs) {
      throw FormatException(
          'Bracket violation: $unit "above" observed ($aboveObs) must be '
          'strictly greater than "at" observed ($atObs). The bracket '
          'rule expects below < at < above magnitudes; an inverted '
          'triad provides no ordering evidence about the threshold '
          'even when each leg individually satisfies its constraint. '
          'Re-record `above` with a larger magnitude (within the '
          'above-ceiling) or `at` with a smaller magnitude (within '
          'the at-band). Files: at=${atFile.path}, '
          'above=${aboveFile.path}');
    }

    if (requireDetectorTraceRecord) {
      // SchemaVersion gate. Captures recorded under v0.18.0+ declare
      // `sleuthMetadata.schemaVersion` so the parser can distinguish a
      // pre-trace-record orphan (NetworkMonitor's v0.16.x triad) from a
      // contract-conformant runtimeVerified capture.
      for (final entry in triad) {
        final declared = entry.$2['schemaVersion'];
        if (declared != captureSchemaVersion) {
          throw FormatException(
              'Capture missing or stale `sleuthMetadata.schemaVersion`: '
              '"${entry.$1}" capture declared "${declared ?? 'null'}" but '
              'this validation requires "$captureSchemaVersion". '
              'Re-record under the v0.18.0+ procedure (see '
              'test/validation/captures/<detector>/README.md) to populate '
              'the schemaVersion field. File: ${entry.$3.path}');
        }
      }
      // Trace-record search. Each capture inside the at+above pair must
      // contain a `sleuth.issue.<stableId>.<severity>` instant event
      // whose `ts` lies inside the scenario marker span. The `below`
      // capture is sub-threshold by definition — the detector did not
      // fire — so absence is expected and verified separately.
      _requireIssueTraceRecord(at, atFile, stableId!,
          severityLabel: severityLabel!,
          context: 'at capture',
          requireUniqueDetectedAtMicros: requireUniqueDetectedAtMicros,
          observedAxisArgKey: observedAxisArgKey,
          observedAxisExpected: atObs,
          observedAxisTolerance: observedAxisTolerance,
          observedAxisReduction: observedAxisReduction);
      _requireIssueTraceRecord(above, aboveFile, stableId,
          severityLabel: severityLabel,
          context: 'above capture',
          requireUniqueDetectedAtMicros: requireUniqueDetectedAtMicros,
          observedAxisArgKey: observedAxisArgKey,
          observedAxisExpected: aboveObs,
          observedAxisTolerance: observedAxisTolerance,
          observedAxisReduction: observedAxisReduction);
      _requireNoIssueTraceRecord(below, belowFile, stableId,
          severityLabel: severityLabel, context: 'below capture');
    }
  }

  /// Searches [metadata]'s associated `traceEvents` for an instant
  /// event with name `sleuth.issue.<stableId>.<severityLabel>` whose
  /// `ts` lies inside the scenario marker span. Throws
  /// [FormatException] when none is found.
  ///
  /// Severity-scoped: a capture bracketing the warning threshold
  /// (e.g. 8 ms) must contain `sleuth.issue.<id>.warning`, not
  /// `.critical`. Accepting either would let a `.critical` event
  /// satisfy a warning-tier audit and vice versa, defeating the
  /// purpose of bracket-with-trace-proof.
  static void _requireIssueTraceRecord(
    Map<String, Object?> metadata,
    File file,
    String stableId, {
    required String severityLabel,
    required String context,
    bool requireUniqueDetectedAtMicros = false,
    String? observedAxisArgKey,
    num? observedAxisExpected,
    double observedAxisTolerance = 0.25,
    String observedAxisReduction = 'max',
  }) {
    final traceEvents = metadata['_rawTraceEvents'] as List?;
    if (traceEvents == null) {
      // Bridge: parseFile only returns the sleuthMetadata block,
      // not the full root. Re-parse the file to access traceEvents.
      // Acceptable since validateBracket is not on a hot path.
      final raw = file.readAsBytesSync();
      final root = json.decode(_decodeUtf8(raw)) as Map<String, Object?>;
      final events = root['traceEvents'] as List;
      _checkIssueTraceRecordPresent(
          events, stableId, severityLabel, file, context,
          requireUniqueDetectedAtMicros: requireUniqueDetectedAtMicros,
          observedAxisArgKey: observedAxisArgKey,
          observedAxisExpected: observedAxisExpected,
          observedAxisTolerance: observedAxisTolerance,
          observedAxisReduction: observedAxisReduction);
      return;
    }
    _checkIssueTraceRecordPresent(
        traceEvents, stableId, severityLabel, file, context,
        requireUniqueDetectedAtMicros: requireUniqueDetectedAtMicros,
        observedAxisArgKey: observedAxisArgKey,
        observedAxisExpected: observedAxisExpected,
        observedAxisTolerance: observedAxisTolerance,
        observedAxisReduction: observedAxisReduction);
  }

  static void _checkIssueTraceRecordPresent(
    List events,
    String stableId,
    String severityLabel,
    File file,
    String context, {
    bool requireUniqueDetectedAtMicros = false,
    String? observedAxisArgKey,
    num? observedAxisExpected,
    double observedAxisTolerance = 0.25,
    String observedAxisReduction = 'max',
  }) {
    final (beginTs, endTs) = _scenarioSpan(events, file);
    final expected = 'sleuth.issue.$stableId.$severityLabel';
    var matchCount = 0;
    final uniqueDetectedAtMicros = <String>{};
    // Track (ts, value) pairs so the reduction strategy can branch on
    // 'max' (default) or 'last' (highest-ts) — required for windowed-
    // aggregate observables on rolling buffers (e.g. FrameTimingDetector
    // jankPercent over a 240-frame buffer is non-monotone as the buffer
    // grows and slides).
    final observedAxisSamples = <({int ts, num value})>[];
    for (final event in events) {
      if (event is! Map) continue;
      final ph = event['ph'];
      if (ph != 'i' && ph != 'I' && ph != 'n') continue;
      if (event['name'] != expected) continue;
      final ts = event['ts'];
      if (ts is! num) continue;
      final tsInt = ts.toInt();
      if (tsInt < beginTs || tsInt > endTs) continue;
      matchCount++;
      // Producer side stamps `detectedAtMicros` on each emission via
      // CaptureHelper.composeIssueEvent. Track the unique-value set so
      // the uniqueness invariant below catches single-issue replay
      // (N records all with the same `detectedAtMicros` — would pass
      // a presence-only check).
      final args = event['args'];
      if (args is Map) {
        final m = args['detectedAtMicros'];
        if (m is String && m.isNotEmpty) {
          uniqueDetectedAtMicros.add(m);
        } else if (m is num) {
          uniqueDetectedAtMicros.add(m.toString());
        }
        if (observedAxisArgKey != null) {
          final axis = args[observedAxisArgKey];
          num? parsedAxis;
          if (axis is String && axis.isNotEmpty) {
            parsedAxis = num.tryParse(axis);
          } else if (axis is num) {
            parsedAxis = axis;
          }
          if (parsedAxis != null) {
            observedAxisSamples.add((ts: tsInt, value: parsedAxis));
          }
        }
      }
    }
    if (matchCount == 0) {
      throw FormatException(
          'Missing detector trace record in $context: expected an instant '
          'event named "$expected" with `ts` inside the scenario span '
          '[$beginTs, $endTs] (the work window between '
          'sleuth.scenario.begin and sleuth.scenario.end). A '
          '`runtimeVerified` capture must contain proof the detector '
          'fired AT THE CLAIMED SEVERITY during the captured scenario; '
          'a `.critical` event does not satisfy a `warning`-tier audit '
          'and vice versa. File: ${file.path}');
    }
    // Uniqueness invariant (opt-in via requireUniqueDetectedAtMicros).
    // Producer-side dedup (SleuthController._captureEmittedKeys, v0.18.1+)
    // guarantees that every emitted issue trace event carries a distinct
    // `detectedAtMicros`. The audit gate enables this when validating
    // captures recorded under v0.18.1+ binaries; legacy v0.18.0 captures
    // (where re-emission inflation is expected) keep the presence-only
    // check by leaving the flag false.
    //
    // The check has two prongs against forgery: (a) every matched event
    // MUST carry a parseable `detectedAtMicros` arg, and (b) the count
    // of unique values MUST equal the match count. Without prong (a) a
    // forger could replay one event N times and strip the arg from
    // every copy — `uniqueDetectedAtMicros` stays empty and a
    // presence-only "is the arg there?" check would silently pass.
    if (requireUniqueDetectedAtMicros) {
      if (uniqueDetectedAtMicros.length != matchCount) {
        throw FormatException(
            'Inflated detector trace records in $context: expected each '
            '"$expected" event to carry a unique, parseable '
            '`detectedAtMicros` arg (producer-side dedup invariant). '
            'Found $matchCount records but only '
            '${uniqueDetectedAtMicros.length} distinct '
            '`detectedAtMicros` value(s) inside the scenario span. This '
            'indicates either capture replay/forgery (N records '
            'replayed from one, possibly with the arg stripped) or a '
            'pre-v0.18.1 capture binary without producer dedup. '
            'Re-record with v0.18.1+ to refresh. File: ${file.path}');
      }
    }
    // Detector-observed-axis cross-check (opt-in via observedAxisArgKey).
    // Captures' `expectedMagnitude.observed` is a SEND-side estimate
    // computed by the capture helper screen (e.g.
    // `totalCallsSent / elapsedSec`). Detectors stamp their authoritative
    // observed axis value (e.g. `_recentCallCount` for PlatformChannel)
    // into the trace event args so the audit gate can confirm the two
    // numbers agree within tolerance. Without this, iOS coalescing or
    // dropped `b` events could produce a capture where the operator
    // reports an `at`-band send rate but the detector actually saw an
    // `above`-band count — bracket bands would silently misalign.
    //
    // Backward compatible: pre-v0.19.5 captures (recorded before
    // detectors started exporting `observedCount`) have no matching arg
    // and the cross-check is skipped. Captures recorded under v0.19.5+
    // carry the arg and exercise the check.
    if (observedAxisArgKey != null &&
        observedAxisExpected != null &&
        observedAxisSamples.isNotEmpty) {
      _requireFinitePositive(observedAxisExpected, 'observedAxisExpected');
      _requireFiniteNonNegative(observedAxisTolerance, 'observedAxisTolerance');
      // Reduction strategy: 'max' (default) for monotone-per-emission
      // axes (NetworkMonitor.slow_request duration, MemoryPressure.heap_growing
      // slope) and cooldown-collapsing detectors (PlatformChannel,
      // single-fire-per-scenario). 'last' (highest-ts) for windowed-
      // aggregate axes whose observable is non-monotone as the buffer
      // grows and slides — e.g. FrameTimingDetector.jank_detected percent
      // over a rolling 240-frame buffer where early small-sample-size
      // ratios spike high before settling.
      late num observed;
      switch (observedAxisReduction) {
        case 'last':
          observedAxisSamples.sort((a, b) => a.ts.compareTo(b.ts));
          observed = observedAxisSamples.last.value;
          break;
        case 'max':
        default:
          observed = observedAxisSamples
              .map((s) => s.value)
              .reduce((a, b) => a.toDouble() > b.toDouble() ? a : b);
      }
      final lower = observedAxisExpected * (1 - observedAxisTolerance);
      final upper = observedAxisExpected * (1 + observedAxisTolerance);
      if (observed < lower || observed > upper) {
        throw FormatException(
            'Detector-observed axis cross-check failed in $context: '
            'capture\'s `expectedMagnitude.observed` ($observedAxisExpected) '
            'and trace-record `args["$observedAxisArgKey"]` ($observed) '
            'diverge beyond ±${(observedAxisTolerance * 100).toStringAsFixed(0)}% '
            '(allowed band [$lower, $upper]). The capture screen reports a '
            'send-side estimate; the trace record carries the detector-'
            'observed value. A divergence this wide indicates iOS '
            'coalescing, dropped events, or a mislabeled bracket leg — '
            'the operator may have reported an `at`-band send rate while '
            'the detector saw an above-band count (or vice versa). '
            'Re-record the leg. File: ${file.path}');
      }
    }
  }

  static void _requireNoIssueTraceRecord(
    Map<String, Object?> metadata,
    File file,
    String stableId, {
    required String severityLabel,
    required String context,
  }) {
    // Reuse `_rawTraceEvents` stashed by `_parseOrThrowWithLabel` so
    // the bracket triad is parsed exactly once (M2). Fall back to a
    // direct read when called outside `validateBracket` (no current
    // caller, but defensive — preserves the helper's invariant).
    final List events;
    final stashed = metadata['_rawTraceEvents'];
    if (stashed is List) {
      events = stashed;
    } else {
      final raw = file.readAsBytesSync();
      final root = json.decode(_decodeUtf8(raw)) as Map<String, Object?>;
      events = root['traceEvents'] as List;
    }
    final (beginTs, endTs) = _scenarioSpan(events, file);
    final expected = 'sleuth.issue.$stableId.$severityLabel';
    for (final event in events) {
      if (event is! Map) continue;
      final ph = event['ph'];
      if (ph != 'i' && ph != 'I' && ph != 'n') continue;
      if (event['name'] != expected) continue;
      final ts = event['ts'];
      if (ts is! num) continue;
      final tsInt = ts.toInt();
      if (tsInt >= beginTs && tsInt <= endTs) {
        throw FormatException(
            'Unexpected detector trace record in $context: found instant '
            'event "$expected" inside the scenario span. The `below` '
            'capture is sub-threshold and the detector should NOT fire '
            'at this severity — re-record below the threshold or pick '
            'a smaller magnitude. File: ${file.path}');
      }
    }
  }

  /// Returns (beginTs, endTs) tuple by locating
  /// [scenarioBeginMarker] / [scenarioEndMarker] instant events.
  /// Throws when markers are missing or duplicated.
  static (int, int) _scenarioSpan(List events, File file) {
    int? beginTs;
    int? endTs;
    var beginCount = 0;
    var endCount = 0;
    for (final event in events) {
      if (event is! Map) continue;
      final ph = event['ph'];
      if (ph != 'i' && ph != 'I' && ph != 'n') continue;
      final name = event['name'];
      if (name is! String) continue;
      final ts = event['ts'];
      if (ts is! num) continue;
      if (name == scenarioBeginMarker) {
        beginTs = ts.toInt();
        beginCount++;
      } else if (name == scenarioEndMarker) {
        endTs = ts.toInt();
        endCount++;
      }
    }
    if (beginCount != 1 || endCount != 1) {
      throw FormatException(
          'Scenario markers malformed in ${file.path}: expected exactly one '
          '"$scenarioBeginMarker" and one "$scenarioEndMarker" instant '
          'event, found beginCount=$beginCount, endCount=$endCount. '
          'Trace-record search needs a unique scenario span.');
    }
    return (beginTs!, endTs!);
  }

  // ---------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------

  /// Rejects NaN, +Infinity, -Infinity, and non-positive numeric
  /// inputs at the boundary of every guard that compares against
  /// them.
  ///
  /// Motivation: Dart's IEEE-754 semantics make every comparison
  /// against NaN return `false` — `NaN < x`, `NaN > x`, `NaN <= x`,
  /// `NaN >= x`, `NaN == NaN` all evaluate to `false`. This silently
  /// bypasses every bracket/magnitude guard in the schema module. A
  /// `bracketThreshold: double.nan` makes `below.observed >= NaN`,
  /// `at.observed < NaN`, `above.observed <= NaN`, and
  /// `above.observed > ceiling` all fall through. An
  /// `aboveCeilingMultiplier: double.infinity` makes the at-band
  /// collision guard (`<= 1 + atTolerance`) pass and the ceiling
  /// (`threshold * infinity = infinity`) unreachable. Same class of
  /// bypass hits `expectedMagnitude.{min, observed, max}`.
  ///
  /// Callers: every numeric-read site in this module. The helper is
  /// intentionally strict (positive, not non-negative) — the schema's
  /// quantities (milliseconds, bytes, frame counts, thresholds,
  /// multipliers) are strictly positive in practice. Use
  /// [_requireFiniteNonNegative] for tolerance-style fields where 0
  /// is a meaningful tight-band value.
  static num _requireFinitePositive(num value, String fieldName) {
    if (!value.isFinite) {
      throw FormatException(
          '"$fieldName" must be a finite number (got $value). NaN, '
          '+Infinity, and -Infinity are rejected because Dart\'s '
          'NaN-comparison semantics silently bypass every downstream '
          'bracket and magnitude guard. Exponent-overflow JSON forms '
          'like 1e400 decode to Infinity — canonicalise the capture '
          'or pin the tier metadata to a finite numeric value.');
    }
    if (value <= 0) {
      throw FormatException(
          '"$fieldName" must be strictly positive (got $value). The '
          'quantities this schema gates (milliseconds, bytes, frame '
          'counts, thresholds, multipliers) are strictly positive in '
          'practice.');
    }
    return value;
  }

  /// Companion to [_requireFinitePositive] for tolerance-style fields
  /// where 0 is a valid tight-band value (e.g. `atTolerance: 0` means
  /// the `at` capture must equal threshold exactly).
  static num _requireFiniteNonNegative(num value, String fieldName) {
    if (!value.isFinite) {
      throw FormatException(
          '"$fieldName" must be a finite number (got $value). NaN, '
          '+Infinity, and -Infinity are rejected because Dart\'s '
          'NaN-comparison semantics silently bypass every downstream '
          'bracket and magnitude guard.');
    }
    if (value < 0) {
      throw FormatException('"$fieldName" must be non-negative (got $value).');
    }
    return value;
  }

  static String _decodeUtf8(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException catch (e) {
      throw FormatException(
          'Capture is not valid UTF-8: ${e.message}. DevTools exports '
          'are UTF-8 encoded; re-export from DevTools if this was '
          'hand-edited.');
    }
  }

  static String _stripBomAndNormaliseLineEndings(String input) {
    var s = input;
    // After `utf8.decode`, a legitimate UTF-8 BOM (`EF BB BF` raw) arrives
    // as the single Unicode code point U+FEFF at the head of the string.
    // UTF-16 / UTF-32 BOMs never reach this path — `_decodeUtf8` rejects
    // them with a FormatException. We only need to handle the decoded
    // form here.
    if (s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF) {
      s = s.substring(1);
    }
    // Normalise CRLF and lone CR to LF. jsonDecode tolerates both in
    // practice but an author's editor settings can introduce surprises
    // that break downstream consumers of the raw string.
    s = s.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    return s;
  }

  static void _validateDevicePolicy(Map<String, Object?> metadata) {
    final device = metadata['device'];
    final osVersion = metadata['deviceOsVersion'];
    if (device is! String || device.trim().isEmpty) {
      throw const FormatException(
          '"device" must be a non-empty string naming a pinned reference '
          'device.');
    }
    if (osVersion is! String || osVersion.trim().isEmpty) {
      throw const FormatException(
          '"deviceOsVersion" must be a non-empty string.');
    }
    final allowed = approvedDevicePairs[device];
    if (allowed == null) {
      throw FormatException(
          '"device" "$device" is not an approved reference device. '
          'Allowed: ${approvedDevicePairs.keys.toList()..sort()}. '
          'Pinned-device policy lives in doc/reference_devices.md; add new '
          'devices via an annual rotation release, not an individual tier '
          'raise PR.');
    }
    if (!allowed.contains(osVersion)) {
      throw FormatException(
          '"deviceOsVersion" "$osVersion" is not approved for device '
          '"$device". Allowed: ${allowed.toList()..sort()}.');
    }
  }

  // Matches `3.41.<patch>` with an optional pre-release suffix (`-1.0.pre`)
  // or build-metadata suffix (`+channel-stable`). Flutter stable's own
  // versioning and `flutter --version` output both include suffixes, so a
  // strict `^3\.41\.\d+$` regex rejected legitimate author-entered values.
  // The pin is still on major.minor (3.41); patch and suffix are free.
  static final RegExp _flutterVersionPattern =
      RegExp(r'^3\.41\.\d+(?:[-+][0-9A-Za-z.\-]+)?$');

  static void _validateFlutterVersion(Map<String, Object?> metadata) {
    final version = metadata['flutterVersion'];
    if (version is! String || version.trim().isEmpty) {
      throw const FormatException(
          '"flutterVersion" must be a non-empty string.');
    }
    if (!_flutterVersionPattern.hasMatch(version)) {
      throw FormatException(
          '"flutterVersion" "$version" does not match pinned Flutter '
          'stable $approvedFlutterMajorMinor.<patch> (pre-release or '
          'build-metadata suffixes like "-1.0.pre" / "+channel-stable" '
          'are accepted). Pinned-version policy rotates annually — see '
          'doc/reference_devices.md.');
    }
  }

  static void _validateExpectedMagnitude(Map<String, Object?> metadata) {
    final magnitude = metadata['expectedMagnitude'];
    if (magnitude is! Map<String, Object?>) {
      throw const FormatException(
          '"expectedMagnitude" must be an object with "min", "observed", '
          '"max" numeric fields.');
    }
    final min = magnitude['min'];
    final observed = magnitude['observed'];
    final max = magnitude['max'];
    if (min is! num) {
      throw const FormatException('"expectedMagnitude.min" must be a number.');
    }
    if (observed is! num) {
      throw const FormatException(
          '"expectedMagnitude.observed" must be a number.');
    }
    if (max is! num) {
      throw const FormatException('"expectedMagnitude.max" must be a number.');
    }
    // Reject non-finite (NaN, +Infinity, -Infinity) AND non-positive
    // magnitudes. `jsonDecode` rejects the literal tokens `NaN` /
    // `Infinity` syntactically, but exponent-overflow forms like
    // `1e400` decode silently to `double.infinity`, and
    // hand-constructed `Map` inputs bypass JSON entirely. Dart's NaN
    // comparison semantics (every comparison against NaN returns
    // false, including `NaN == NaN`) silently bypass every downstream
    // bracket and magnitude guard, so non-finite inputs must be
    // rejected at the boundary.
    for (final pair in <MapEntry<String, num>>[
      MapEntry('min', min),
      MapEntry('observed', observed),
      MapEntry('max', max),
    ]) {
      _requireFinitePositive(pair.value, 'expectedMagnitude.${pair.key}');
    }
    if (min > observed) {
      throw FormatException(
          '"expectedMagnitude" invariant violated: min ($min) > observed '
          '($observed). A capture claiming an observed magnitude must fall '
          'within its declared bounds.');
    }
    if (observed > max) {
      throw FormatException(
          '"expectedMagnitude" invariant violated: observed ($observed) > '
          'max ($max). A capture claiming an observed magnitude must fall '
          'within its declared bounds.');
    }
    // AGR-1 (Bundle E): unit is mandatory. The AB-1 trace/observed
    // cross-check needs a unit to convert `observed` into microseconds,
    // and the bracketing rule must compare all three captures against a
    // shared scale. Before Bundle E, unit was optional — a capture with
    // no unit declared was silently accepted AND silently disabled the
    // AB-1 ratio assertion, turning the single most important runtime
    // cross-check into an opt-in field. Now a missing or non-String
    // unit is a hard parse failure, and the unit must be in the
    // approved set so authors can't hide behind novel spellings
    // (`millis`, `millisecond`, `Ms`).
    final unit = magnitude['unit'];
    if (unit is! String || unit.trim().isEmpty) {
      throw const FormatException(
          '"expectedMagnitude.unit" must be a non-empty string naming the '
          'unit the magnitude is expressed in (e.g. "ms", "bytes", '
          '"frames"). A capture with no unit silently disables the '
          'trace-vs-observed cross-check and leaves the bracketing '
          'rule scale-confused.');
    }
    final normalisedUnit = unit.trim().toLowerCase();
    if (!approvedUnits.contains(normalisedUnit)) {
      throw FormatException(
          '"expectedMagnitude.unit" "$unit" is not in the approved unit '
          'set. Allowed: ${(approvedUnits.toList()..sort()).join(', ')}. '
          'Add new units by amending ProfileCaptureSchema.approvedUnits '
          'in the same PR — silent unit-name drift (e.g. "millis" vs '
          '"ms") undermines the audit gate.');
    }
  }

  /// Allowed values for `expectedMagnitude.unit`. Time units are
  /// recognised by `_unitToMicroseconds` and participate in the AB-1
  /// cross-check; non-time units pass the shape/positivity/invariant
  /// checks and skip the cross-check (a trace cannot certify bytes or
  /// frame counts). New units are a schema change — bump when adding.
  static const Set<String> approvedUnits = {
    // Time
    'ns', 'us', 'µs', 'ms', 's', 'sec', 'seconds',
    // Size
    'bytes', 'kb', 'mb',
    // Counts
    'frames', 'requests', 'gcevents', 'paints', 'rebuilds', 'builds',
    'events',
    // Rates (size-per-time) — used by MemoryPressureDetector.heap_growing
    // (slope), and any future detector measuring throughput.
    'bytes/sec',
    // Ratios — used by FrameTimingDetector.jank_detected (jankPercent
    // observation over rolling 240-frame buffer; denominator-independent
    // axis under v0.19.6+ percent-axis bracket convention). Skips AB-1
    // time-unit cross-check (a trace cannot certify a percent), but
    // participates in observedAxisArgKey + observedAxisReduction='last'
    // cross-check.
    'percent',
  };

  static void _validateCaptureDate(Map<String, Object?> metadata) {
    final raw = metadata['captureDate'];
    if (raw is! String || raw.trim().isEmpty) {
      throw const FormatException(
          '"captureDate" must be a non-empty ISO-8601 string.');
    }
    final trimmed = raw.trim();
    // CODEX-R1-4 / AB-3: `DateTime.tryParse` silently rolls over
    // out-of-range components — "2026-13-45" parses as 2027-02-14,
    // "2026-04-18T25:61:00Z" parses as 2026-04-19T02:01:00Z. A capture
    // whose literal components silently drift almost certainly reflects
    // an authoring bug we should surface, not absorb.
    //
    // Previously this did a string-based round-trip check against a
    // normalised form, which incorrectly rejected valid captures with a
    // non-zero UTC offset (e.g. `+05:30`) because `toUtc().toIso8601String()`
    // shifts the components to UTC and the normalisation only bridged
    // `Z` ↔ `+00:00`. Replace with explicit range checks on the literal
    // components extracted via regex — this detects rollover
    // unambiguously regardless of the offset.
    final m = _captureDatePattern.firstMatch(trimmed);
    if (m == null) {
      throw FormatException(
          '"captureDate" "$raw" is not a valid ISO-8601 date/time.');
    }
    final year = int.parse(m.group(1)!);
    final month = int.parse(m.group(2)!);
    final day = int.parse(m.group(3)!);
    final hour = m.group(4) != null ? int.parse(m.group(4)!) : 0;
    final minute = m.group(5) != null ? int.parse(m.group(5)!) : 0;
    final second = m.group(6) != null ? int.parse(m.group(6)!) : 0;

    if (month < 1 || month > 12) {
      throw FormatException(
          '"captureDate" "$raw" has an out-of-range month ($month) that '
          'DateTime.parse round-trips through silent rollover. '
          'Reject rather than absorb the drift.');
    }
    if (hour > 23 || minute > 59 || second > 60) {
      throw FormatException(
          '"captureDate" "$raw" has out-of-range time components '
          '(hour=$hour, minute=$minute, second=$second) that DateTime.parse '
          'round-trips through silent rollover. '
          'Reject rather than absorb the drift.');
    }
    final isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
    final maxDay = (month == 2 && isLeap) ? 29 : _daysInMonth[month - 1];
    if (day < 1 || day > maxDay) {
      throw FormatException(
          '"captureDate" "$raw" has an out-of-range day ($day for month '
          '$month in year $year) that DateTime.parse round-trips through '
          'silent rollover. Reject rather than absorb the drift.');
    }

    if (DateTime.tryParse(trimmed) == null) {
      throw FormatException(
          '"captureDate" "$raw" is not a valid ISO-8601 date/time.');
    }
  }

  // ISO-8601 shape: `YYYY-MM-DD` optionally followed by
  // `Thh:mm:ss[.fraction][offset]`, where offset is `Z`, `+HH:MM`, `-HH:MM`,
  // `+HHMM`, or `-HHMM`. Enough to extract literal components for
  // range-checking; `DateTime.tryParse` does the final validity pass.
  static final RegExp _captureDatePattern = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})'
    r'(?:[Tt ](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?'
    r'(?:[Zz]|[+-]\d{2}:?\d{2})?)?$',
  );

  static const List<int> _daysInMonth = [
    31,
    28,
    31,
    30,
    31,
    30,
    31,
    31,
    30,
    31,
    30,
    31,
  ];

  static Map<String, Object?> _parseOrThrowWithLabel(File file, String label) {
    if (!file.existsSync()) {
      throw FormatException(
          'Bracket "$label" capture does not exist: ${file.path}');
    }
    try {
      final bytes = file.readAsBytesSync();
      // `parse()` reads `sleuthMetadata.role` to drive the AB-1
      // inverse-ratio bypass for below-role captures (sub-threshold
      // workload paired with normal-sized scenario span). The role
      // field is the canonical signal — no shim needed here.
      final metadata = parse(bytes);
      _validateScenarioMatchesPath(file, metadata);
      // Cross-check that the file's stored role matches the positional
      // bracket slot it was passed into. Without this, a mis-rolled
      // capture (e.g. a file with `metadata.role: 'below'` placed in
      // the at-slot) silently disables the inverse-ratio check while
      // being audited in the wrong bracket position. Presence of the
      // role field is enforced upstream in `parse()`; correctness of
      // the triad mapping is enforced here.
      final storedRole = metadata['role'];
      if (storedRole != label) {
        throw FormatException('Bracket "$label" slot received a capture whose '
            '`sleuthMetadata.role` is "$storedRole" — the positional '
            'bracket label and the stored role must match. Either '
            'pass this file to the "$storedRole" slot or correct the '
            'role field in the capture.');
      }
      // Stash the raw traceEvents on the metadata under a private
      // sentinel key so the trace-record helpers
      // (`_requireIssueTraceRecord`, `_requireNoIssueTraceRecord`)
      // can avoid re-reading + re-parsing the file. The sentinel
      // collides with no schema-defined key (all start without `_`).
      final root =
          jsonDecode(_stripBomAndNormaliseLineEndings(_decodeUtf8(bytes)))
              as Map<String, Object?>;
      metadata['_rawTraceEvents'] = root['traceEvents'];
      return metadata;
    } on FormatException catch (e) {
      throw FormatException('Bracket "$label" capture failed schema validation '
          '(${file.path}): ${e.message}');
    }
  }

  static num _readObserved(Map<String, Object?> metadata) {
    final magnitude = metadata['expectedMagnitude'] as Map<String, Object?>;
    // Already validated numeric in parse(); cast is safe here.
    return magnitude['observed'] as num;
  }

  static String _readUnit(Map<String, Object?> metadata) {
    final magnitude = metadata['expectedMagnitude'] as Map<String, Object?>;
    // AGR-1 (Bundle E): `_validateExpectedMagnitude` has already run and
    // guaranteed unit is a non-empty String in the approved set.
    return magnitude['unit'] as String;
  }
}

/// Per-object frame used by [ProfileCaptureSchema._detectDuplicateKeys]
/// to track which keys have been seen within the same open object.
class _JsonFrame {
  _JsonFrame({required this.isObject})
      : nextIsKey = isObject,
        keys = isObject ? <String>{} : const <String>{};

  final bool isObject;
  final Set<String> keys;
  bool nextIsKey;
}
