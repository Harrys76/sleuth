import 'package:flutter/foundation.dart';

/// Cost of one VM timeline poll, split by segment.
///
/// All durations are wall-clock microseconds measured on the UI isolate.
/// Read through `Sleuth.lastPollTimings` or the `lastPoll*` keys of
/// `ext.sleuth.diagnose`.
@immutable
class PollTimings {
  /// Creates a timings record. Durations and counts are non-negative,
  /// except [responseChars], which is −1 when the raw response could not
  /// be matched to the timeline request.
  const PollTimings({
    required this.rpcMicros,
    required this.parseMicros,
    required this.dispatchMicros,
    required this.tailMicros,
    required this.eventCount,
    required this.responseChars,
    required this.duplicatesDropped,
    required this.completedAt,
  });

  /// Await of the `getVMTimeline` RPC, including the JSON decode and the
  /// `Timeline` construction that package:vm_service runs on the UI
  /// isolate before the future completes.
  final int rpcMicros;

  /// Timeline parse plus the stale-begin sweep (and, on the first poll of
  /// a session, startup-event extraction).
  final int parseMicros;

  /// Time spent in the `onTimelineData` callback (detector dispatch and
  /// issue aggregation). Zero when the batch was not dispatched.
  final int dispatchMicros;

  /// Remaining RPCs of the poll (timeline housekeeping and the heap
  /// memory sample).
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

  /// Sum of the four measured segments.
  int get totalMicros => rpcMicros + parseMicros + dispatchMicros + tailMicros;

  /// JSON-encodable form.
  Map<String, Object?> toJson() => <String, Object?>{
    'rpcMicros': rpcMicros,
    'parseMicros': parseMicros,
    'dispatchMicros': dispatchMicros,
    'tailMicros': tailMicros,
    'eventCount': eventCount,
    'responseChars': responseChars,
    'duplicatesDropped': duplicatesDropped,
    'completedAtMicros': completedAt.microsecondsSinceEpoch,
  };

  @override
  String toString() =>
      'PollTimings(rpc: $rpcMicros us, parse: $parseMicros us, '
      'dispatch: $dispatchMicros us, tail: $tailMicros us, '
      'events: $eventCount, chars: $responseChars, '
      'duplicates: $duplicatesDropped)';
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

  /// Largest [PollTimings.parseMicros] in the window; null when empty.
  int? get maxParseMicros => _max((t) => t.parseMicros);

  /// Largest [PollTimings.dispatchMicros] in the window; null when empty.
  int? get maxDispatchMicros => _max((t) => t.dispatchMicros);
}
