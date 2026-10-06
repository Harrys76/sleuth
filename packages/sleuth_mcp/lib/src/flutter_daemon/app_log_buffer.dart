import 'dart:collection';

import '../bridge/app_log_stream.dart';

/// Bounded ring buffer of recent app output for the `get_logs` tool.
///
/// Keeps the newest [capacity] lines and cuts each line to [maxLineLength]
/// characters. [droppedCount] counts the lines evicted since the buffer was
/// last cleared, so a reader can tell that older output is gone.
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

  /// Lines evicted since the last [clear], oldest first.
  int get droppedCount => _dropped;

  /// Lines held now.
  int get length => _lines.length;

  /// Adds [line], cut to [maxLineLength], evicting the oldest line when the
  /// buffer is full.
  void add(AppLogLine line) {
    _lines.addLast(line.capped(maxLineLength));
    while (_lines.length > capacity) {
      _lines.removeFirst();
      _dropped++;
    }
  }

  /// Empties the buffer and resets [droppedCount].
  void clear() {
    _lines.clear();
    _dropped = 0;
  }

  /// The newest [maxLines] lines whose text contains [filter] (case
  /// insensitive), oldest first, plus how many lines matched in total.
  ({List<AppLogLine> lines, int matched}) query({
    required int maxLines,
    String? filter,
  }) {
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
}
