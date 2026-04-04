import 'package:vm_service/vm_service.dart';

import '../models/phase_event.dart';

/// Parsed timeline data from a batch of VM timeline events.
class ParsedTimelineData {
  ParsedTimelineData({
    this.buildScopeDurations = const [],
    this.flushLayoutDurations = const [],
    this.flushPaintDurations = const [],
    this.rasterDurations = const [],
    this.shaderCompileDurations = const [],
    this.platformChannelEvents = const [],
    this.gcEvents = const [],
    this.buildEventCount = 0,
    this.phaseEvents = const [],
  });

  /// Exact buildScope durations in microseconds.
  final List<int> buildScopeDurations;

  /// Exact flushLayout durations in microseconds.
  final List<int> flushLayoutDurations;

  /// Exact flushPaint durations in microseconds.
  final List<int> flushPaintDurations;

  /// Raster thread durations in microseconds.
  final List<int> rasterDurations;

  /// Shader compilation durations in microseconds.
  final List<int> shaderCompileDurations;

  /// Platform channel method call events.
  final List<TimelineEvent> platformChannelEvents;

  /// GC-related events.
  final List<TimelineEvent> gcEvents;

  /// Number of individual build (widget rebuild) events.
  final int buildEventCount;

  /// Timestamped phase events for frame-event correlation.
  /// Each event carries its absolute monotonic timestamp and duration,
  /// allowing [FrameEventCorrelator] to match events to specific frames.
  final List<PhaseEvent> phaseEvents;

  bool get hasData =>
      buildScopeDurations.isNotEmpty ||
      flushLayoutDurations.isNotEmpty ||
      flushPaintDurations.isNotEmpty ||
      rasterDurations.isNotEmpty ||
      shaderCompileDurations.isNotEmpty ||
      platformChannelEvents.isNotEmpty ||
      gcEvents.isNotEmpty ||
      buildEventCount > 0;

  /// Total buildScope time for this batch.
  int get totalBuildScopeUs => buildScopeDurations.fold(0, (sum, d) => sum + d);

  /// Total flushLayout time for this batch.
  int get totalFlushLayoutUs =>
      flushLayoutDurations.fold(0, (sum, d) => sum + d);

  /// Total flushPaint time for this batch.
  int get totalFlushPaintUs => flushPaintDurations.fold(0, (sum, d) => sum + d);
}

/// Parses raw VM Timeline events into structured [ParsedTimelineData].
///
/// Handles multiple naming conventions across Flutter versions:
/// - `BUILD` (v3+), `Build` (v2.x)
/// - `LAYOUT` / `LAYOUT (root)` (v3.13+), `Layout` (v2.x)
/// - `PAINT` / `PAINT (root)` (v3.13+), `Paint` (v2.x)
///
/// Falls back to thread ID classification when names don't match known patterns.
class TimelineParser {
  TimelineParser._();

  // Known event name patterns (lowercased).
  // Flutter emits BUILD, LAYOUT, PAINT (v3+); LAYOUT (root) / PAINT (root) (v3.13+).
  static bool _isBuild(String name) => name == 'build';
  static bool _isLayout(String name) =>
      name == 'layout' || name.startsWith('layout (');
  static bool _isPaint(String name) =>
      name == 'paint' || name.startsWith('paint (');
  static const _rasterNames = {
    'gpurasterizer::draw',
    'gpurasterizer',
    'rasterizer::dodraw',
    'raster',
  };
  static const _shaderNames = {
    'shadercompilation',
    'shader_compilation',
    'pipeline::create',
  };
  static const _channelNames = {
    'platformchannel',
    'platform_channel',
    'methodchannel',
  };

  /// Prefix for real platform channel timeline events emitted by
  /// `debugProfilePlatformChannels` (lowercased).
  /// Format: 'platform channel send [channelName]#[methodName]'
  static const _channelPrefix = 'platform channel send ';

  /// Parse a string-encoded int from timeline args.
  ///
  /// Flutter writes all timeline args as `Map<String, String>`,
  /// so numeric values arrive as `"3"` not `3`.
  static int? _parseIntArg(Object? raw) {
    if (raw == null) return null;
    if (raw is int) return raw; // defensive: handle if VM ever sends int
    if (raw is String) return int.tryParse(raw);
    return null;
  }

