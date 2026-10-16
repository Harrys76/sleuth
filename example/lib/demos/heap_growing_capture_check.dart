import 'dart:convert';

/// The `heap_growing` leg a capture records. Each leg has its own bracket:
/// the audit tells them apart by the axis key the trace record carries.
enum HeapGrowingCaptureLeg {
  /// The heap measured right after idle full collections.
  floor(
    axisKey: 'observedFloorSlopeBytesPerSec',
    scenarioPrefix: 'memory_pressure_heap_growing_floor_',
    fileStem: 'heap_growing_floor_',
    directory: 'test/validation/captures/memory_pressure_floor/',
  ),

  /// The 500 ms heap-sample regression.
  sample(
    axisKey: 'observedSlopeBytesPerSec',
    scenarioPrefix: 'memory_pressure_heap_growing_',
    fileStem: 'heap_growing_',
    directory: 'test/validation/captures/memory_pressure/',
  );

  const HeapGrowingCaptureLeg({
    required this.axisKey,
    required this.scenarioPrefix,
    required this.fileStem,
    required this.directory,
  });

  /// The trace-record argument holding this leg's slope.
  final String axisKey;

  /// Scenario name prefix; the role label follows it.
  final String scenarioPrefix;

  /// Capture file name prefix; the role label and `.json` follow it.
  final String fileStem;

  /// Where the capture files live in the repository.
  final String directory;
}

const String _issueEvent = 'sleuth.issue.heap_growing.warning';

/// The in-span `heap_growing` records of a wrapped capture, as the value
/// each carries for [axisKey] (null when the record lacks it). Null when
/// the capture has no span for [scenarioName].
List<double?>? heapGrowingRecordAxes(
  String json, {
  required String scenarioName,
  required String axisKey,
}) {
  final Object? root;
  try {
    root = jsonDecode(json);
  } catch (_) {
    return null;
  }
  if (root is! Map<String, dynamic>) return null;
  final events = root['traceEvents'];
  if (events is! List) return null;

  int? beginTs;
  int? endTs;
  for (final raw in events) {
    if (raw is! Map) continue;
    final name = raw['name'];
    final ts = raw['ts'];
    if (ts is! num) continue;
    if (name != 'sleuth.scenario.begin' && name != 'sleuth.scenario.end') {
      continue;
    }
    if (_arg(raw['args'], 'name') != scenarioName) continue;
    if (name == 'sleuth.scenario.begin') beginTs = ts.toInt();
    if (name == 'sleuth.scenario.end') endTs = ts.toInt();
  }
  if (beginTs == null || endTs == null) return null;

  final axes = <double?>[];
  for (final raw in events) {
    if (raw is! Map || raw['name'] != _issueEvent) continue;
    final ts = raw['ts'];
    if (ts is! num) continue;
    if (ts.toInt() < beginTs || ts.toInt() > endTs) continue;
    final value = _arg(raw['args'], axisKey);
    axes.add(switch (value) {
      final String s => double.tryParse(s),
      final num n => n.toDouble(),
      _ => null,
    });
  }
  return axes;
}

// Reads [key] from trace args, which some VM service exports nest under
// `Dart Arguments`.
Object? _arg(Object? args, String key) {
  if (args is! Map) return null;
  final direct = args[key];
  if (direct != null) return direct;
  final nested = args['Dart Arguments'];
  return nested is Map ? nested[key] : null;
}

/// Why a stashed capture cannot be exported for [leg], or null when it can.
///
/// A below capture must hold no `heap_growing` record at all. An at or
/// above capture must hold at least one, every record must carry the
/// leg's axis key (a record from the other leg fails the audit), and
/// every value must lie in `[bandMin, bandMax]`.
String? checkHeapGrowingCapture(
  String json, {
  required HeapGrowingCaptureLeg leg,
  required String role,
  required double bandMin,
  required double bandMax,
}) {
  final scenarioName = '${leg.scenarioPrefix}$role';
  final axes = heapGrowingRecordAxes(
    json,
    scenarioName: scenarioName,
    axisKey: leg.axisKey,
  );
  if (axes == null) {
    return 'scenario markers for $scenarioName are missing from the '
        'capture. Re-tap the leg.';
  }
  if (role == 'below') {
    return axes.isEmpty
        ? null
        : 'the detector fired ${axes.length} time(s) on a leg whose '
              'retained rate is below the threshold. Retry the leg.';
  }
  if (axes.isEmpty) {
    return 'no in-span `$_issueEvent` record: the ${leg.name} leg did not '
        'fire. Re-tap the leg.';
  }
  final missing = axes.where((a) => a == null).length;
  if (missing > 0) {
    return '$missing in-span record(s) lack `${leg.axisKey}`: the other '
        'leg published during the run, so the audit would reject the '
        'capture. Check that the leg switches were applied.';
  }
  final outOfBand = [
    for (final a in axes)
      if (a! < bandMin || a > bandMax) a,
  ];
  if (outOfBand.isNotEmpty) {
    return 'record slope(s) ${outOfBand.map((a) => a.round()).join(', ')} '
        'B/s outside [${bandMin.round()}, ${bandMax.round()}].';
  }
  return null;
}

/// The highest slope among the in-span records carrying [leg]'s axis key,
/// or null when none does.
double? heapGrowingCaptureSlope(
  String json, {
  required HeapGrowingCaptureLeg leg,
  required String role,
}) {
  final axes = heapGrowingRecordAxes(
    json,
    scenarioName: '${leg.scenarioPrefix}$role',
    axisKey: leg.axisKey,
  );
  final values = [for (final a in axes ?? const <double?>[]) ?a];
  if (values.isEmpty) return null;
  return values.reduce((a, b) => a > b ? a : b);
}
