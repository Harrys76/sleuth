/// Shared format constants for profile-mode capture trace records.
///
/// The detector-emission path (`CaptureHelper.recordIssue`) and the
/// schema-validation path (`ProfileCaptureSchema._findIssueTraceRecord`)
/// MUST agree on these strings byte-for-byte. A single source prevents
/// silent drift — any rename here propagates to both consumers via
/// the type system, and the cross-check round-trip test
/// (`test/validation/capture_event_constants_test.dart`) fails CI if a
/// future refactor splits them.
library;

/// Trace event name prefix for sleuth-detector-emitted issue records.
///
/// Full name: `<issueTraceEventPrefix><stableId>.<severity>`.
/// Examples:
///   - `'sleuth.issue.heavy_compute.warning'`
///   - `'sleuth.issue.shader_compilation.critical'`
const String issueTraceEventPrefix = 'sleuth.issue.';

/// Phase code for instant trace events as emitted by Flutter's
/// `Timeline.instantSync`. Chrome Trace Event Format calls this 'i'.
const String instantPhaseChrome = 'i';

/// Alternate phase codes parsers must accept. `'I'` is the uppercase
/// variant some exporters emit; `'n'` is Perfetto's async-nestable
/// instant code that DevTools 'Save timeline JSON' may produce when
/// converting from Perfetto traces.
const List<String> instantPhaseAlternates = ['I', 'n'];

/// All accepted instant-phase codes for matching trace records.
const List<String> instantPhases = [
  instantPhaseChrome,
  ...instantPhaseAlternates
];

/// Schema version pinned in `sleuthMetadata.schemaVersion` for
/// captures recorded under v0.18.0+. The schema parser rejects
/// captures missing this field for runtimeVerified detector audits;
/// pre-v0.18.0 captures (e.g. orphan NetworkMonitor triad) parse
/// without this field when `requireDetectorTraceRecord: false`.
const String captureSchemaVersion = 'v1';

/// Argument key carrying the detector-measured issue timestamp inside
/// the trace event's `args` map. Value is `microsecondsSinceEpoch` as
/// a string (Flutter's Timeline encodes all args as strings).
const String issueTraceArgDetectedAtMicros = 'detectedAtMicros';

/// Compose the full trace event name for an emitted issue.
///
/// Reads as: `sleuth.issue.<stableId>.<severity>`. The capture-helper
/// emits this name; the schema parser searches for it.
String issueTraceEventName(String stableId, String severityName) =>
    '$issueTraceEventPrefix$stableId.$severityName';
