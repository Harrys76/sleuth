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
    this.platformChannelCalls = const [],
    this.gcEvents = const [],
    this.buildEventCount = 0,
    this.phaseEvents = const [],
    this.duplicatesDropped = 0,
    this.maxTimestampUs = -1,
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

  /// Platform channel method call events, one per call (the async `b`
  /// event, or the sync `X` event).
  final List<TimelineEvent> platformChannelEvents;

  /// Completed platform channel calls with a measured duration: async
  /// `b`/`e` pairs matched by `id`, plus sync `X` events. A call whose
  /// begin arrived in an earlier batch completes here. Counting uses
  /// [platformChannelEvents]; this list carries durations only.
  final List<PlatformChannelCall> platformChannelCalls;

  /// GC-related events.
  final List<TimelineEvent> gcEvents;

  /// Number of individual build (widget rebuild) events.
  final int buildEventCount;

  /// Timestamped phase events for frame-event correlation.
  /// Each event carries its absolute monotonic timestamp and duration,
  /// allowing `FrameEventCorrelator` to match events to specific frames.
  final List<PhaseEvent> phaseEvents;

  /// Events skipped because an earlier parse call already processed them
  /// (per-thread cursor rejects). Diagnostic only; not part of [hasData].
  final int duplicatesDropped;

  /// Largest `ts` among the events this call accepted (duplicates
  /// excluded), or −1 when none carried a timestamp.
  final int maxTimestampUs;

  bool get hasData =>
      buildScopeDurations.isNotEmpty ||
      flushLayoutDurations.isNotEmpty ||
      flushPaintDurations.isNotEmpty ||
      rasterDurations.isNotEmpty ||
      shaderCompileDurations.isNotEmpty ||
      platformChannelEvents.isNotEmpty ||
      platformChannelCalls.isNotEmpty ||
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

/// A completed platform channel call.
class PlatformChannelCall {
  const PlatformChannelCall({
    required this.name,
    required this.beginTs,
    required this.durationUs,
    this.id,
  });

  /// Timeline event name (`Platform Channel send <channel>#<method>`).
  final String name;

  /// Monotonic timestamp of the call's begin, in microseconds.
  final int beginTs;

  /// Begin-to-end duration in microseconds.
  final int durationUs;

  /// Async event id for `b`/`e` pairs; null for sync `X` events.
  final String? id;
}

/// Parses raw VM Timeline events into structured [ParsedTimelineData].
///
/// Handles multiple naming conventions across Flutter versions:
/// - `BUILD` (v3+), `Build` (v2.x)
/// - `LAYOUT` / `LAYOUT (root)` (v3.13+), `Layout` (v2.x)
/// - `PAINT` / `PAINT (root)` (v3.13+), `Paint` (v2.x)
///
/// Falls back to thread ID classification when names don't match known patterns.

/// Per-tid cross-call dedup cursor for [TimelineParser.parse].
///
/// [lastTs] is the largest `ts` processed for the thread. Distinct events
/// can share a microsecond, so the cursor also remembers the events at
/// exactly [lastTs] by their `(ph, name, id)` signature. The signature is
/// built only when a second event arrives at [lastTs]; an event with a
/// larger `ts` resets the set, so its size is bounded by the events
/// sharing one timestamp, never by session length.
class TimelineCursor {
  TimelineCursor._(this._lastTs, this._firstAtLastTs);

  int _lastTs;

  /// First event accepted at [lastTs], kept unsigned until a tie.
  Map<String, dynamic>? _firstAtLastTs;

  /// Signatures of the events at [lastTs]; null until a tie.
  Set<String>? _signatures;

  /// Largest `ts` processed for the thread.
  int get lastTs => _lastTs;

  /// Signatures of the events processed at exactly [lastTs].
  Set<String> get seenSignatures =>
      _signatures ?? {TimelineParser._signatureOf(_firstAtLastTs!)};

  void _advance(int ts, Map<String, dynamic> json) {
    _lastTs = ts;
    _firstAtLastTs = json;
    _signatures = null;
  }