  /// Parse a dirty list string like `"[MyWidget, Other]"` into type names.
  ///
  /// Flutter's `toString()` on lists wraps in `[...]`. Strips brackets
  /// before splitting on `", "`.
  static List<String>? _parseDirtyList(Object? raw) {
    if (raw == null) return null;
    if (raw is! String || raw.isEmpty) return null;
    var s = raw;
    if (s.startsWith('[') && s.endsWith(']')) {
      s = s.substring(1, s.length - 1);
    }
    if (s.isEmpty) return null;
    return s.split(', ');
  }

  /// Parse a list of raw timeline events into [ParsedTimelineData].
  static ParsedTimelineData parse(List<TimelineEvent> events) {
    final buildScopes = <int>[];
    final layouts = <int>[];
    final paints = <int>[];
    final rasters = <int>[];
    final shaders = <int>[];
    final channels = <TimelineEvent>[];
    final gcs = <TimelineEvent>[];
    final phaseEvents = <PhaseEvent>[];
    var buildCount = 0;

    for (final event in events) {
      final json = event.json;
      if (json == null) continue;

      final name = (json['name'] as String? ?? '').toLowerCase();
      final ph = json['ph'] as String? ?? '';
      final dur = json['dur'] as int?;
      final cat = (json['cat'] as String? ?? '').toLowerCase();

      // Complete duration events (ph == 'X') have a 'dur' field
      if (ph == 'X' && dur != null) {
        final ts = json['ts'] as int?;
        final args = json['args'] as Map<String, dynamic>?;

        if (_isBuild(name)) {
          buildScopes.add(dur);
          buildCount++;
          if (ts != null) {
            // Build scope uses prefixed keys: "build scope dirty count" etc.
            phaseEvents.add(PhaseEvent(
              phase: TimelinePhase.build,
              timestampUs: ts,
              durationUs: dur,
              dirtyCount: _parseIntArg(args?['build scope dirty count']),
              dirtyList: _parseDirtyList(args?['build scope dirty list']),
              scopeContext: args?['scope context']?.toString(),
            ));
          }
        } else if (_isLayout(name)) {
          layouts.add(dur);
          if (ts != null) {
            phaseEvents.add(PhaseEvent(
              phase: TimelinePhase.layout,
              timestampUs: ts,
              durationUs: dur,
              dirtyCount: _parseIntArg(args?['dirty count']),
              dirtyList: _parseDirtyList(args?['dirty list']),
            ));
          }
        } else if (_isPaint(name)) {
          paints.add(dur);
          if (ts != null) {
            phaseEvents.add(PhaseEvent(
              phase: TimelinePhase.paint,
              timestampUs: ts,
              durationUs: dur,
              dirtyCount: _parseIntArg(args?['dirty count']),
              dirtyList: _parseDirtyList(args?['dirty list']),
            ));
          }
        } else if (_rasterNames.contains(name)) {
          rasters.add(dur);
          if (ts != null) {
            phaseEvents.add(PhaseEvent(
              phase: TimelinePhase.raster,
              timestampUs: ts,
              durationUs: dur,
            ));
          }
        } else if (_shaderNames.contains(name)) {
          shaders.add(dur);
          if (ts != null) {
            phaseEvents.add(PhaseEvent(
              phase: TimelinePhase.shader,
              timestampUs: ts,
              durationUs: dur,
            ));
          }
        } else if (_channelNames.contains(name) ||
            name.startsWith(_channelPrefix)) {
          channels.add(event);
        } else if (cat.contains('gc')) {
          gcs.add(event);
        }
      } else if (ph == 'B' || ph == 'E') {
        // Begin/End events — count builds
        if (_isBuild(name) && ph == 'B') {
          buildCount++;
        }
        if (cat.contains('gc')) {
          gcs.add(event);
        }
      }
    }

    return ParsedTimelineData(
      buildScopeDurations: buildScopes,
      flushLayoutDurations: layouts,
      flushPaintDurations: paints,
      rasterDurations: rasters,
      shaderCompileDurations: shaders,
      platformChannelEvents: channels,
      gcEvents: gcs,
      buildEventCount: buildCount,
      phaseEvents: phaseEvents,
    );
  }
}
