import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Offset;

import '../models/performance_issue.dart';
import 'overlay_filters.dart' as filters;

/// Horizontal screen edge the trigger button rests against.
enum TriggerEdge {
  /// Left edge of the safe area.
  left,

  /// Right edge of the safe area.
  right,
}

/// Window state of the floating issues card.
enum CardWindowState {
  /// User-sized card.
  normal,

  /// Title bar only.
  minimized,

  /// Fills the safe area.
  maximized,
}

/// Overlay UI state that outlives the widgets showing it.
///
/// Owned by the Sleuth controller, so it survives opening and closing the
/// dashboard and hot reload. When `SleuthConfig.stateStore` is set, the
/// persisted fields are loaded at startup and saved after changes (see
/// [toJson]).
///
/// Hiding and the severity filter only change what the overlay shows.
/// Issue aggregation, `ext.sleuth.*` responses, snapshots, budgets, route
/// sessions and recurrence still see every issue.
///
/// Read `Sleuth.overlayUiState` for the live instance. Changing it from
/// app code is supported but rarely needed.
class OverlayUiState extends ChangeNotifier {
  /// Creates a state with default values: dashboard closed, trigger at its
  /// configured position, default card geometry, nothing hidden and every
  /// severity shown.
  OverlayUiState();

  /// Creates a state from [toJson] output.
  ///
  /// Throws [FormatException] when `schemaVersion` is missing, not an
  /// integer, or newer than [schemaVersion]. Other fields are optional;
  /// a missing or malformed field keeps its default and unknown keys are
  /// ignored.
  factory OverlayUiState.fromJson(Map<String, Object?> json) =>
      OverlayUiState()..loadJson(json);

  /// Version written by [toJson] and the newest version [loadJson]
  /// accepts.
  static const int schemaVersion = 1;

  /// Maximum number of hidden keys kept. Hiding beyond it evicts the
  /// oldest key.
  static const int maxHiddenKeys = 200;

  /// The key [hide] and [unhide] take for [issue]: `stableId` (or `title`
  /// when the issue has none), plus `|widgetName` when the issue names a
  /// widget.
  static String hideKeyFor(PerformanceIssue issue) => filters.hideKeyFor(issue);

  bool _dashboardOpen = false;
  ({TriggerEdge edge, double fraction})? _triggerAnchor;
  Offset? _cardOffset;
  double? _cardWidth;
  double? _cardHeight;
  CardWindowState _windowState = CardWindowState.normal;
  Offset? _restoreOffset;
  double? _restoreWidth;
  double? _restoreHeight;
  final LinkedHashSet<String> _hiddenKeys = LinkedHashSet<String>();
  final Set<IssueSeverity> _severityFilter = {...IssueSeverity.values};

  // ── Dashboard ─────────────────────────────────────────────────────────

  /// Whether the dashboard card is open. Session only; not persisted.
  bool get dashboardOpen => _dashboardOpen;
  set dashboardOpen(bool value) {
    if (_dashboardOpen == value) return;
    _dashboardOpen = value;
    notifyListeners();
  }

  // ── Trigger ───────────────────────────────────────────────────────────

  /// Where the trigger rests after the user dragged it: the horizontal
  /// [TriggerEdge] and the vertical position as a fraction (0 = top,
  /// 1 = bottom) of the safe-area height. Null until the first drag; the
  /// trigger then uses `SleuthConfig.triggerButtonAlignment` and
  /// `SleuthConfig.triggerButtonOffset`.
  ///
  /// The fraction is clamped to `[0, 1]`; a non-finite fraction clears
  /// the anchor.
  ({TriggerEdge edge, double fraction})? get triggerAnchor => _triggerAnchor;
  set triggerAnchor(({TriggerEdge edge, double fraction})? value) {
    final next = value == null || !value.fraction.isFinite
        ? null
        : (edge: value.edge, fraction: value.fraction.clamp(0.0, 1.0));
    if (next == _triggerAnchor) return;
    _triggerAnchor = next;
    notifyListeners();
  }

  // ── Card geometry ─────────────────────────────────────────────────────

  /// Top-left of the card in logical pixels, or null for the default
  /// position.
  Offset? get cardOffset => _cardOffset;

  /// Card width, or null for the default width.
  double? get cardWidth => _cardWidth;

  /// Card height, or null for the default height (a share of the screen).
  double? get cardHeight => _cardHeight;