  /// Records an event at exactly [lastTs]; false when already seen.
  bool _acceptTie(Map<String, dynamic> json) {
    var signatures = _signatures;
    if (signatures == null) {
      signatures = {TimelineParser._signatureOf(_firstAtLastTs!)};
      _signatures = signatures;
      _firstAtLastTs = null;
    }
    return signatures.add(TimelineParser._signatureOf(json));
  }
}

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

  /// Whether a begin (`B`) or complete (`X`) event is a pipeline or
  /// shader build. Impeller Vulkan emits `PipelineVK::Create` (render
  /// pipelines, on worker threads) and `CreateComputePipeline`; Skia
  /// tags shader-category events with `devtoolsTag: shaders`. Impeller
  /// Metal emits nothing for pipelines. Exact names only: the frame
  /// pipeline emits `PipelineItem` / `PipelineProduce`, and
  /// `CreateShaderLibrary` is a one-shot library load, not a build.
  static bool _isShaderEvent(String name, Map<String, dynamic>? args) =>
      name == 'PipelineVK::Create' ||
      name == 'CreateComputePipeline' ||
      args?['devtoolsTag'] == 'shaders';

  /// Whether an end (`E`) event closes a pending shader begin. Engine
  /// end events carry no args, so a tagged Skia begin is closed by the
  /// next `E` with the same name on the same thread.
  static bool _isShaderEnd(
    String name,
    int tid,
    Map<int, List<Map<String, dynamic>>> pending,
  ) {
    if (_isShaderEvent(name, null)) return true;
    final stack = pending[tid];
    return stack != null && stack.isNotEmpty && stack.last['name'] == name;
  }

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

  /// Maximum unmatched BUILD `ph: 'B'` events retained per thread.
  /// Beyond this, the OLDEST unmatched B is dropped on each new B.
  /// Conservative ceiling — typical iPhone Flutter app emits <60 BUILDs
  /// per second per thread (60 FPS), so 100 entries = >1.5 s buffer of
  /// unmatched begins. Capping prevents unbounded growth when a session
  /// produces orphan B events (B without matching E — e.g. due to event
  /// loss or VM service buffer overflow).
  static const int _pendingBuildBeginsCapPerTid = 100;

  /// Per-tid cap for unmatched LAYOUT / PAINT / raster `ph: 'B'`
  /// begins. Same conservative ceiling as BUILD — typical iPhone
  /// emits one outermost LAYOUT/PAINT/raster scope per frame plus a
  /// handful of nested children, so 100 entries comfortably covers
  /// >1.5 s of pending begins per thread under sustained 60 FPS.
  static const int _pendingPhaseBeginsCapPerTid = 100;

  /// Cap for in-flight platform channel calls awaiting their `e` event.
  /// Captures show at most 9 in flight; beyond the cap the oldest begin
  /// is dropped.
  static const int pendingChannelBeginsCap = 256;

  /// Dedup signature `'$ph|$name|$id'` of an event.
  static String _signatureOf(Map<String, dynamic> json) =>
      '${json['ph'] ?? ''}|${json['name'] ?? ''}|${json['id'] ?? ''}';

  /// Push-or-pop a per-tid B/E begins stack for a phase event,
  /// invoking [onOutermost] only when the pop drains the stack EMPTY
  /// — i.e. the popped E closed the outermost scope on this thread.
  /// This is the shared body for LAYOUT / PAINT / raster
  /// reconstruction; nested scopes (`LAYOUT (root)` wrapping
  /// `LAYOUT`, raster trio nesting) push without emitting a duration
  /// so the outer scope's E is the only one that contributes to the
  /// duration list. Nesting is detected at the per-tid stack level so
  /// no name comparison is required.
  /// Longest begin/end span the reconstruction accepts as one scope.
  ///
  /// Under heavy jank the VM timeline ring buffer drops events. A dropped
  /// `B` leaves a later `E` to pop an older begin, and on a quiet screen
  /// that span is the gap between two frames (seconds), which read as a
  /// multi-second BUILD or raster scope. A real scope of that length would
  /// freeze the UI thread, which `jank_detected` / `sustained_jank`
  /// report from frame timing instead. Pairs longer than this are
  /// discarded, and pending begins older than this are evicted when a new
  /// begin arrives so the stale entry cannot keep every later outermost
  /// pair from being credited.
  static const int maxReconstructedPhaseUs = 2000000;

  static void _reconstructPhaseBE({
    required Map<String, dynamic> json,
    required String ph,
    required Map<int, List<Map<String, dynamic>>> pending,
    required void Function(Map<String, dynamic> beginJson, int beginTs, int dur)
    onOutermost,
  }) {
    final ts = json['ts'] as int?;
    final tid = json['tid'] as int? ?? 0;
    if (ph == 'B') {
      if (ts == null) return;
      final stack = pending[tid] ??= <Map<String, dynamic>>[];
      stack.removeWhere((b) {
        final bTs = b['ts'] as int?;
        return bTs != null && ts - bTs > maxReconstructedPhaseUs;
      });
      stack.add(json);
      if (stack.length > _pendingPhaseBeginsCapPerTid) {
        stack.removeAt(0);
      }
    } else {
      // ph == 'E'
      final stack = pending[tid];
      if (stack == null || stack.isEmpty) return;
      final beginJson = stack.removeLast();
      final beginTs = beginJson['ts'] as int?;
      if (beginTs == null || ts == null || ts < beginTs) return;
      final dur = ts - beginTs;
      if (dur > maxReconstructedPhaseUs) return; // mis-paired after a loss
      if (stack.isNotEmpty) return; // not outermost — skip emission
      onOutermost(beginJson, beginTs, dur);
    }
  }

  /// Parse raw timeline events into [ParsedTimelineData].
  ///
  /// [pendingBuildBegins] carries unmatched BUILD `ph: 'B'` events
  /// across calls so iOS B/E pairs straddling poll boundaries
  /// reconstruct correctly. Null = fresh per call.
  ///
  /// [pendingLayoutBegins], [pendingPaintBegins], [pendingRasterBegins],
  /// [pendingShaderBegins] extend the same cross-batch reconstruction to
  /// LAYOUT, PAINT, raster, and pipeline/shader build events. iOS profile mode (Impeller backend, observed on
  /// Flutter 3.41.x / iOS 17.5) emits these phases as nested `B`/`E`
  /// pairs with no `X`-form complete events: `LAYOUT (root)` wraps
  /// `LAYOUT`, `PAINT (root)` wraps `PAINT`, and the raster trio
  /// (`GPURasterizer::Draw` → `Rasterizer::DoDraw` →
  /// `Rasterizer::DrawToSurfaces`) nests on the raster thread.
  /// Counting every popped pair would double-count nested scopes;
  /// instead a duration is emitted only when the per-tid stack drains
  /// EMPTY after the pop, crediting only the outermost scope per
  /// frame. Skia X-form emissions continue through the unchanged X
  /// branch above. Null = fresh per call.
  ///
  /// [pendingChannelBegins] maps an async platform-channel call `id` to
  /// its `b` timestamp so the matching `e` (same or later batch) yields a
  /// [PlatformChannelCall] with a duration. Capped at
  /// [pendingChannelBeginsCap] (oldest dropped). Null = fresh per call.
  ///
  /// [cursorsByTid] is a per-thread cross-call dedup cursor; events
  /// with `ts < cursor.lastTs`, or with `ts == cursor.lastTs` and a
  /// signature already in `cursor.seenSignatures`, are skipped.
  /// Signature is `'$ph|$name|${id ?? ""}'`, built only for events at
  /// exactly `cursor.lastTs`. Skipped for events without `ts` (metadata
  /// `M` events). Null = fresh per call. Caller clears the map on
  /// session reset.
  ///
  /// [minTimestampUs] skips every event with a smaller `ts` (counted in
  /// [ParsedTimelineData.duplicatesDropped]); the poll loop sets it when
  /// it had to read the whole buffer instead of a window.
  static ParsedTimelineData parse(
    List<TimelineEvent> events, {
    Map<int, List<Map<String, dynamic>>>? pendingBuildBegins,
    Map<int, List<Map<String, dynamic>>>? pendingLayoutBegins,
    Map<int, List<Map<String, dynamic>>>? pendingPaintBegins,
    Map<int, List<Map<String, dynamic>>>? pendingRasterBegins,
    Map<int, List<Map<String, dynamic>>>? pendingShaderBegins,
    Map<String, int>? pendingChannelBegins,
    Map<int, TimelineCursor>? cursorsByTid,
    int minTimestampUs = 0,
  }) {
    final buildScopes = <int>[];
    final layouts = <int>[];
    final paints = <int>[];
    final rasters = <int>[];
    final shaders = <int>[];
    // Per-thread stack of unmatched BUILD `ph: 'B'` events. iOS
    // profile-mode emits BUILD as begin/end pairs (no `ph: 'X'`
    // complete-form), so `dur` must be reconstructed from the matched
    // `ph: 'E'` event's `ts`. The stack is keyed by `tid` because B/E
    // pairs interleave across threads in real captures, and a naive
    // single-stack reconstruction would mismatch pairs across threads.
    final pendingBuilds =
        pendingBuildBegins ?? <int, List<Map<String, dynamic>>>{};
    final pendingLayouts =
        pendingLayoutBegins ?? <int, List<Map<String, dynamic>>>{};
    final pendingPaints =
        pendingPaintBegins ?? <int, List<Map<String, dynamic>>>{};
    final pendingRasters =
        pendingRasterBegins ?? <int, List<Map<String, dynamic>>>{};
    final pendingShaders =
        pendingShaderBegins ?? <int, List<Map<String, dynamic>>>{};
    final pendingChannels = pendingChannelBegins ?? <String, int>{};
    final cursors = cursorsByTid ?? <int, TimelineCursor>{};
    final channels = <TimelineEvent>[];
    final channelCalls = <PlatformChannelCall>[];
    final gcs = <TimelineEvent>[];
    final phaseEvents = <PhaseEvent>[];
    var buildCount = 0;
    var duplicates = 0;
    var maxTs = -1;
    int? cachedTid;
    TimelineCursor? cachedCursor;

    for (final event in events) {
      final json = event.json;
      if (json == null) continue;

      // Cross-call dedup: skip events already observed in a prior parse
      // call. Uses the event's own monotonic `ts` (microseconds since
      // process boot) as the per-tid watermark — drift-free across
      // wall-clock skews. Skipped for events without `ts` (metadata
      // events like process_name / thread_name); those are passed
      // through every call but never accumulated into output buckets,
      // so re-processing is a no-op.
      //
      // The `ts` comparison runs before any other field is read, so a
      // re-read event costs three map lookups and no allocation. The `(ph, name, id)`
      // signature is built only for events at exactly `lastTs`, where
      // two distinct events can share a microsecond (instant events with
      // different names, async pairs with different `id`).
      final ts = json['ts'];
      if (ts is int) {
        if (ts < minTimestampUs) {
          duplicates++;
          continue;
        }
        final rawTid = json['tid'];
        final tid = rawTid is int ? rawTid : 0;
        // Events arrive in per-thread blocks; reuse the previous lookup.
        TimelineCursor? cursor;
        if (tid == cachedTid) {
          cursor = cachedCursor;
        } else {
          cursor = cursors[tid];
          cachedTid = tid;
          cachedCursor = cursor;
        }
        if (cursor == null) {
          cachedCursor = cursors[tid] = TimelineCursor._(ts, json);
        } else if (ts > cursor._lastTs) {
          cursor._advance(ts, json);
        } else if (ts < cursor._lastTs || !cursor._acceptTie(json)) {
          duplicates++;
          continue;
        }
        if (ts > maxTs) maxTs = ts;
      }

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
            phaseEvents.add(
              PhaseEvent(
                phase: TimelinePhase.build,
                timestampUs: ts,
                durationUs: dur,
                dirtyCount: _parseIntArg(args?['build scope dirty count']),
                dirtyList: _parseDirtyList(args?['build scope dirty list']),
                scopeContext: args?['scope context']?.toString(),
              ),
            );
          }
        } else if (_isLayout(name)) {
          layouts.add(dur);
          if (ts != null) {
            phaseEvents.add(
              PhaseEvent(
                phase: TimelinePhase.layout,
                timestampUs: ts,
                durationUs: dur,
                dirtyCount: _parseIntArg(args?['dirty count']),
                dirtyList: _parseDirtyList(args?['dirty list']),
              ),
            );
          }
        } else if (_isPaint(name)) {
          paints.add(dur);
          if (ts != null) {
            phaseEvents.add(
              PhaseEvent(
                phase: TimelinePhase.paint,
                timestampUs: ts,
                durationUs: dur,
                dirtyCount: _parseIntArg(args?['dirty count']),
                dirtyList: _parseDirtyList(args?['dirty list']),
              ),
            );
          }
        } else if (_rasterNames.contains(name)) {
          rasters.add(dur);
          if (ts != null) {
            phaseEvents.add(
              PhaseEvent(
                phase: TimelinePhase.raster,
                timestampUs: ts,
                durationUs: dur,
              ),
            );
          }
        } else if (_isShaderEvent(name, args)) {
          shaders.add(dur);
          if (ts != null) {
            phaseEvents.add(
              PhaseEvent(
                phase: TimelinePhase.shader,
                timestampUs: ts,
                durationUs: dur,
              ),
            );
          }
        } else if (_channelNames.contains(name) || _isChannelEvent(name)) {
          channels.add(event);
          if (ts != null) {
            channelCalls.add(
              PlatformChannelCall(name: name, beginTs: ts, durationUs: dur),
            );
          }
        } else if (_isGcCategory(cat)) {
          gcs.add(event);
        }
      } else if (ph == 'B' || ph == 'E') {
        // Begin/End events — iOS profile-mode emits BUILD / LAYOUT /
        // PAINT / raster as B/E pairs instead of `ph: 'X'` complete
        // events. Track unmatched B timestamps per-tid so the matching
        // E can reconstruct `dur = E.ts - B.ts` and feed the phase
        // duration lists / phaseEvents.
        //
        // BUILD reconstruction: every B/E pair contributes a duration
        // (BUILDs do not nest meaningfully on iOS — `_isBuild` matches
        // only the bare `BUILD` name, not `BUILD (root)` or similar).
        //
        // LAYOUT / PAINT / raster reconstruction: nested begin/end
        // pairs DO occur on iOS Impeller (`LAYOUT (root)` wraps
        // `LAYOUT`; raster trio nests on the raster thread). To avoid
        // double-counting nested scopes the duration is emitted only
        // when the per-tid stack drains EMPTY after the pop — i.e. we
        // credit the OUTERMOST scope per frame, matching the
        // single-duration accounting that Skia X-form emissions
        // produce.
        if (_isBuild(name)) {
          final ts = json['ts'] as int?;
          final tid = json['tid'] as int? ?? 0;
          if (ph == 'B') {
            buildCount++;
            if (ts != null) {
              final stack = pendingBuilds[tid] ??= <Map<String, dynamic>>[];
              // A begin older than the span cap lost its end; evict it so
              // it cannot pair with a much later end.
              stack.removeWhere((b) {
                final bTs = b['ts'] as int?;
                return bTs != null && ts - bTs > maxReconstructedPhaseUs;
              });
              stack.add(json);
              // Drop oldest unmatched begin if cap exceeded — prevents
              // unbounded growth under sustained orphan-B emission.
              if (stack.length > _pendingBuildBeginsCapPerTid) {
                stack.removeAt(0);
              }
            }
          } else {
            // ph == 'E'
            final stack = pendingBuilds[tid];
            if (stack != null && stack.isNotEmpty) {
              final beginJson = stack.removeLast();
              final beginTs = beginJson['ts'] as int?;
              if (beginTs != null &&
                  ts != null &&
                  ts >= beginTs &&
                  ts - beginTs <= maxReconstructedPhaseUs) {
                final dur = ts - beginTs;
                buildScopes.add(dur);
                final args = beginJson['args'] as Map<String, dynamic>?;
                phaseEvents.add(
                  PhaseEvent(
                    phase: TimelinePhase.build,
                    timestampUs: beginTs,
                    durationUs: dur,
                    dirtyCount: _parseIntArg(args?['build scope dirty count']),
                    dirtyList: _parseDirtyList(args?['build scope dirty list']),
                    scopeContext: args?['scope context']?.toString(),
                  ),
                );
              }
            }
          }
        } else if (_isLayout(name)) {
          _reconstructPhaseBE(
            json: json,
            ph: ph,
            pending: pendingLayouts,
            onOutermost: (beginJson, beginTs, dur) {
              layouts.add(dur);
              final args = beginJson['args'] as Map<String, dynamic>?;
              phaseEvents.add(
                PhaseEvent(
                  phase: TimelinePhase.layout,
                  timestampUs: beginTs,
                  durationUs: dur,
                  dirtyCount: _parseIntArg(args?['dirty count']),
                  dirtyList: _parseDirtyList(args?['dirty list']),
                ),
              );
            },
          );
        } else if (_isPaint(name)) {
          _reconstructPhaseBE(
            json: json,
            ph: ph,
            pending: pendingPaints,
            onOutermost: (beginJson, beginTs, dur) {
              paints.add(dur);
              final args = beginJson['args'] as Map<String, dynamic>?;
              phaseEvents.add(
                PhaseEvent(
                  phase: TimelinePhase.paint,
                  timestampUs: beginTs,
                  durationUs: dur,
                  dirtyCount: _parseIntArg(args?['dirty count']),
                  dirtyList: _parseDirtyList(args?['dirty list']),
                ),
              );
            },
          );
        } else if (_rasterNames.contains(name)) {
          _reconstructPhaseBE(
            json: json,
            ph: ph,
            pending: pendingRasters,
            onOutermost: (beginJson, beginTs, dur) {
              rasters.add(dur);
              phaseEvents.add(
                PhaseEvent(
                  phase: TimelinePhase.raster,
                  timestampUs: beginTs,
                  durationUs: dur,
                ),
              );
            },
          );
        } else if (ph == 'B'
            ? _isShaderEvent(name, json['args'] as Map<String, dynamic>?)
            : _isShaderEnd(name, json['tid'] as int? ?? 0, pendingShaders)) {
          // Pipeline/shader builds are `TRACE_EVENT` scopes: a begin
          // plus an arg-less end, never an `X` event. Outermost scope
          // per thread is credited.
          _reconstructPhaseBE(
            json: json,
            ph: ph,
            pending: pendingShaders,
            onOutermost: (beginJson, beginTs, dur) {
              shaders.add(dur);
              phaseEvents.add(
                PhaseEvent(
                  phase: TimelinePhase.shader,
                  timestampUs: beginTs,
                  durationUs: dur,
                ),
              );
            },
          );
        }
        if (_isGcCategory(cat)) {
          gcs.add(event);
        }
      } else if (ph == 'b' || ph == 'e') {
        // Async Begin/End events — emitted by TimelineTask.start/finish.
        // Flutter's `debugProfilePlatformChannels` wraps each platform-channel
        // send in a TimelineTask, so channel events arrive as 'b'/'e' pairs
        // (lowercase, async, no 'dur'). The 'b' event counts the call
        // exactly once; the 'e' with the same `id` gives its duration.
        if (_isChannelEvent(name)) {
          final rawId = json['id'];
          final id = rawId?.toString();
          final ts = json['ts'] as int?;
          if (ph == 'b') {
            channels.add(event);
            if (id != null && ts != null) {
              pendingChannels.remove(id);
              pendingChannels[id] = ts;
              if (pendingChannels.length > pendingChannelBeginsCap) {
                pendingChannels.remove(pendingChannels.keys.first);
              }
            }
          } else if (id != null && ts != null) {
            final beginTs = pendingChannels.remove(id);
            if (beginTs != null && ts >= beginTs) {
              channelCalls.add(
                PlatformChannelCall(
                  name: name,
                  beginTs: beginTs,
                  durationUs: ts - beginTs,
                  id: id,
                ),
              );
            }
          }
        }
      }
    }

    // Cursor advances happen inline at the parse-loop entry (per-event
    // mutation of `cursors[tid]`), so no separate commit step is
    // needed here. The caller-supplied `cursorsByTid` map was updated
    // in place via the same reference.

    return ParsedTimelineData(
      buildScopeDurations: buildScopes,
      flushLayoutDurations: layouts,
      flushPaintDurations: paints,
      rasterDurations: rasters,
      shaderCompileDurations: shaders,
      platformChannelEvents: channels,
      platformChannelCalls: channelCalls,
      gcEvents: gcs,
      buildEventCount: buildCount,
      phaseEvents: phaseEvents,
      duplicatesDropped: duplicates,
      maxTimestampUs: maxTs,
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
