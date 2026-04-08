/// Trend direction for an issue's recurrence over time.
enum TrendDirection {
  /// Issue severity/frequency is increasing.
  worsening,

  /// Issue is consistently present with stable severity.
  stable,

  /// Issue severity/frequency is decreasing.
  improving,

  /// Issue appears and disappears irregularly.
  intermittent,
}

/// A single observation in a recurrence ring buffer.
class RecurrenceEntry {
  const RecurrenceEntry({
    required this.scanCycle,
    required this.present,
    this.severityIndex,
  });

  /// Monotonic scan cycle index when this entry was recorded.
  final int scanCycle;

  /// Whether the issue was present during this scan cycle.
  final bool present;

  /// Severity at observation time (3 = critical, 2 = warning, 1 = ok).
  /// Null when [present] is false.
  final int? severityIndex;

  Map<String, dynamic> toJson() => {
        'scanCycle': scanCycle,
        'present': present,
        if (severityIndex != null) 'severityIndex': severityIndex,
      };

  factory RecurrenceEntry.fromJson(Map<String, dynamic> json) =>
      RecurrenceEntry(
        scanCycle: json['scanCycle'] as int,
        present: json['present'] as bool,
        severityIndex: json['severityIndex'] as int?,
      );
}

/// Ring-buffered time-series tracker for a single issue's recurrence.
///
/// Records whether an issue was present/absent each scan cycle,
/// with the severity when present. Fixed capacity evicts oldest entries.
class RecurrenceTrend {
  RecurrenceTrend({this.capacity = 60});

  /// Maximum entries retained. Oldest evicted when full.
  final int capacity;

  final List<RecurrenceEntry> _entries = [];

  /// Scan cycles since the issue was last observed.
  /// Used for stale eviction — entries unseen for [staleThreshold]
  /// cycles are eligible for removal.
  static const staleThreshold = 120;

  /// All entries in chronological order (oldest first).
  List<RecurrenceEntry> get entries => List.unmodifiable(_entries);

  /// Number of entries currently stored.
  int get length => _entries.length;

  /// Total number of scan cycles where the issue was present.
  int get presentCount => _entries.where((e) => e.present).length;

  /// Total number of scan cycles where the issue was absent.
  int get absentCount => _entries.where((e) => !e.present).length;

  /// Record that the issue was present during [scanCycle].
  void recordPresent(int scanCycle, {required int severityIndex}) {
    _add(RecurrenceEntry(
      scanCycle: scanCycle,
      present: true,
      severityIndex: severityIndex,
    ));
  }

  /// Record that the issue was absent during [scanCycle].
  void recordAbsent(int scanCycle) {
    _add(RecurrenceEntry(
      scanCycle: scanCycle,
      present: false,
    ));
  }

  void _add(RecurrenceEntry entry) {
    if (_entries.length >= capacity) {
      _entries.removeAt(0);
    }
    _entries.add(entry);
  }

  /// Compute the trend direction from the most recent entries.
  ///
  /// Uses the last [window] entries (default 10) to determine direction:
  /// - **worsening**: average severity is increasing over the window
  /// - **improving**: average severity is decreasing over the window
  /// - **intermittent**: issue toggles present/absent ≥ 3 times in window
  /// - **stable**: none of the above
  TrendDirection get trend => computeTrend();

  TrendDirection computeTrend({int window = 10}) {
    if (_entries.length < 3) return TrendDirection.stable;

    final recent = _entries.length <= window
        ? _entries
        : _entries.sublist(_entries.length - window);

    // Count present/absent transitions for intermittent detection
    var transitions = 0;
    for (var i = 1; i < recent.length; i++) {
      if (recent[i].present != recent[i - 1].present) transitions++;
    }
    if (transitions >= 3) return TrendDirection.intermittent;

    // Compare severity in first vs second half of present entries
    final presentEntries = recent.where((e) => e.present).toList();
    if (presentEntries.length < 2) return TrendDirection.stable;

    final midpoint = presentEntries.length ~/ 2;
    final firstHalf = presentEntries.sublist(0, midpoint);
    final secondHalf = presentEntries.sublist(midpoint);

    final firstAvg =
        firstHalf.fold<double>(0, (s, e) => s + (e.severityIndex ?? 0)) /
            firstHalf.length;
    final secondAvg =
        secondHalf.fold<double>(0, (s, e) => s + (e.severityIndex ?? 0)) /
            secondHalf.length;

    final delta = secondAvg - firstAvg;
    if (delta > 0.3) return TrendDirection.worsening;
    if (delta < -0.3) return TrendDirection.improving;
    return TrendDirection.stable;
  }

  /// Whether this trend is stale (no presence recorded in [staleThreshold]
  /// cycles from the most recent entry's scan cycle).
  bool isStale(int currentScanCycle) {
    if (_entries.isEmpty) return true;
    final lastPresent = _entries.lastWhere(
      (e) => e.present,
      orElse: () => _entries.first,
    );
    return (currentScanCycle - lastPresent.scanCycle) > staleThreshold;
  }

  /// Summary for export (not the full ring buffer).
  Map<String, dynamic> toJson() {
    final presentSeverities =
        _entries.where((e) => e.present).map((e) => e.severityIndex ?? 0);
    return {
      'trend': trend.name,
      'totalOccurrences': presentCount,
      'totalObserved': _entries.length,
      'lastSeenCycle': _entries.isNotEmpty ? _entries.last.scanCycle : null,
      if (presentSeverities.isNotEmpty)
        'severityStats': {
          'min': presentSeverities.reduce((a, b) => a < b ? a : b),
          'max': presentSeverities.reduce((a, b) => a > b ? a : b),
        },
    };
  }
}
