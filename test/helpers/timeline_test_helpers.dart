import 'package:vm_service/vm_service.dart';
import 'package:sleuth/src/models/phase_event.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

/// Factory for empty timeline data (all zeros).
ParsedTimelineData emptyTimelineData() => ParsedTimelineData();

/// Factory for timeline data carrying [scopes] BUILD scopes whose
/// durations sum to exactly [buildTimeUs] (`totalBuildScopeUs`), with
/// `buildEventCount == scopes`. Feeds the `rebuild_activity` time-share
/// axis: over a 1 000 ms window, `buildTimeUs: 110000` is 11.0 %.
ParsedTimelineData buildLoadData({required int buildTimeUs, int scopes = 60}) =>
    ParsedTimelineData(
      buildScopeDurations: _splitEvenly(buildTimeUs, scopes),
      buildEventCount: scopes,
    );

/// Factory for timeline data carrying [frames] PAINT scopes whose
/// durations sum to exactly [paintTimeUs] (`totalFlushPaintUs`). Feeds the
/// `excessive_repaint` time-share axis.
ParsedTimelineData paintLoadData({required int paintTimeUs, int frames = 60}) =>
    ParsedTimelineData(flushPaintDurations: _splitEvenly(paintTimeUs, frames));

/// Splits [total] into [parts] non-negative integers summing to [total].
List<int> _splitEvenly(int total, int parts) {
  assert(parts > 0 && total >= 0);
  final base = total ~/ parts;
  final remainder = total % parts;
  return List.generate(parts, (i) => base + (i < remainder ? 1 : 0));
}

/// Factory for raster-dominant timeline data.
ParsedTimelineData rasterDominantData({
  int rasterUs = 30000,
  int buildUs = 5000,
  int layoutUs = 3000,
  int paintUs = 2000,
}) => ParsedTimelineData(
  rasterDurations: [rasterUs],
  buildScopeDurations: [buildUs],
  flushLayoutDurations: [layoutUs],
  flushPaintDurations: [paintUs],
);

/// Factory for timeline data with GC events.
ParsedTimelineData gcHeavyData({int gcCount = 10}) => ParsedTimelineData(
  gcEvents: List.generate(
    gcCount,
    (i) => TimelineEvent.parse({
      'name': 'GC',
      'cat': 'gc',
      'ph': 'X',
      'dur': 100,
      'ts': i * 1000,
      'pid': 1,
      'tid': 1,
    })!,
  ),
);

/// Factory for timeline data with buildScope durations (for HeavyComputeDetector).
ParsedTimelineData heavyComputeData({
  List<int> buildScopeDurationsUs = const [],
}) => ParsedTimelineData(buildScopeDurations: buildScopeDurationsUs);

/// Factory for timeline data with enriched build phaseEvents.
///
/// Creates both raw duration lists AND phaseEvents with enrichment data,
/// matching what [TimelineParser.parse] produces when timeline enrichment
/// is enabled.
ParsedTimelineData enrichedBuildData({
  required int buildDurationUs,
  int? dirtyCount,
  List<String>? dirtyList,
  String? scopeContext,
  int baseTimestampUs = 100000,
}) => ParsedTimelineData(
  buildScopeDurations: [buildDurationUs],
  buildEventCount: 1,
  phaseEvents: [
    PhaseEvent(
      phase: TimelinePhase.build,
      timestampUs: baseTimestampUs,
      durationUs: buildDurationUs,
      dirtyCount: dirtyCount,
      dirtyList: dirtyList,
      scopeContext: scopeContext,
    ),
  ],
);

/// Factory for timeline data with enriched paint phaseEvents.
ParsedTimelineData enrichedPaintData({
  required int paintCount,
  int? dirtyCount,
  int paintDurationUs = 1000,
  int baseTimestampUs = 100000,
}) => ParsedTimelineData(
  flushPaintDurations: List.generate(paintCount, (_) => paintDurationUs),
  phaseEvents: List.generate(
    paintCount,
    (i) => PhaseEvent(
      phase: TimelinePhase.paint,
      timestampUs: baseTimestampUs + i * paintDurationUs,
      durationUs: paintDurationUs,
      dirtyCount: dirtyCount,
    ),
  ),
);

/// Factory for build activity data with enriched dirty names. The BUILD
/// scope time ([buildTimeUs]) feeds the `rebuild_activity` time-share
/// axis; the dirty-list phase event feeds attribution only.
ParsedTimelineData enrichedBuildActivityData({
  int buildTimeUs = 0,
  List<String>? dirtyList,
}) => ParsedTimelineData(
  buildScopeDurations: buildTimeUs > 0 ? [buildTimeUs] : const [],
  buildEventCount: buildTimeUs > 0 ? 1 : 0,
  phaseEvents: dirtyList != null
      ? [
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 100000,
            durationUs: 5000,
            dirtyList: dirtyList,
          ),
        ]
      : const [],
);

