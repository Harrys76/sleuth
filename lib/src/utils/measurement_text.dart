import '../models/issue_measurement.dart';
import '../models/performance_issue.dart';

/// [value] in [unit], as the Measured row and its gauge show it.
String formatMeasurementValue(double value, MeasurementUnit unit) {
  if (!value.isFinite) return '$value';
  return switch (unit) {
    MeasurementUnit.milliseconds => '${_number(value, 100)} ms',
    MeasurementUnit.seconds => '${_number(value, 10)} s',
    MeasurementUnit.percent => '${_number(value, 10)}%',
    MeasurementUnit.bytes => _bytes(value),
    MeasurementUnit.bytesPerSecond => '${_bytes(value)}/s',
    MeasurementUnit.count => _grouped(value.round()),
    MeasurementUnit.perSecond => '${_number(value, 10)}/s',
    MeasurementUnit.perMinute => '${_number(value, 10)}/min',
    MeasurementUnit.frames =>
      '${_grouped(value.round())} ${value.round() == 1 ? 'frame' : 'frames'}',
    _ => '${_number(value, 10)} ${unit.name}',
  };
}

/// One decimal below [wholeFrom], whole numbers with digit groups above.
String _number(double value, double wholeFrom) => value.abs() < wholeFrom
    ? value.toStringAsFixed(1)
    : _grouped(value.round());

