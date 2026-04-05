import 'package:vm_service/vm_service.dart';
import 'package:sleuth/src/models/phase_event.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

/// Factory for empty timeline data (all zeros).
ParsedTimelineData emptyTimelineData() => ParsedTimelineData();

/// Factory for timeline data with only build event count.
ParsedTimelineData highBuildActivityData({int buildCount = 25}) =>
    ParsedTimelineData(buildEventCount: buildCount);

/// Factory for raster-dominant timeline data.
ParsedTimelineData rasterDominantData({
  int rasterUs = 30000,
  int buildUs = 5000,
  int layoutUs = 3000,
  int paintUs = 2000,
}) =>
    ParsedTimelineData(
      rasterDurations: [rasterUs],
      buildScopeDurations: [buildUs],
      flushLayoutDurations: [layoutUs],
      flushPaintDurations: [paintUs],
    );

/// Factory for timeline data with paint events only.
ParsedTimelineData highPaintActivityData({int paintCount = 40}) =>
    ParsedTimelineData(
      flushPaintDurations: List.generate(paintCount, (_) => 1000),
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
}) =>
    ParsedTimelineData(buildScopeDurations: buildScopeDurationsUs);

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
}) =>
    ParsedTimelineData(
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
}) =>
    ParsedTimelineData(
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

/// Factory for build activity data with enriched dirty names.
ParsedTimelineData enrichedBuildActivityData({
  int buildCount = 25,
  List<String>? dirtyList,
}) =>
    ParsedTimelineData(
      buildEventCount: buildCount,
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
ParsedTimelineData shaderCompileData({
  List<int> shaderDurationsUs = const [],
}) =>
    ParsedTimelineData(shaderCompileDurations: shaderDurationsUs);

/// Factory for timeline data with platform channel events (for PlatformChannelDetector).
ParsedTimelineData platformChannelData({
  int channelEventCount = 0,
  int durUs = 100,
  String? methodName,
}) =>
    ParsedTimelineData(
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