/// Factory for timeline data with shader compile durations (for ShaderJankDetector).
///
/// Populates BOTH `shaderCompileDurations` and `phaseEvents` so the detector
/// — which iterates `phaseEvents.where(shader)` to access per-event timestamps
/// for `shaderWarmupContext` attribution — sees the synthetic events. Each
/// shader event is stamped with a synthetic monotonic timestamp at 1 second
/// intervals starting at 1_000_000 µs (1 s) so test fixtures land outside
/// the default 5 s `coldStartShaderWindowSeconds` and classify as
/// `'hot_path'` unless overridden by `appStartMonotonicUsForTest`.
ParsedTimelineData shaderCompileData({List<int> shaderDurationsUs = const []}) {
  final phaseEvents = <PhaseEvent>[];
  for (var i = 0; i < shaderDurationsUs.length; i++) {
    phaseEvents.add(
      PhaseEvent(
        phase: TimelinePhase.shader,
        timestampUs: 10000000 + i * 1000000,
        durationUs: shaderDurationsUs[i],
      ),
    );
  }
  return ParsedTimelineData(
    shaderCompileDurations: shaderDurationsUs,
    phaseEvents: phaseEvents,
  );
}

/// Raw begin/end pair for a pipeline or shader build, in the shape the
/// engine's `TRACE_EVENT` scopes produce: a `B` (carrying [args]) and an
/// arg-less `E` on the same thread. Defaults to Impeller Vulkan's
/// `PipelineVK::Create`; pass a Skia name with
/// `args: {'devtoolsTag': 'shaders'}` for a Skia shader compile.
List<TimelineEvent> shaderBeginEndEvents({
  String name = 'PipelineVK::Create',
  required int startTs,
  required int durUs,
  int tid = 1,
  Map<String, String>? args,
}) => [
  TimelineEvent.parse({
    'name': name,
    'cat': 'Embedder',
    'ph': 'B',
    'ts': startTs,
    'args': ?args,
    'pid': 1,
    'tid': tid,
  })!,
  TimelineEvent.parse({
    'name': name,
    'cat': 'Embedder',
    'ph': 'E',
    'ts': startTs + durUs,
    'pid': 1,
    'tid': tid,
  })!,
];

/// Raw complete (`X`) shader event tagged `devtoolsTag: shaders`.
TimelineEvent shaderCompleteEvent({
  String name = 'GrGLProgramBuilder::finalize',
  required int ts,
  required int durUs,
  int tid = 1,
}) => TimelineEvent.parse({
  'name': name,
  'cat': 'Embedder',
  'ph': 'X',
  'ts': ts,
  'dur': durUs,
  'args': {'devtoolsTag': 'shaders'},
  'pid': 1,
  'tid': tid,
})!;

/// Factory for timeline data with platform channel events (for PlatformChannelDetector).
///
/// Mirrors the parser's output for sync `X` channel events: one counted
/// event plus one completed [PlatformChannelCall] (duration [durUs]) per
/// call.
ParsedTimelineData platformChannelData({
  int channelEventCount = 0,
  int durUs = 100,
  String? methodName,
}) => ParsedTimelineData(
  platformChannelEvents: List.generate(
    channelEventCount,
    (i) => TimelineEvent.parse({
      'name': methodName ?? 'PlatformChannel',
      'cat': '',
      'ph': 'X',
      'dur': durUs,
      'ts': i * 1000,
      'pid': 1,
      'tid': 1,
    })!,
  ),
  platformChannelCalls: List.generate(
    channelEventCount,
    (i) => PlatformChannelCall(
      name: methodName ?? 'PlatformChannel',
      beginTs: i * 1000,
      durationUs: durUs,
    ),
  ),
);

/// Factory for timeline data with phaseEvents for frame-event correlation testing.
///
/// [baseTimestampUs] is the start of the event window.
/// Creates events across all phases with timestamps suitable for correlation.
ParsedTimelineData correlatedTimelineData({
  int buildUs = 5000,
  int layoutUs = 3000,
  int paintUs = 2000,
  int rasterUs = 10000,
  int shaderUs = 0,
  int baseTimestampUs = 100000,
}) {
  final phaseEvents = <PhaseEvent>[
    PhaseEvent(
      phase: TimelinePhase.build,
      timestampUs: baseTimestampUs,
      durationUs: buildUs,
    ),
    PhaseEvent(
      phase: TimelinePhase.layout,
      timestampUs: baseTimestampUs + buildUs,
      durationUs: layoutUs,
    ),
    PhaseEvent(
      phase: TimelinePhase.paint,
      timestampUs: baseTimestampUs + buildUs + layoutUs,
      durationUs: paintUs,
    ),
    PhaseEvent(
      phase: TimelinePhase.raster,
      timestampUs: baseTimestampUs + buildUs + layoutUs + paintUs + 1000,
      durationUs: rasterUs,
    ),
    if (shaderUs > 0)
      PhaseEvent(
        phase: TimelinePhase.shader,
        timestampUs:
            baseTimestampUs + buildUs + layoutUs + paintUs + 1000 + rasterUs,
        durationUs: shaderUs,
      ),
  ];

  return ParsedTimelineData(
    buildScopeDurations: [buildUs],
    flushLayoutDurations: [layoutUs],
    flushPaintDurations: [paintUs],
    rasterDurations: [rasterUs],
    shaderCompileDurations: shaderUs > 0 ? [shaderUs] : [],
    phaseEvents: phaseEvents,
  );
}
