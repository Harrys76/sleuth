import 'dart:developer' show Timeline;

import 'package:flutter/foundation.dart' show kReleaseMode;

import '../models/performance_issue.dart';
import '../validation/capture_event_constants.dart';

/// Resolved trace event payload — name + args. The `recordIssue` path
/// produces one of these and forwards to `Timeline.instantSync`; tests
/// drive `composeIssueEvent` directly to verify wire-format shape
/// without depending on the VM service buffer.
class CaptureIssueEvent {
  const CaptureIssueEvent({required this.name, required this.args});
  final String name;
  final Map<String, String> args;
}

/// Emits `sleuth.issue.<stableId>.<severity>` instant trace events that
/// `ProfileCaptureSchema.validateBracket` looks for inside the
/// `sleuth.scenario.{begin,end}` span when validating a `runtimeVerified`
/// detector's capture triad.
///
/// **Triple-gated** so production sessions and ordinary profile-mode
/// development never see extra timeline traffic:
///
///   1. Compile-time `kReleaseMode` guard — release builds don't carry
///      this code at all.
///   2. Runtime `captureMode` flag (passed in) — even in profile mode,
///      events emit only when the user explicitly opted in via
///      `Sleuth.track(config: SleuthConfig(captureMode: true))`.
///   3. Issue must have a non-null, non-empty `stableId`. Detectors
///      that haven't adopted stable IDs are silently skipped.
///
/// All event-name composition routes through [issueTraceEventName] in
/// `capture_event_constants.dart` so emitter and parser cannot drift —
/// the cross-check round-trip test in
/// `test/validation/capture_event_constants_test.dart` exercises both
/// ends against the shared constant.
class CaptureHelper {
  CaptureHelper._();

  /// Pure-data composition of the trace event payload. Returns null
  /// when the issue should NOT be recorded (no stableId or empty
  /// stableId). Both gates `kReleaseMode` and `captureMode` are checked
  /// at the [recordIssue] entry point — this method assumes the gates
  /// passed and only does payload construction so it stays directly
  /// testable.
  static CaptureIssueEvent? composeIssueEvent(PerformanceIssue issue) {
    final stableId = issue.stableId;
    if (stableId == null || stableId.isEmpty) return null;
    // Detectors may emit issues without a `detectedAt` timestamp (legacy
    // or test fixtures); fall back to "now" so the trace record always
    // carries a numeric arg the schema parser can range-check against
    // the scenario span.
    final detectedAt = issue.detectedAt ?? DateTime.now();
    return CaptureIssueEvent(
      name: issueTraceEventName(stableId, issue.severity.name),
      args: <String, String>{
        // Flutter's Timeline arg encoding accepts `Map<String, Object?>`
        // and serialises each value via `toString()` exactly once on
        // its way to the engine. Pre-stringifying here therefore does
        // NOT produce a doubly-quoted value (`'"123"'`) — a String
        // passed in is forwarded as-is. Pre-encoding keeps the wire
        // format unambiguous and means the schema parser can read
        // `args[issueTraceArgDetectedAtMicros]` as a plain `String`
        // without type-coercion. If you ever change this to a numeric
        // type, also update the schema-side reader and re-record the
        // round-trip fixtures so the cross-check test re-validates.
        issueTraceArgDetectedAtMicros:
            detectedAt.microsecondsSinceEpoch.toString(),
      },
    );
  }

  /// Records [issue] as a `sleuth.issue.<stableId>.<severity>` instant
  /// trace event when [captureMode] is true and the build is not
  /// release.
  static void recordIssue(
    PerformanceIssue issue, {
    required bool captureMode,
  }) {
    if (kReleaseMode || !captureMode) return;
    final event = composeIssueEvent(issue);
    if (event == null) return;
    Timeline.instantSync(event.name, arguments: event.args);
  }
}