  /// Current window state of the card.
  CardWindowState get windowState => _windowState;

  /// Offset to return to when leaving [CardWindowState.minimized] or
  /// [CardWindowState.maximized].
  Offset? get restoreOffset => _restoreOffset;

  /// Width to return to when leaving a non-normal window state.
  double? get restoreWidth => _restoreWidth;

  /// Height to return to when leaving a non-normal window state.
  double? get restoreHeight => _restoreHeight;

  /// Replaces the card geometry in one change. Non-finite or negative
  /// values are stored as null (default).
  void setCardGeometry({
    required Offset? offset,
    required double? width,
    required double? height,
    required CardWindowState windowState,
    Offset? restoreOffset,
    double? restoreWidth,
    double? restoreHeight,
  }) {
    final o = _validOffset(offset);
    final w = _validExtent(width);
    final h = _validExtent(height);
    final ro = _validOffset(restoreOffset);
    final rw = _validExtent(restoreWidth);
    final rh = _validExtent(restoreHeight);
    if (o == _cardOffset &&
        w == _cardWidth &&
        h == _cardHeight &&
        windowState == _windowState &&
        ro == _restoreOffset &&
        rw == _restoreWidth &&
        rh == _restoreHeight) {
      return;
    }
    _cardOffset = o;
    _cardWidth = w;
    _cardHeight = h;
    _windowState = windowState;
    _restoreOffset = ro;
    _restoreWidth = rw;
    _restoreHeight = rh;
    notifyListeners();
  }

  // ── Hidden issues ─────────────────────────────────────────────────────

  /// Keys of issues hidden from the overlay, oldest first.
  Set<String> get hiddenKeys => UnmodifiableSetView(_hiddenKeys);

  /// Whether [issue]'s card is hidden.
  bool isHidden(PerformanceIssue issue) =>
      _hiddenKeys.contains(hideKeyFor(issue));

  /// Hides the cards whose [hideKeyFor] equals [key]. Re-hiding a key
  /// makes it the newest; past [maxHiddenKeys] the oldest key is evicted.
  void hide(String key) {
    if (_hiddenKeys.isNotEmpty && _hiddenKeys.last == key) return;
    _hiddenKeys
      ..remove(key)
      ..add(key);
    while (_hiddenKeys.length > maxHiddenKeys) {
      _hiddenKeys.remove(_hiddenKeys.first);
    }
    notifyListeners();
  }

  /// Shows [key] again. Returns false when it was not hidden.
  bool unhide(String key) {
    if (!_hiddenKeys.remove(key)) return false;
    notifyListeners();
    return true;
  }

  /// Shows every hidden issue again.
  void restoreAll() {
    if (_hiddenKeys.isEmpty) return;
    _hiddenKeys.clear();
    notifyListeners();
  }

  // ── Severity filter ───────────────────────────────────────────────────

  /// Severities whose cards the overlay shows. Never empty.
  Set<IssueSeverity> get severityFilter => UnmodifiableSetView(_severityFilter);

  /// Whether at least one severity is turned off.
  bool get isSeverityFiltered =>
      _severityFilter.length != IssueSeverity.values.length;

  /// Turns [severity] on or off. Returns false, leaving the filter
  /// unchanged, when that would turn the last severity off.
  bool toggleSeverity(IssueSeverity severity) {
    if (_severityFilter.contains(severity)) {
      if (_severityFilter.length == 1) return false;
      _severityFilter.remove(severity);
    } else {
      _severityFilter.add(severity);
    }
    notifyListeners();
    return true;
  }

  /// Shows every severity again.
  void resetSeverityFilter() {
    if (!isSeverityFiltered) return;
    _severityFilter.addAll(IssueSeverity.values);
    notifyListeners();
  }

  /// The cards the overlay shows for [issues]: filtered by
  /// [severityFilter], collapsed so single-parent effects sit under their
  /// root, then stripped of hidden cards.
  List<PerformanceIssue> visibleIssues(List<PerformanceIssue> issues) =>
      filters.applyOverlayFilters(
        issues,
        severities: _severityFilter,
        hiddenKeys: _hiddenKeys,
      );

  // ── Serialization ─────────────────────────────────────────────────────

