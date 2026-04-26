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

  // Known event name patterns — multi-case matching to avoid toLowerCase()
  // allocation per event (Pillar 2a M3).
  // Flutter emits BUILD, LAYOUT, PAINT (v3+); LAYOUT (root) / PAINT (root) (v3.13+).
  // Older versions: Build, Layout, Paint (v2.x).
  static bool _isBuild(String name) =>
      name == 'BUILD' || name == 'build' || name == 'Build';
  static bool _isLayout(String name) =>
      name == 'LAYOUT' ||
      name == 'layout' ||
      name == 'Layout' ||
      name.startsWith('LAYOUT (') ||
      name.startsWith('layout (') ||
      name.startsWith('Layout (');
  static bool _isPaint(String name) =>
      name == 'PAINT' ||
      name == 'paint' ||
      name == 'Paint' ||
      name.startsWith('PAINT (') ||
      name.startsWith('paint (') ||
      name.startsWith('Paint (');
  static const _rasterNames = {
    'GPURasterizer::Draw',
    'gpurasterizer::draw',
    'GPURasterizer',
    'gpurasterizer',
    'Rasterizer::DoDraw',
    'rasterizer::dodraw',
    'Raster',
    'raster',
  };
  static const _shaderNames = {
    'ShaderCompilation',
    'shadercompilation',
    'Shader_Compilation',
    'shader_compilation',
    'Pipeline::Create',
    'pipeline::create',
  };
  static const _channelNames = {
    'PlatformChannel',
    'platformchannel',
    'Platform_Channel',
    'platform_channel',
    'MethodChannel',
    'methodchannel',
  };

  /// Prefixes for real platform channel timeline events emitted by
  /// `debugProfilePlatformChannels`.
  /// Format: 'Platform Channel send [channelName]#[methodName]'
  /// (Note: actual Flutter output uses lowercase 'send'.)
  static bool _isChannelEvent(String name) =>
      name.startsWith('Platform Channel send ') ||
      name.startsWith('Platform Channel Send ') ||
      name.startsWith('platform channel send ');

  /// Whether a category string contains a GC marker (case-insensitive).
  static bool _isGcCategory(String cat) =>
      cat.contains('GC') || cat.contains('gc');

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
    // Per-thread stack of unmatched BUILD `ph: 'B'` timestamps. iOS
    // profile-mode emits BUILD as begin/end pairs (no `ph: 'X'`
    // complete-form), so `dur` must be reconstructed from the matched
    // `ph: 'E'` event's `ts`. The stack is keyed by `tid` because B/E
    // pairs interleave across threads in real captures, and a naive
    // single-stack reconstruction would mismatch pairs across threads.
    final pendingBuildBegins = <int, List<Map<String, dynamic>>>{};
    final channels = <TimelineEvent>[];
    final gcs = <TimelineEvent>[];
    final phaseEvents = <PhaseEvent>[];
    var buildCount = 0;

    for (final event in events) {
      final json = event.json;
      if (json == null) continue;

      final name = json['name'] as String? ?? '';
      final ph = json['ph'] as String? ?? '';
      final dur = json['dur'] as int?;
      final cat = json['cat'] as String? ?? '';

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
        } else if (_channelNames.contains(name) || _isChannelEvent(name)) {
          channels.add(event);
        } else if (_isGcCategory(cat)) {
          gcs.add(event);
        }
      } else if (ph == 'B' || ph == 'E') {
        // Begin/End events — iOS profile-mode emits BUILD as B/E pairs
        // instead of `ph: 'X'` complete events. Track unmatched B
        // timestamps per-tid so the matching E can reconstruct
        // `dur = E.ts - B.ts` and feed buildScopes / phaseEvents.
        if (_isBuild(name)) {
          final ts = json['ts'] as int?;
          final tid = json['tid'] as int? ?? 0;
          if (ph == 'B') {
            buildCount++;
            if (ts != null) {
              (pendingBuildBegins[tid] ??= <Map<String, dynamic>>[]).add(json);
            }
          } else {
            // ph == 'E'
            final stack = pendingBuildBegins[tid];
            if (stack != null && stack.isNotEmpty) {
              final beginJson = stack.removeLast();
              final beginTs = beginJson['ts'] as int?;
              if (beginTs != null && ts != null && ts >= beginTs) {
                final dur = ts - beginTs;
                buildScopes.add(dur);
                final args = beginJson['args'] as Map<String, dynamic>?;
                phaseEvents.add(PhaseEvent(
                  phase: TimelinePhase.build,
                  timestampUs: beginTs,
                  durationUs: dur,
                  dirtyCount: _parseIntArg(args?['build scope dirty count']),
                  dirtyList: _parseDirtyList(args?['build scope dirty list']),
                  scopeContext: args?['scope context']?.toString(),
                ));
              }
            }
          }
        }
        if (_isGcCategory(cat)) {
          gcs.add(event);
        }
      } else if (ph == 'b' || ph == 'e') {
        // Async Begin/End events — emitted by TimelineTask.start/finish.
        // Flutter's `debugProfilePlatformChannels` wraps each platform-channel
        // send in a TimelineTask, so channel events arrive as 'b'/'e' pairs
        // (lowercase, async). Capture only the 'b' event to count each call
        // exactly once. 'dur' is null on async events, so duration tracking
        // won't work — but the frequency threshold is what matters.
        if (ph == 'b' && _isChannelEvent(name)) {
          channels.add(event);
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

  /// Extract engine-level startup timestamps and first-frame sub-phase
  /// durations from the VM timeline ring buffer.
  ///
  /// Scans for the same events that `flutter run --trace-startup` captures:
  /// - `FlutterEngineMainEnter` — C++ instant event before Dart code runs
  /// - `Framework initialization` — sync duration event (binding init)
  /// - `Rasterized first useful frame` — instant sync event
  ///
  /// Also captures the first complete-duration (`ph: 'X'`) event for each
  /// rendering sub-phase (BUILD, LAYOUT, PAINT, raster) to populate the
  /// VM sub-phase slots in [StartupMetrics].
  ///
  /// Returns null if no startup events are found (events evicted from the
  /// ring buffer or VM connected too late).
  static StartupTimelineEvents? extractStartupEvents(
    List<TimelineEvent> events,
  ) {
    int? engineEnterUs;
    int? frameworkInitDurationUs;
    int? firstFrameRasterizedUs;
    int? firstBuildScopeDurUs;
    int? firstFlushLayoutDurUs;
    int? firstFlushPaintDurUs;
    int? firstRasterDurUs;

    for (final event in events) {
      final json = event.json;
      if (json == null) continue;

      final name = json['name'] as String? ?? '';
      final ph = json['ph'] as String? ?? '';
      final ts = json['ts'] as int?;

      if (ts == null) continue;

      // FlutterEngineMainEnter — instant event (ph: 'i' or 'I')
      if (name == 'FlutterEngineMainEnter' && (ph == 'i' || ph == 'I')) {
        engineEnterUs = ts;
      }

      // Framework initialization — sync duration event. Only captures
      // 'X' (complete) events with a dur field. B/E pairs are not
      // combined here because the direct Timeline.now measurement in
      // Sleuth.init() is the authoritative source for this metric.
      if (name == 'Framework initialization' && ph == 'X') {
        final dur = json['dur'] as int?;
        if (dur != null) frameworkInitDurationUs = dur;
      }

      // Rasterized first useful frame — instant sync event
      if (name == 'Rasterized first useful frame' && (ph == 'i' || ph == 'I')) {
        firstFrameRasterizedUs = ts;
      }

      // First-frame sub-phase durations — capture only the first 'X' event
      // for each phase. The first timeline poll contains the startup frame's
      // events; subsequent polls are handled by the runtime pipeline.
      if (ph == 'X') {
        final dur = json['dur'] as int?;
        if (dur != null) {
          if (firstBuildScopeDurUs == null && _isBuild(name)) {
            firstBuildScopeDurUs = dur;
          } else if (firstFlushLayoutDurUs == null && _isLayout(name)) {
            firstFlushLayoutDurUs = dur;
          } else if (firstFlushPaintDurUs == null && _isPaint(name)) {
            firstFlushPaintDurUs = dur;
          } else if (firstRasterDurUs == null && _rasterNames.contains(name)) {
            firstRasterDurUs = dur;
          }
        }
      }
    }

    // Return null if we got nothing useful.
    if (engineEnterUs == null &&
        firstFrameRasterizedUs == null &&
        firstBuildScopeDurUs == null &&
        firstFlushLayoutDurUs == null &&
        firstFlushPaintDurUs == null &&
        firstRasterDurUs == null) {
      return null;
    }

    return StartupTimelineEvents(
      engineEnterUs: engineEnterUs,
      frameworkInitDurationUs: frameworkInitDurationUs,
      firstFrameRasterizedUs: firstFrameRasterizedUs,
      firstBuildScopeDurUs: firstBuildScopeDurUs,
      firstFlushLayoutDurUs: firstFlushLayoutDurUs,
      firstFlushPaintDurUs: firstFlushPaintDurUs,
      firstRasterDurUs: firstRasterDurUs,
    );
  }
}

/// Engine-level startup timestamps and first-frame sub-phase durations
/// extracted from the VM timeline ring buffer.
///
/// Mirrors the data that `flutter run --trace-startup` captures in
/// `start_up_info.json`, plus first-frame rendering sub-phase durations.
/// All fields are optional because ring buffer extraction is best-effort
/// — events may have been evicted.
class StartupTimelineEvents {
  const StartupTimelineEvents({
    this.engineEnterUs,
    this.frameworkInitDurationUs,
    this.firstFrameRasterizedUs,
    this.firstBuildScopeDurUs,
    this.firstFlushLayoutDurUs,
    this.firstFlushPaintDurUs,
    this.firstRasterDurUs,
  });

  /// Monotonic microsecond timestamp of `FlutterEngineMainEnter`.
  /// C++ engine entry before any Dart code runs.
  final int? engineEnterUs;

  /// Duration of `Framework initialization` in microseconds.
  /// Covers `BindingBase()` constructor (initInstances + initServiceExtensions).
  final int? frameworkInitDurationUs;

  /// Monotonic microsecond timestamp of `Rasterized first useful frame`.
  final int? firstFrameRasterizedUs;

  /// Duration of the first `buildScope` event in microseconds.
  final int? firstBuildScopeDurUs;

  /// Duration of the first `flushLayout` event in microseconds.
  final int? firstFlushLayoutDurUs;

  /// Duration of the first `flushPaint` event in microseconds.
  final int? firstFlushPaintDurUs;

  /// Duration of the first raster event in microseconds.
  final int? firstRasterDurUs;
}
