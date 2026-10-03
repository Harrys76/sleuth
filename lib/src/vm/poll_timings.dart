import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Cost of one VM timeline poll, split by segment.
///
/// All durations are wall-clock microseconds measured on the UI isolate.
/// Two kinds of segment:
///
/// * UI-isolate CPU: [decodeMicros], [parseMicros] and [dispatchMicros]
///   run synchronously on the UI isolate and hold off frame work for
///   their whole length. [uiBlockingMicros] is their sum.
/// * Wall time across awaits: [rpcMicros] and [tailMicros] include the
///   VM-side work and the transport. The UI isolate is free for most of
///   it, except the part of [rpcMicros] that is [decodeMicros].
///
/// Read through `Sleuth.lastPollTimings` or the `lastPoll*` keys of
/// `ext.sleuth.diagnose`.
@immutable
class PollTimings {
  /// Creates a timings record. Durations and counts are non-negative,
  /// except [responseChars] and [decodeMicros], which are −1 when the raw
  /// response could not be matched to the timeline request.
  const PollTimings({
    required this.rpcMicros,
    this.decodeMicros = -1,
    required this.parseMicros,
    required this.dispatchMicros,
    required this.tailMicros,
    required this.eventCount,
    required this.responseChars,
    required this.duplicatesDropped,
    required this.completedAt,
    this.windowFallback = false,
    this.dispatchDetectorsMicros = 0,
    this.dispatchCorrelateMicros = 0,
    this.dispatchAggregateMicros = 0,
    this.dispatchOtherMicros = 0,
    this.tailCpuSamplesMicros = 0,
    this.tailAllocationProfileMicros = 0,
    this.tailMemoryMicros = 0,
  });

  /// Await of the `getVMTimeline` RPC: wall time covering the VM-side
  /// serialization, the transport, and [decodeMicros].
  final int rpcMicros;

  /// Part of [rpcMicros] spent on the UI isolate after the raw response
  /// arrived: the JSON decode and `Timeline` construction that
  /// package:vm_service runs before the future completes, plus the
  /// resumption of the await. −1 when the raw response could not be
  /// matched to the request (no wire streams, or a failed RPC).
  final int decodeMicros;

  /// Timeline parse plus the stale-begin sweep (and, on the first poll of
  /// a session, startup-event extraction).
  final int parseMicros;

  /// Time spent in the `onTimelineData` callback (detector dispatch and
  /// issue aggregation). Zero when the batch was not dispatched.
  final int dispatchMicros;

  /// Remaining RPCs of the poll (the timeline clock read that bounds the
  /// fetch window and the heap memory sample).
  final int tailMicros;

  /// Raw events returned by the VM in this poll.
  final int eventCount;

  /// Length in characters of the raw `getVMTimeline` response, or −1 when
  /// it could not be matched to the request.
  final int responseChars;

  /// Events this poll skipped because an earlier poll already processed
  /// them.
  final int duplicatesDropped;

  /// Wall-clock time the poll finished.
  final DateTime completedAt;

  /// Whether the poll read the whole timeline buffer because the timeline
  /// clock could not bound a window (failed read, or a reading behind the
  /// newest event already seen).
  final bool windowFallback;

  /// Part of [dispatchMicros] spent feeding the batch to the detectors
  /// (`processTimelineData` and `evaluateNow`).
  final int dispatchDetectorsMicros;

  /// Part of [dispatchMicros] spent matching the batch to frames and
  /// building the frame verdict.
  final int dispatchCorrelateMicros;

  /// Part of [dispatchMicros] spent aggregating, ranking and publishing
  /// the issue list.
  final int dispatchAggregateMicros;

  /// Rest of [dispatchMicros]: capture bookkeeping, the export buffers,
  /// and issuing the jank frame's CPU-samples request. The four dispatch
  /// parts sum to [dispatchMicros].
  final int dispatchOtherMicros;

  /// Part of [tailMicros] during which a `getCpuSamples` request (jank
  /// frame attribution) was in flight. Overlaps the other tail parts.
  final int tailCpuSamplesMicros;

  /// Part of [tailMicros] during which a `getAllocationProfile` request
  /// was in flight. Overlaps the other tail parts.
  final int tailAllocationProfileMicros;

  /// Await of the heap `getMemoryUsage` sample inside [tailMicros].
  final int tailMemoryMicros;

  /// Sum of the four top-level segments ([decodeMicros] is inside
  /// [rpcMicros]).
  int get totalMicros => rpcMicros + parseMicros + dispatchMicros + tailMicros;

  /// Time the poll held the UI isolate: [decodeMicros] (when measured)
  /// plus [parseMicros] and [dispatchMicros]. Excludes the awaited RPC
  /// and tail time, during which the isolate can run frames. A frame
  /// that needs the isolate during this time is delayed by up to this
  /// much.
  int get uiBlockingMicros =>
      (decodeMicros >= 0 ? decodeMicros : 0) + parseMicros + dispatchMicros;