  /// Persisted fields: trigger anchor, card geometry and window state,
  /// hidden keys and the severity filter. [dashboardOpen] is session only.
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    if (_triggerAnchor != null)
      'triggerAnchor': {
        'edge': _triggerAnchor!.edge.name,
        'fraction': _triggerAnchor!.fraction,
      },
    if (_cardOffset != null) 'cardOffset': _offsetJson(_cardOffset!),
    if (_cardWidth != null) 'cardWidth': _cardWidth,
    if (_cardHeight != null) 'cardHeight': _cardHeight,
    'windowState': _windowState.name,
    if (_restoreOffset != null) 'restoreOffset': _offsetJson(_restoreOffset!),
    if (_restoreWidth != null) 'restoreWidth': _restoreWidth,
    if (_restoreHeight != null) 'restoreHeight': _restoreHeight,
    'hiddenKeys': _hiddenKeys.toList(),
    'severityFilter': [
      for (final s in IssueSeverity.values)
        if (_severityFilter.contains(s)) s.name,
    ],
  };

  /// Replaces the persisted fields with [json] (from [toJson]) and
  /// notifies once. [dashboardOpen] is left alone.
  ///
  /// Throws [FormatException], leaving the state unchanged, when
  /// `schemaVersion` is missing, not an integer, or newer than
  /// [schemaVersion]. A missing or malformed field takes its default;
  /// unknown keys are ignored; only the newest [maxHiddenKeys] hidden keys
  /// are kept.
  void loadJson(Map<String, Object?> json) {
    final version = json['schemaVersion'];
    if (version is! int) {
      throw const FormatException('schemaVersion missing or not an int');
    }
    if (version > schemaVersion || version < 1) {
      throw FormatException('unsupported schemaVersion $version');
    }

    ({TriggerEdge edge, double fraction})? anchor;
    final rawAnchor = json['triggerAnchor'];
    if (rawAnchor is Map) {
      final edge = _enumByName(TriggerEdge.values, rawAnchor['edge']);
      final fraction = rawAnchor['fraction'];
      if (edge != null && fraction is num && fraction.isFinite) {
        anchor = (edge: edge, fraction: fraction.toDouble().clamp(0.0, 1.0));
      }
    }

    final hidden = <String>[
      if (json['hiddenKeys'] case final List<Object?> keys)
        for (final k in keys)
          if (k is String && k.isNotEmpty) k,
    ];
    final keptHidden = hidden.length > maxHiddenKeys
        ? hidden.sublist(hidden.length - maxHiddenKeys)
        : hidden;

    final severities = <IssueSeverity>{
      if (json['severityFilter'] case final List<Object?> names)
        for (final n in names) ?_enumByName(IssueSeverity.values, n),
    };

    _triggerAnchor = anchor;
    _cardOffset = _validOffset(_offsetFromJson(json['cardOffset']));
    _cardWidth = _validExtent(_doubleFromJson(json['cardWidth']));
    _cardHeight = _validExtent(_doubleFromJson(json['cardHeight']));
    _windowState =
        _enumByName(CardWindowState.values, json['windowState']) ??
        CardWindowState.normal;
    _restoreOffset = _validOffset(_offsetFromJson(json['restoreOffset']));
    _restoreWidth = _validExtent(_doubleFromJson(json['restoreWidth']));
    _restoreHeight = _validExtent(_doubleFromJson(json['restoreHeight']));
    _hiddenKeys
      ..clear()
      ..addAll(keptHidden);
    _severityFilter
      ..clear()
      ..addAll(severities.isEmpty ? IssueSeverity.values : severities);
    notifyListeners();
  }

  static Map<String, double> _offsetJson(Offset o) => {'dx': o.dx, 'dy': o.dy};

  static Offset? _offsetFromJson(Object? raw) {
    if (raw is! Map) return null;
    final dx = raw['dx'];
    final dy = raw['dy'];
    if (dx is! num || dy is! num) return null;
    return Offset(dx.toDouble(), dy.toDouble());
  }

  static double? _doubleFromJson(Object? raw) =>
      raw is num ? raw.toDouble() : null;

  static Offset? _validOffset(Offset? o) =>
      o != null && o.dx.isFinite && o.dy.isFinite ? o : null;

  static double? _validExtent(double? v) =>
      v != null && v.isFinite && v > 0 ? v : null;

  static T? _enumByName<T extends Enum>(List<T> values, Object? raw) {
    if (raw is! String) return null;
    for (final v in values) {
      if (v.name == raw) return v;
    }
    return null;
  }
}