String _grouped(int value) {
  final digits = value.abs().toString();
  final out = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

String _bytes(double bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var v = bytes;
  var i = 0;
  while (v.abs() >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return i == 0 ? '${v.round()} B' : '${v.toStringAsFixed(1)} ${units[i]}';
}

/// The stable id's family: the part before `:` for a colon-parametric id
/// and `rebuild_debug` / `repaint_debug` for the per-type debug ids.
String measurementFamilyOf(String stableId) {
  final colon = stableId.indexOf(':');
  if (colon >= 0) return stableId.substring(0, colon);
  for (final prefix in const ['rebuild_debug_', 'repaint_debug_']) {
    if (stableId.startsWith(prefix)) {
      return prefix.substring(0, prefix.length - 1);
    }
  }
  return stableId;
}

/// What the measured value is, per family. `{v}` is the value, `{w}` the
/// issue's widget and `{n}` the name after the `:` of a parametric id.
/// Text in `[...]` shows only when the measurement has a window, with
/// `{t}` the window's length.
///
/// Every family whose detector stamps a measurement has an entry; a test
/// walks them.
const Map<String, String> measuredPhrases = {
  'sustained_jank': '{v} ran more than twice over budget[ in the last {t}]',
  'jank_detected': '{v} of frames missed their deadline[ in the last {t}]',
  'raster_cache_thrashing':
      '{v} in a row changed the raster cache by more than 20%',
  'raster_cache_growing': '{v} in a row grew the raster cache',
  'rebuild_debug': 'Rebuilds of {w} at {v}',
  'rebuild_activity': '{v} of UI-thread time went to building widgets',
  'stateful_density': '{v} stateful widgets on screen',
  'excessive_repaint': '{v} of UI-thread time went to painting',
  'repaint_debug': 'Repaints that likely start at {w}: {v}',
  'excessive_repaint_debug': 'Paint calls at {v}, animations left out',
  'frequent_repaint_painter': 'Repaints from {w} at {v}',
  'event_loop_stall': 'At least {v} with the UI isolate held',
  'non_lazy_listview': '{v} children built up front in {w}',
  'non_lazy_gridview': '{v} children built up front in {w}',
  'non_lazy_sliver_list': '{v} children built up front in {w}',
  'non_lazy_sliver_grid': '{v} children built up front in {w}',
  'non_lazy_list': '{v} children built up front in a scroll view',
  'sliver_to_box_adapter_large':
      '{v} children built up front in a SliverToBoxAdapter',
  'non_lazy_shrinkwrap':
      '{v} children of a shrink-wrapped list, built up front',
  'slow_startup_ttff': '{v} from Sleuth.init() to the first frame',
  'wrap_layout_bottleneck': '{v} children laid out at once in this Wrap',
  'heavy_compute': '{v} in one build on the UI thread',
  'multiple_custom_fonts': '{v} custom font families in use',
  'excessive_keep_alive': '{v} keep-alive items in one scrollable',
  'tracked_resource_concurrent': '{v} live "{n}" instances',
  'tracked_resource_long_lived': 'One "{n}" instance alive for {v}',
  'raster_dominance': '{v} missed the deadline on the raster thread[ in {t}]',
  'slow_request': '{v} for the slowest request',
  'large_response': '{v} in the largest response',
  'request_frequency': '{v} requests[ in {t}] at the peak',
  'http_error_spike': '{v} failed requests[ in {t}]',
  'high_frequency_same_path': '{v} requests to one path[ within {t}]',
  'shader_compilation': '{v} to build one shader pipeline',
  'setstate_scope': '{v} of the widget tree sits under {w}',
  'gc_pressure': 'Young-generation garbage collections at {v}',
  'heap_growing': 'Dart heap growing at {v}',
  'heap_near_capacity': '{v} of process memory in use',
  'native_memory_growing': 'Memory outside the Dart heap growing at {v}',
  'platform_channel_traffic':
      'Platform channel calls at {v} in the busiest second',
  'stream_resource_growth':
      '{v} more instances of the fastest-growing stream class',
  'uncached_images': '{v} decoded beyond display size',
  'missing_repaint_boundary':
      '{v} GPU-heavy widgets with no RepaintBoundary above',
  'excessive_repaint_boundary': '{v} RepaintBoundary widgets in one scrollable',
};

/// The Measured row's value line split around the value, which the card
/// sets in bold: `(before, value, after)`. Null when the issue has no
/// finite measurement.
(String, String, String)? measuredLine(PerformanceIssue issue) {
  final m = issue.measurement;
  if (m == null || !m.hasFiniteValue) return null;
  final value = formatMeasurementValue(m.value, m.unit);
  final id = issue.stableId;
  final colon = id?.indexOf(':') ?? -1;
  final template = id == null ? null : measuredPhrases[measurementFamilyOf(id)];
  if (template == null) return ('', value, '');
  final window = m.window;
  final filled = template
      .replaceAll('{w}', issue.widgetName ?? 'the widget')
      .replaceAll('{n}', colon >= 0 ? id!.substring(colon + 1) : '')
      .replaceAllMapped(
        _windowPart,
        (match) => window == null
            ? ''
            : match.group(1)!.replaceAll('{t}', formatWindow(window)),
      );
  final at = filled.indexOf('{v}');
  return (filled.substring(0, at), value, filled.substring(at + 3));
}

final RegExp _windowPart = RegExp(r'\[([^\]]*)\]');

/// [window] as the value line names it: "500 ms", "4.2 s", "10 s".
String formatWindow(Duration window) {
  final ms = window.inMicroseconds / Duration.microsecondsPerMillisecond;
  if (ms < 1000) return '${ms.round()} ms';
  final s = ms / 1000;
  return s < 10 && (s * 10).round() % 10 != 0
      ? '${s.toStringAsFixed(1)} s'
      : '${s.round()} s';
}

/// The Measured row's text, as one string, the gauge's line labels
/// included: the issues fingerprint takes it, so a card refreshes when
/// what it shows changes and not otherwise.
String? measuredText(PerformanceIssue issue) {
  final line = measuredLine(issue);
  if (line == null) return null;
  final m = issue.measurement!;
  final note = measuredSeverityNote(issue);
  return [
    '${line.$1}${line.$2}${line.$3}',
    if (m.warningAt != null)
      'warn ${formatMeasurementValue(m.warningAt!, m.unit)}',
    if (m.criticalAt != null)
      'critical ${formatMeasurementValue(m.criticalAt!, m.unit)}',
    ?note,
  ].join('\n');
}

/// Whether [m]'s value reaches [line]: at or above it, or above it when
/// [strict].
bool _reaches(IssueMeasurement m, double? line, bool strict) =>
    line != null && (strict ? m.value > line : m.value >= line);

/// A line under the gauge when the severity and the value disagree.
///
/// A severity above what the value reaches is a held severity. A warning
/// whose value reaches the critical line comes from a detector that judged
/// another reading: for the debug rates, the latest second. The card never
/// derives severity from the measurement.
String? measuredSeverityNote(PerformanceIssue issue) {
  final m = issue.measurement;
  if (m == null || !m.hasFiniteValue) return null;
  final reachesWarning = _reaches(m, m.warningAt, m.warningStrict);
  final reachesCritical = _reaches(m, m.criticalAt, m.criticalStrict);
  switch (issue.severity) {
    case IssueSeverity.critical when m.criticalAt != null && !reachesCritical:
      return 'Held at critical: the value has not stayed below the line '
          'long enough to clear it';
    case IssueSeverity.warning when m.warningAt != null && !reachesWarning:
      return 'Held at warning: the value has not stayed below the line '
          'long enough to clear it';
    case IssueSeverity.warning when reachesCritical:
      return m.unit == MeasurementUnit.perSecond
          ? 'Not critical: the latest second stayed at or under the line'
          : 'Not critical: the detector judged another reading';
    default:
      return null;
  }
}

/// What a screen reader hears for the Measured row: the value line, both
/// lines and the severity note.
String measuredSemanticsLabel(PerformanceIssue issue) {
  final m = issue.measurement!;
  final line = measuredLine(issue)!;
  final note = measuredSeverityNote(issue);
  return [
    'Measured: ${line.$1}${line.$2}${line.$3}',
    if (m.warningAt != null)
      'Warning at ${formatMeasurementValue(m.warningAt!, m.unit)}',
    if (m.criticalAt != null)
      'Critical at ${formatMeasurementValue(m.criticalAt!, m.unit)}',
    ?note,
  ].join('. ');
}

/// The Measured row as sentences for text the user copies or sends, such
/// as Copy details and the AI prompt. Null when the issue has no finite
/// measurement.
String? measuredSentence(PerformanceIssue issue) =>
    measuredLine(issue) == null ? null : '${measuredSemanticsLabel(issue)}.';

/// [PerformanceIssue.toClipboardText] with the Measured sentence after its
/// header lines (title, severity, confidence, route, widget), as Copy
/// details puts it on the clipboard.
String copyDetailsText(PerformanceIssue issue) {
  final text = issue.toClipboardText();
  final measured = measuredSentence(issue);
  if (measured == null) return text;
  final headerEnd = text.indexOf('\n\n');
  if (headerEnd < 0) return '$text\n$measured';
  return '${text.substring(0, headerEnd)}\n$measured'
      '${text.substring(headerEnd)}';
}
