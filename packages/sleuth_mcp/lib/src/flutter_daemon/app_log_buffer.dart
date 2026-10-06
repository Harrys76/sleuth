import 'dart:collection';

import '../bridge/app_log_stream.dart';

/// Bounded ring buffer of recent app output for the `get_logs` tool.
///
/// Keeps the newest [capacity] lines and cuts each line to [maxLineLength]
/// characters. [droppedCount] counts the lines evicted since the buffer was
/// last cleared, so a reader can tell that older output is gone.
///
/// Lines read on a VM service connection carry its [AppLogEpoch]. Once the
/// bridge ends that epoch, because it disconnected or connected to another
/// app, the buffer drops those lines and refuses late ones, so `get_logs`
/// never mixes one app's output with another's. Flutter daemon lines carry
/// no epoch and stay until [clear].
class AppLogBuffer {
  AppLogBuffer({this.capacity = 500, this.maxLineLength = maxAppLogLineLength})
    : assert(capacity > 0),
      assert(maxLineLength > 0);

  /// Most lines kept at once.
  final int capacity;

  /// Longest line kept, in characters. Longer lines are cut and marked
  /// `truncated`.
  final int maxLineLength;

  final ListQueue<AppLogLine> _lines = ListQueue<AppLogLine>();
  int _dropped = 0;

  /// The epochs of the lines held now, usually one at most.
  final Set<AppLogEpoch> _epochs = Set<AppLogEpoch>.identity();

  /// Lines evicted since the last [clear], oldest first.
  int get droppedCount {
    _dropEndedEpochs();
    return _dropped;
  }

  /// Lines held now.
  int get length {
    _dropEndedEpochs();
    return _lines.length;
  }

  /// Adds [line], cut to [maxLineLength], evicting the oldest line when the
  /// buffer is full. A line whose epoch has ended is dropped.
  void add(AppLogLine line) {
    _dropEndedEpochs();
    final epoch = line.epoch;
    if (epoch != null) {
      if (epoch.ended) return;
      _epochs.add(epoch);
    }
    _lines.addLast(line.capped(maxLineLength));
    while (_lines.length > capacity) {
      _lines.removeFirst();
      _dropped++;
    }
  }

  /// Empties the buffer and resets [droppedCount].
  void clear() {
    _lines.clear();
    _epochs.clear();
    _dropped = 0;
  }

  /// The newest [maxLines] lines whose text contains [filter] (case
  /// insensitive), oldest first, plus how many lines matched in total.
  ({List<AppLogLine> lines, int matched}) query({
    required int maxLines,
    String? filter,
  }) {
    _dropEndedEpochs();
    final needle = filter == null || filter.isEmpty
        ? null
        : filter.toLowerCase();
    final matching = needle == null
        ? _lines.toList()
        : _lines
              .where((line) => line.text.toLowerCase().contains(needle))
              .toList();
    final start = matching.length > maxLines ? matching.length - maxLines : 0;
    return (lines: matching.sublist(start), matched: matching.length);
  }

  /// Removes the lines of every ended epoch. The evictions counted so far
  /// belonged to that output, so [droppedCount] starts again.
  void _dropEndedEpochs() {
    if (!_epochs.any((epoch) => epoch.ended)) return;
    _epochs.removeWhere((epoch) => epoch.ended);
    _lines.removeWhere((line) => line.epoch?.ended ?? false);
    _dropped = 0;
  }
}