  /// JSON-encodable form.
  Map<String, Object?> toJson() => <String, Object?>{
    'rpcMicros': rpcMicros,
    'decodeMicros': decodeMicros,
    'parseMicros': parseMicros,
    'dispatchMicros': dispatchMicros,
    'tailMicros': tailMicros,
    'eventCount': eventCount,
    'responseChars': responseChars,
    'duplicatesDropped': duplicatesDropped,
    'completedAtMicros': completedAt.microsecondsSinceEpoch,
    'windowFallback': windowFallback,
    'dispatchDetectorsMicros': dispatchDetectorsMicros,
    'dispatchCorrelateMicros': dispatchCorrelateMicros,
    'dispatchAggregateMicros': dispatchAggregateMicros,
    'dispatchOtherMicros': dispatchOtherMicros,
    'tailCpuSamplesMicros': tailCpuSamplesMicros,
    'tailAllocationProfileMicros': tailAllocationProfileMicros,
    'tailMemoryMicros': tailMemoryMicros,
  };

  @override
  String toString() =>
      'PollTimings(rpc: $rpcMicros us (decode $decodeMicros), '
      'parse: $parseMicros us, '
      'dispatch: $dispatchMicros us (detectors $dispatchDetectorsMicros, '
      'correlate $dispatchCorrelateMicros, '
      'aggregate $dispatchAggregateMicros, other $dispatchOtherMicros), '
      'tail: $tailMicros us (memory $tailMemoryMicros, '
      'cpu samples $tailCpuSamplesMicros, '
      'allocation profile $tailAllocationProfileMicros), '
      'events: $eventCount, chars: $responseChars, '
      'duplicates: $duplicatesDropped'
      '${windowFallback ? ', window fallback' : ''})';
}

/// Rolling per-segment maximum over the most recent polls.
class PollTimingsWindow {
  /// Creates a window holding the last [capacity] polls.
  PollTimingsWindow({this.capacity = 32}) : assert(capacity > 0);

  /// Number of polls the maxima are taken over.
  final int capacity;

  final List<PollTimings> _ring = <PollTimings>[];
  int _next = 0;

  /// Polls currently held.
  int get length => _ring.length;

  /// Adds one poll, replacing the oldest once the window is full.
  void add(PollTimings timings) {
    if (_ring.length < capacity) {
      _ring.add(timings);
    } else {
      _ring[_next] = timings;
    }
    _next = (_next + 1) % capacity;
  }

  /// Drops every held poll.
  void clear() {
    _ring.clear();
    _next = 0;
  }

  int? _max(int Function(PollTimings t) read) {
    if (_ring.isEmpty) return null;
    var best = read(_ring.first);
    for (var i = 1; i < _ring.length; i++) {
      final v = read(_ring[i]);
      if (v > best) best = v;
    }
    return best;
  }

  /// Largest [PollTimings.rpcMicros] in the window; null when empty.
  int? get maxRpcMicros => _max((t) => t.rpcMicros);

  /// Largest [PollTimings.decodeMicros] in the window (−1 when no poll
  /// in it was matched); null when empty.
  int? get maxDecodeMicros => _max((t) => t.decodeMicros);

  /// Largest [PollTimings.parseMicros] in the window; null when empty.
  int? get maxParseMicros => _max((t) => t.parseMicros);

  /// Largest [PollTimings.dispatchMicros] in the window; null when empty.
  int? get maxDispatchMicros => _max((t) => t.dispatchMicros);
}

/// Split of one timeline dispatch, reported by the dispatch callback
/// owner and read by the poll right after the callback returns.
typedef DispatchSegments = ({int detectors, int correlate, int aggregate});

/// In-flight intervals of one RPC kind on a monotonic clock, so a poll
/// can report how much of its tail overlapped requests it did not issue.
class RpcSpanTracker {
  /// Creates a tracker reading times from [clock] (microseconds).
  RpcSpanTracker(this._clock);

  final int Function() _clock;
  final List<(int, int)> _spans = <(int, int)>[];
  int _nextId = 0;
  final Map<int, int> _openById = <int, int>{};

  /// Requests still in flight.
  int get openCount => _openById.length;

  /// Intervals currently held (open or closed).
  int get length => _spans.length + _openById.length;

  /// Tracks [rpc] from now until it completes, then returns its result.
  Future<T> track<T>(Future<T> rpc) {
    final id = _nextId++;
    _openById[id] = _clock();
    return rpc.whenComplete(() {
      final start = _openById.remove(id);
      if (start != null) _spans.add((start, _clock()));
    });
  }

  /// Drops closed intervals that ended before [micros].
  void pruneBefore(int micros) {
    _spans.removeWhere((s) => s.$2 < micros);
  }

  /// Drops every interval, open or closed.
  void clear() {
    _spans.clear();
    _openById.clear();
  }

  /// Microseconds inside [windows] (each `(start, end)`) during which at
  /// least one tracked request was in flight. Requests still open count
  /// up to now.
  int overlapWith(List<(int, int)> windows) {
    if (windows.isEmpty || (_spans.isEmpty && _openById.isEmpty)) return 0;
    final now = _clock();
    final all = <(int, int)>[
      ..._spans,
      for (final start in _openById.values) (start, now),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    var total = 0;
    for (final w in windows) {
      var cursor = w.$1;
      for (final s in all) {
        final from = math.max(s.$1, cursor);
        final to = math.min(s.$2, w.$2);
        if (to > from) {
          total += to - from;
          cursor = to;
        }
      }
    }
    return total;
  }
}
