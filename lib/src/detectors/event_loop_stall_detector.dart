import 'package:flutter/widgets.dart' show AppLifecycleState;

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/own_work_log.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../vm/timeline_parser.dart';

/// Reports event-loop stalls: stretches in which the UI isolate ran work
/// for 100 ms or more without returning to its event loop.
///
/// **VM-only.** Since Dart 3.9 (Flutter 3.35) the VM posts a
/// `TimerSignificantlyOverdue` event on its `Timer` stream whenever a timer
/// fires 100 ms or more after it was due, in every build except product.
/// A late timer means the isolate was busy, and frames and input waited
/// too. This catches stalls that no frame shows, such as synchronous work
/// in a tap handler that runs before the next frame is scheduled. Apps on
/// Flutter 3.32 to 3.34 have no `Timer` stream, and the detector stays
/// silent there.
///
/// One stall makes the VM post one event per timer it delayed, so events
/// within [mergeWindowMs] of each other count as one stall, and that stall
/// lasts as long as the longest delay among them. The VM measures from the
/// moment the first waiting timer was due, so the reading is a lower
/// bound. A stall is seen only if a timer was due during it. The
/// controller keeps a 50 ms timer running while the detector listens, so
/// every stall longer than 150 ms is seen.
///
/// Before judging a stall, the detector takes off the time that is not the
/// app's:
/// - time while the app was hidden or paused. A stall that began before
///   the app came back counts from the moment Dart handled the first
///   lifecycle change after it ([onAppLifecycleChanged]);
/// - debugger pauses ([onDebuggerPaused], [onDebuggerResumed]) and hot
///   reloads ([excludeWindow]);
/// - Sleuth's own work (`OwnWorkLog`).
///
/// What remains is reported when it is at least [warningMs]. The issue
/// holds for [issueHold] after the latest stall. Its identity is the first
/// stall of the episode, and a stall on another route starts a new
/// episode.
///
/// On Android an activity result can reach Dart before any lifecycle
/// callback. The detector cannot tell that work from the suspension before
/// it, so it leaves out the stall that work causes up to the first
/// lifecycle change after it.
class EventLoopStallDetector extends BaseDetector
    with DetectorMetadataProvider {
  /// Creates the detector.
  EventLoopStallDetector({
    this.warningMs = 100,
    this.criticalMs = 700,
    this.mergeWindowMs = 50,
    this.issueHold = const Duration(seconds: 10),
    DateTime Function()? clock,
    int Function()? monotonicNowUs,
    int Function(int fromUs, int toUs)? ownWorkOverlapUs,
    String? Function()? sourceRouteProvider,
  }) : _clock = clock ?? DateTime.now,
       _monotonicNowUs = monotonicNowUs ?? OwnWorkLog.now,
       _ownWorkOverlapUs = ownWorkOverlapUs ?? ownWorkLog.overlapUs,
       _sourceRouteProvider = sourceRouteProvider ?? (() => null),
       super(
         type: DetectorType.eventLoopStall,
         lifecycle: DetectorLifecycle.vmOnly,
         name: 'Event Loop Stall',
         description:
             'Detects UI-isolate stalls of 100 ms or more from late '
             'timers (Flutter 3.35 and later)',
       );

  /// Shortest stall reported, in milliseconds. The VM reports nothing
  /// under 100.
  final int warningMs;

  /// A stall this long or longer is critical. 700 ms is the frozen-frame
  /// bound Android vitals uses.
  final int criticalMs;

  /// Events this close together (by event time) are one stall.
  final int mergeWindowMs;

  /// How long the issue stays after the latest stall.
  final Duration issueHold;

  final DateTime Function() _clock;
  final int Function() _monotonicNowUs;
  final int Function(int fromUs, int toUs) _ownWorkOverlapUs;
  final String? Function() _sourceRouteProvider;

  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  // Lifecycle: whether the app is hidden, paused or detached, whether the
  // next lifecycle change ends such a stretch, and when Dart handled that
  // change (epoch ms).
  bool _suspended = false;
  bool _awaitingBoundary = false;
  int? _boundaryMs;

  // Debugger pauses and reloads, as epoch-ms windows; an open pause has no
  // end yet.
  final List<(int, int)> _excluded = [];
  int? _pauseStartMs;

  // The stall being merged: the event time of its latest event and the
  // longest delay seen (null when no event's delay parsed).
  int? _stallLastEventMs;
  int? _stallOverdueMs;
  bool _stallReported = false;
  bool _stallExcusedCounted = false;

  // The episode the issue reports.
  int? _episodeIdentityMicros;
  int? _episodeLastStallUs;
  int _episodeStallCount = 0;
  int? _episodeWorstMs;
  bool _episodeHasUnknownLength = false;
  String? _episodeRoute;

  int _excusedStallCount = 0;
  int _ignoredForLifecycleCount = 0;

  /// Stalls of 100 ms or more that were not reported because debugger
  /// pauses, reloads or Sleuth's own work explained enough of them.
  int get excusedStallCount => _excusedStallCount;

  /// Events ignored because the app was hidden or paused, or because the
  /// whole stall lay before it came back.
  int get ignoredForLifecycleCount => _ignoredForLifecycleCount;

  static final RegExp _overduePattern = RegExp(r'(\d+)\s*ms');

  /// How long excluded windows are kept, in milliseconds.
  static const int _excludedRetentionMs = 60000;

  /// The delay in milliseconds a `TimerSignificantlyOverdue` event's
  /// `details` text names ("A timer should have fired N ms ago, ..."), or
  /// null when the text names none.
  static int? parseOverdueMs(String? details) {
    if (details == null) return null;
    final match = _overduePattern.firstMatch(details);
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  @override
  List<PerformanceIssue> get issues {
    _expireHold();
    return List.unmodifiable(_issues);
  }

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) {
    _isEnabled = value;
    if (!value) _clearAll();
  }

  @override
  set vmConnected(bool value) {
    if (!value) {
      _clearAll();
      _pauseStartMs = null;
    }
  }

  /// Tracks the app's lifecycle; called by the controller.
  ///
  /// Hidden, paused and detached suspend the detector. The first change
  /// after them stamps the boundary that later stalls are clipped to.
  /// Timers come due while an app is suspended, and Android freezes cached
  /// processes, so time before the boundary is not the app's. A change from
  /// `inactive` to `resumed` does not move the stamp, so a slow `resumed`
  /// handler still counts.
  void onAppLifecycleChanged(AppLifecycleState state) {
    final suspended =
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (suspended) {
      _suspended = true;
      _awaitingBoundary = true;
      return;
    }
    _suspended = false;
    if (_awaitingBoundary) {
      _boundaryMs = _clock().millisecondsSinceEpoch;
      _awaitingBoundary = false;
    }
  }

  /// The debugger paused the isolate at [epochMs] (a `Pause*` event).
  void onDebuggerPaused(int epochMs) {
    _pauseStartMs ??= epochMs;
  }

  /// The debugger resumed the isolate at [epochMs].
  void onDebuggerResumed(int epochMs) {
    final start = _pauseStartMs;
    if (start == null) return;
    _pauseStartMs = null;
    excludeWindow(start, epochMs);
  }

  /// Takes the window from [startMs] to [endMs] (epoch ms), a debugger
  /// pause or a hot reload, off any stall that overlaps it.
  void excludeWindow(int startMs, int endMs) {
    if (endMs <= startMs) return;
    _excluded.add((startMs, endMs));
    final cutoff = endMs - _excludedRetentionMs;
    _excluded.removeWhere((w) => w.$2 < cutoff);
  }

  /// Feeds one `TimerSignificantlyOverdue` event: its `details` text and
  /// its `timestamp` (epoch milliseconds).
  void recordOverdueTimer({
    required String? details,
    required int? eventTimestampMs,
  }) {
    if (!_isEnabled) return;
    final eventMs = eventTimestampMs ?? _clock().millisecondsSinceEpoch;
    final overdueMs = parseOverdueMs(details);

    if (_suspended) {
      _ignoredForLifecycleCount++;
      return;
    }

    final lastEvent = _stallLastEventMs;
    if (lastEvent != null && (eventMs - lastEvent).abs() <= mergeWindowMs) {
      _stallLastEventMs = eventMs > lastEvent ? eventMs : lastEvent;
      if (overdueMs != null &&
          (_stallOverdueMs == null || overdueMs > _stallOverdueMs!)) {
        _stallOverdueMs = overdueMs;
      }
    } else {
      _stallLastEventMs = eventMs;
      _stallOverdueMs = overdueMs;
      _stallReported = false;
      _stallExcusedCounted = false;
    }
    _evaluateStall(eventMs);
  }

  void _evaluateStall(int eventMs) {
    final overdueMs = _stallOverdueMs;
    int? lengthMs;
    if (overdueMs != null) {
      if (overdueMs < warningMs) return;
      var startMs = eventMs - overdueMs;
      final boundary = _boundaryMs;
      if (boundary != null && startMs < boundary) {
        if (eventMs <= boundary) {
          if (!_stallExcusedCounted) _ignoredForLifecycleCount++;
          _stallExcusedCounted = true;
          return;
        }
        startMs = boundary;
      }
      final spanMs = eventMs - startMs;
      final excludedMs = _excludedOverlapMs(startMs, eventMs, eventMs);
      final ownMs = _ownOverlapMs(startMs, eventMs);
      final remaining = spanMs - excludedMs - ownMs;
      if (remaining < warningMs) {
        if (!_stallExcusedCounted) _excusedStallCount++;
        _stallExcusedCounted = true;
        return;
      }
      lengthMs = remaining;
    }

    final nowUs = _monotonicNowUs();
    _expireHold();
    final route = _sourceRouteProvider();
    if (_episodeIdentityMicros != null && route != _episodeRoute) {
      // A stall on another route is its own episode.
      _startEpisode(route);
    }
    if (_episodeIdentityMicros == null) _startEpisode(route);
    if (!_stallReported) {
      _episodeStallCount++;
      _stallReported = true;
    }
    if (lengthMs == null) {
      _episodeHasUnknownLength = true;
    } else if (_episodeWorstMs == null || lengthMs > _episodeWorstMs!) {
      _episodeWorstMs = lengthMs;
    }
    _episodeLastStallUs = nowUs;
    _publish(_clock());
  }

  void _startEpisode(String? route) {
    _episodeIdentityMicros = _clock().microsecondsSinceEpoch;
    _episodeStallCount = 0;
    _episodeWorstMs = null;
    _episodeHasUnknownLength = false;
    _episodeRoute = route;
    _stallReported = false;
  }

  /// Milliseconds of [startMs] to [endMs] that debugger pauses and reloads
  /// cover, counting overlaps once; an open pause runs to [nowMs].
  int _excludedOverlapMs(int startMs, int endMs, int nowMs) {
    final windows = [
      ..._excluded,
      if (_pauseStartMs != null) (_pauseStartMs!, nowMs),
    ];
    final clipped = <(int, int)>[
      for (final (s, e) in windows)
        if ((e < endMs ? e : endMs) > (s > startMs ? s : startMs))
          (s > startMs ? s : startMs, e < endMs ? e : endMs),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    if (clipped.isEmpty) return 0;
    var covered = 0;
    var (runStart, runEnd) = clipped.first;
    for (final (s, e) in clipped.skip(1)) {
      if (s > runEnd) {
        covered += runEnd - runStart;
        runStart = s;
        runEnd = e;
      } else if (e > runEnd) {
        runEnd = e;
      }
    }
    return covered + (runEnd - runStart);
  }

  /// Milliseconds of [startMs] to [endMs] (epoch) that Sleuth's own work
  /// covered. The log is in `Timeline.now` microseconds, so this reads both
  /// clocks now to map one onto the other.
  int _ownOverlapMs(int startMs, int endMs) {
    final offsetUs = _clock().microsecondsSinceEpoch - _monotonicNowUs();
    return _ownWorkOverlapUs(
          startMs * 1000 - offsetUs,
          endMs * 1000 - offsetUs,
        ) ~/
        1000;
  }

  void _publish(DateTime now) {
    final worst = _episodeWorstMs;
    final count = _episodeStallCount;
    final severity = worst != null && worst >= criticalMs
        ? IssueSeverity.critical
        : IssueSeverity.warning;
    final worstText = worst == null ? 'unknown length' : 'at least $worst ms';
    final ranFor = worst == null
        ? 'The UI isolate stayed away from its event loop for a time the VM '
              'did not give'
        : 'The UI isolate ran work for at least $worst ms without returning '
              'to its event loop';
    final (hint, effort) = FixHintBuilder.eventLoopStall(worstMs: worst);
    _issues
      ..clear()
      ..add(
        PerformanceIssue(
          stableId: 'event_loop_stall',
          severity: severity,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title: count > 1
              ? 'Event Loop Stalls: $count, longest $worstText'
              : 'Event Loop Stall: $worstText',
          detail:
              '$ranFor, so frames, input and timers waited. The VM '
              'measures from the moment the first waiting timer was due, so '
              'the work may have started earlier. '
              '${count > 1 ? '$count stalls in this episode. ' : ''}'
              '${_episodeHasUnknownLength ? 'The VM gave no length for at '
                        'least one of them. ' : ''}'
              'Look for synchronous work in callbacks and builds: JSON '
              'decoding, file reads, large list sorting or image '
              'processing.',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.vmTimeline,
          detectedAt: now,
          dedupIdentityMicros: _episodeIdentityMicros,
          sourceRoute: _episodeRoute,
          extraTraceArgs: {
            if (worst != null) 'observedStallMs': worst.toString(),
            'stallCount': count.toString(),
          },
          confidenceReason:
              'The VM reported a timer that fired at least 100 ms late',
        ),
      );
  }

  void _expireHold() {
    final last = _episodeLastStallUs;
    if (last == null) return;
    if (_monotonicNowUs() - last < issueHold.inMicroseconds) return;
    _issues.clear();
    _episodeIdentityMicros = null;
    _episodeLastStallUs = null;
    _episodeStallCount = 0;
    _episodeWorstMs = null;
    _episodeHasUnknownLength = false;
    _episodeRoute = null;
  }

  /// Ends the hold on the VM poll even when no new event arrives.
  @override
  void processTimelineData(ParsedTimelineData data) => _expireHold();

  void _clearAll() {
    _issues.clear();
    _stallLastEventMs = null;
    _stallOverdueMs = null;
    _stallReported = false;
    _stallExcusedCounted = false;
    _episodeIdentityMicros = null;
    _episodeLastStallUs = null;
    _episodeStallCount = 0;
    _episodeWorstMs = null;
    _episodeHasUnknownLength = false;
    _episodeRoute = null;
  }

  /// Clears the current stall and episode; called on
  /// `Sleuth.markScenarioBegin`.
  void reset() {
    _clearAll();
    _excusedStallCount = 0;
    _ignoredForLifecycleCount = 0;
  }

  @override
  void dispose() => reset();

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'VM-only detector fed by the VM `Timer` stream (Dart 3.9 / Flutter '
        '3.35 and later). The VM posts `TimerSignificantlyOverdue` when a '
        'timer fires 100 ms or more late in a non-product build; the delay '
        'is only in the event\'s `details` text, parsed for the first '
        '`N ms`. Events within 50 ms merge into one stall of the longest '
        'delay. Each stall is clipped to the first lifecycle change after '
        'the app was hidden or paused, then debugger pauses, hot reloads '
        'and Sleuth\'s own work are taken off it; at least 100 ms left is '
        'a warning and 700 ms or more is critical (the Android vitals '
        'frozen-frame bound). Events while the app is hidden or paused are '
        'ignored. The reproducer feeds events through a fake VM service '
        'into the real client and controller, and pins the merge, both '
        'thresholds, the lifecycle clipping, the pause, reload and '
        'own-work subtraction, the 10 s hold, per-route episodes and the '
        'stable episode identity. No on-device captures back it yet.',
    reproducerPath: 'test/validation/event_loop_stall_reproducer_test.dart',
    coveredStableIds: {'event_loop_stall'},
  );
}
