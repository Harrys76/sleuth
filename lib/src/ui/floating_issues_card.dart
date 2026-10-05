import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../sleuth.dart' show Sleuth;
import '../controller/sleuth_controller.dart';
import '../models/performance_issue.dart';
import '../models/frame_stats.dart';
import '../models/frame_verdict.dart';
import '../models/widget_highlight.dart';
import 'issue_card.dart';
import 'ai_chat_page.dart';
import 'issue_encyclopedia_page.dart';
import 'guide_page.dart';
import 'rebuild_stats_page.dart';
import 'startup_metrics_page.dart';
import '../models/ai_chat_adapter.dart';
import '../utils/ai_session_context.dart';
import '../utils/issue_explanation_builder.dart';
import '../vm/connection_mode.dart';
import 'hidden_issues_page.dart';
import 'motion.dart';
import 'overlay_filters.dart';
import 'overlay_toast.dart';
import 'overlay_ui_state.dart';
import 'sleuth_listenable_builder.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

export 'overlay_filters.dart'
    show applyOverlayFilters, computeVisibleIssues, hideKeyFor, listKeyFor;

/// Composes the frozen-zone list for an expanded render.
///
/// Freeze-above-on-expand contract (v0.15.5):
///
///  * When the user expands a card at visible-index N, the list is
///    captured as `orderSnapshot` and positions `0..N` (inclusive) freeze
///    to what was on screen at expand time. Positions `N+1..end` flow
///    normally through the ranker on every subsequent render.
///  * With multiple expanded cards, `freezeEnd = max(expandedIndices)` —
///    the deepest expansion wins (user-confirmed MAX rule). Expanding a
///    shallower card while a deeper one is already expanded is a no-op
///    on the zone.
///  * Cards whose frozen-zone entry has disappeared from [visibleIssues]
///    (e.g. downstream absorbed the issue, detector evicted it) are
///    dropped silently from the output; `_pruneStaleState` evicts the
///    matching entry on its next sweep.
///  * Items in [visibleIssues] that aren't in the frozen zone are
///    appended in their current ranker-flow order — a new CRITICAL
///    landing mid-read arrives below the frozen zone, never above.
///
/// Identity is [listKeyFor], matching the host's pruning and key-based
/// reorder helpers.
///
/// Pure function over `(visibleIssues, orderSnapshot, expandedIndices)`
/// — no widget state involved — marked [visibleForTesting] so the
/// algorithm can be verified with deterministic unit tests instead of
/// pumping the full overlay tree.
///
/// Contract invariant (asserted in debug): a non-null [orderSnapshot]
/// must be accompanied by a non-empty [expandedIndices] and vice-versa.
/// The host's lifecycle code in [_FloatingIssuesCardState] is the sole
/// enforcer; this assert catches accidental half-state during refactors.
@visibleForTesting
List<PerformanceIssue> applyFreezeZone({
  required List<PerformanceIssue> visibleIssues,
  required List<PerformanceIssue>? orderSnapshot,
  required Map<String, int> expandedIndices,
}) {
  assert(
    (orderSnapshot == null) == expandedIndices.isEmpty,
    'orderSnapshot/expandedIndices must be set together or cleared '
    'together — snapshot=${orderSnapshot?.length}, '
    'expandedIndices=${expandedIndices.length}, '
    'keys=${expandedIndices.keys.toList()}',
  );
  if (expandedIndices.isEmpty || orderSnapshot == null) {
    return visibleIssues;
  }
  // freezeEnd = max(capturedIndex) — MAX rule.
  var freezeEnd = expandedIndices.values.first;
  for (final v in expandedIndices.values) {
    if (v > freezeEnd) freezeEnd = v;
  }
  // Clamp to what's representable: can't freeze past the snapshot's
  // length (frozen zone comes from the snapshot) and can't freeze past
  // the current visible length either (the frozen items need to still
  // be somewhere in the visible set to survive the identity filter).
  final maxSnapshotIdx = orderSnapshot.length - 1;
  final maxVisibleIdx = visibleIssues.length - 1;
  if (freezeEnd > maxSnapshotIdx) freezeEnd = maxSnapshotIdx;
  if (freezeEnd > maxVisibleIdx) freezeEnd = maxVisibleIdx;
  if (freezeEnd < 0) return visibleIssues;

  // Build identity set from the frozen slice.
  final frozenKeys = <String>{
    for (var i = 0; i <= freezeEnd; i++) listKeyFor(orderSnapshot[i]),
  };

  // Index current visible issues by identity so we can re-anchor the
  // snapshot slice to the latest PerformanceIssue instances (the
  // ranker may have updated severity, recurrence, etc. on the same id).
  final visibleById = <String, PerformanceIssue>{
    for (final i in visibleIssues) listKeyFor(i): i,
  };

  final frozen = <PerformanceIssue>[];
  for (var i = 0; i <= freezeEnd; i++) {
    final snap = orderSnapshot[i];
    final key = listKeyFor(snap);
    final live = visibleById[key];
    // Drop silently if the frozen-zone entry has disappeared from the
    // visible set. `_pruneStaleState` will evict the expand-entry on
    // its next sweep.
    if (live != null) frozen.add(live);
  }

  final flow = <PerformanceIssue>[
    for (final i in visibleIssues)
      if (!frozenKeys.contains(listKeyFor(i))) i,
  ];

  return <PerformanceIssue>[...frozen, ...flow];
}

/// Draggable floating card showing FPS, issue count, and ranked issues list.
///
/// Replaces the old DashboardSheet. Uses [Positioned] within an internal
/// [Stack] for drag positioning. Wrapped in a [RepaintBoundary] by the
/// parent overlay to isolate repaints from the app.
class FloatingIssuesCard extends StatefulWidget {
  const FloatingIssuesCard({
    super.key,
    required this.controller,
    required this.onClose,
    this.onLayersChanged,
    this.isDebugMode = kDebugMode,
  });

  final SleuthController controller;
  final VoidCallback onClose;

  /// Called after a full-screen page or the Hidden list opens or closes,
  /// so the host can re-request system back handling.
  final VoidCallback? onLayersChanged;

  /// Whether we are in debug mode. Defaults to [kDebugMode].
  /// Exposed as a param so tests can override it.
  @visibleForTesting
  final bool isDebugMode;

  @override
  State<FloatingIssuesCard> createState() => _FloatingIssuesCardState();
}

/// Implemented by the card's State. [SleuthOverlay] calls
/// [closeInnermostLayer] on system back before closing the dashboard.
abstract interface class OverlayLayerHost {
  /// Closes the innermost open layer: unfocuses a focused text field,
  /// else closes the open full-screen page, else the Hidden list. Returns
  /// false when none of these is open.
  bool closeInnermostLayer();

  /// Number of full-screen layers (pages and the Hidden list) open above
  /// the card. Read from [FloatingIssuesCard.onLayersChanged].
  int get openLayerDepth;
}

class _FloatingIssuesCardState extends State<FloatingIssuesCard>
    implements OverlayLayerHost {
  OverlayUiState get _ui => widget.controller.overlayUiState;

  /// Drag offset — applied via inner [Positioned], null until first build.
  /// Seeded from [OverlayUiState.cardOffset]; written back on drag end.
  Offset? _cardOffset;

  /// Expansion registry: `issueKey -> capturedIndex`.
  ///
  /// When a card expands, its [listKeyFor] is mapped to the index it held in
  /// the visible list at expand-time (captured from the `itemBuilder`
  /// closure scope — see `_buildIssuesList`). The host uses the MAX
  /// captured index across this map to compute the freeze boundary.
  ///
  /// Multiple cards can be expanded simultaneously — one entry per
  /// expand. Entries are removed on collapse (see the `onExpandedChanged`
  /// callback in `_buildIssuesList`) and pruned in [_pruneStaleState]
  /// when their referenced issue disappears from the visible list.
  ///
  /// Paired with [_orderSnapshot]: both fields are populated together on
  /// the 0→1 expand transition and cleared together on the 1→0 collapse
  /// transition. Never mutate one without updating the other or the
  /// class invariant breaks (asserted in [applyFreezeZone]).
  ///
  /// v0.15.5 replaces the v0.14.x single `_expandedIssueId` field with
  /// this map. That field only tracked "which card is expanded" for
  /// `initiallyExpanded`; it didn't freeze position, so ranker reorders
  /// visibly shuffled whichever card the user was reading.
  final Map<String, int> _expandedIndices = <String, int>{};

  /// Snapshot of the visible list captured at the instant the user first
  /// expanded any card (i.e. when [_expandedIndices] went 0→1).
  ///
  /// The snapshot is the source of truth for the frozen zone — positions
  /// `0..max(_expandedIndices.values)` (inclusive) are drawn from this
  /// list, not from the live ranker output. On collapse-to-empty, the
  /// snapshot is released (set back to null) so the next expand captures
  /// a fresh one from whatever the ranker currently shows.
  ///
  /// Source-of-truth rule: the snapshot is a **defensive copy** of the
  /// `visibleIssues` closure-captured inside `_buildIssuesList`'s build
  /// pass, NOT a read of `widget.controller.issuesNotifier.value`. The
  /// notifier may have ticked between the frame the user saw and the
  /// moment their tap arrived; using the live value could anchor the
  /// freeze to rows the user never saw.
  List<PerformanceIssue>? _orderSnapshot;

  /// [listKeyFor] of the issue whose highlight checkbox is checked.
  String? _selectedIssueId;

  /// Bumped when the host clears every expansion at once (severity filter
  /// change); [IssueCard] collapses without calling back.
  int _collapseEpoch = 0;

  /// Severity filter seen by the last [_onUiStateChanged].
  Set<IssueSeverity> _lastSeverityFilter = const {};

  final OverlayToastController _toast = OverlayToastController();

  /// Open-layer count reported through [FloatingIssuesCard.onLayersChanged].
  int _reportedLayerDepth = 0;

  bool _debugBannerDismissed = false;
  bool _showHidden = false;
  bool _showGuide = false;
  bool _showDetail = false;
  bool _showStartupDetail = false;
  bool _showRebuildStats = false;
  // Snapshot captured at tap time so mutations to the live session
  // (from background scans) don't shuffle rows while the drilldown is open.
  // Spec v15 M10: drilldown is snapshot-at-open, not live.
  Map<String, int>? _rebuildStatsSnapshot;
  String? _rebuildStatsRouteName;
  String? _detailStableId;
  PerformanceIssue? _detailContextIssue;
  bool _showAiChat = false;
  String? _chatIssueStableId;
  final Map<String, List<AiChatMessage>> _chatHistories = {};

  /// Cached jank-correlated issue keys from verdict, updated via listener.
  Set<String> _cachedJankKeys = const {};

  double _cardWidth = _defaultCardWidth;
  static const double _defaultCardWidth = 300;
  static const double _minCardWidth = 220;
  static const double _minCardHeight = 300;

  /// Height of the minimized card: the 48 px header row.
  static const double _minimizedHeight = 48;

  /// Height of a header or footer control row.
  static const double _controlRowHeight = 48;

  /// Height of the card header.
  static const double _headerHeight = _controlRowHeight;

  /// Height of the card footer: a control row and its top border.
  static const double _footerHeight = _controlRowHeight + 1;

  // ─── Window state (M2) ─────────────────────────────────────────────
  CardWindowState _windowState = CardWindowState.normal;

  /// Stored when transitioning away from normal so restore is exact.
  /// Drag while minimized does NOT update these — restore always returns
  /// to the position the card was in when minimize/maximize was tapped.
  Offset? _preTransitionOffset;
  double? _preTransitionWidth;
  double? _preTransitionHeight;

  /// User-set card height. Null = default (55% of screen).
  double? _cardHeight;

  // Cached for gesture handlers (set each build).
  EdgeInsets _cachedSafePadding = EdgeInsets.zero;
  double _cachedEffectiveWidth = 0;
  double _cachedKeyboardHeight = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.verdictNotifier.addListener(_onVerdictChanged);
    widget.controller.issuesNotifier.addListener(_onIssuesChanged);
    _ui.addListener(_onUiStateChanged);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    _readGeometry();
    _lastSeverityFilter = {..._ui.severityFilter};
    _onVerdictChanged();
  }

  /// Seeds the local geometry from [OverlayUiState].
  void _readGeometry() {
    final ui = _ui;
    _cardOffset = ui.cardOffset;
    _cardWidth = ui.cardWidth ?? _defaultCardWidth;
    _cardHeight = ui.cardHeight;
    _windowState = ui.windowState;
    _preTransitionOffset = ui.restoreOffset;
    _preTransitionWidth = ui.restoreWidth;
    _preTransitionHeight = ui.restoreHeight;
  }

  /// Writes the local geometry to [OverlayUiState]: once per drag end,
  /// resize end, or window-state change.
  void _commitGeometry() {
    _ui.setCardGeometry(
      offset: _cardOffset,
      width: _cardWidth,
      height: _cardHeight,
      windowState: _windowState,
      restoreOffset: _preTransitionOffset,
      restoreWidth: _preTransitionWidth,
      restoreHeight: _preTransitionHeight,
    );
  }

  /// Hidden keys or the severity filter changed. A filter change clears
  /// every expansion together with the freeze snapshot; then stale state
  /// is pruned against the new visible list.
  void _onUiStateChanged() {
    if (!mounted) return;
    final filter = _ui.severityFilter;
    if (!setEquals(filter, _lastSeverityFilter)) {
      _lastSeverityFilter = {...filter};
      if (_expandedIndices.isNotEmpty || _orderSnapshot != null) {
        _expandedIndices.clear();
        _orderSnapshot = null;
        _collapseEpoch++;
      }
    }
    _pruneStaleState();
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant FloatingIssuesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Defensive: if the host swaps the controller (not expected in
    // production — `SleuthOverlay` builds the card once with a stable
    // controller — but cheap insurance for test harnesses that rebuild
    // the overlay with a fresh controller on the same widget instance).
    // Without this, `_expandedIndices`/`_orderSnapshot` and listeners
    // would reference the old controller's issue ids and notifiers.
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.verdictNotifier.removeListener(_onVerdictChanged);
      oldWidget.controller.issuesNotifier.removeListener(_onIssuesChanged);
      oldWidget.controller.overlayUiState.removeListener(_onUiStateChanged);
      widget.controller.verdictNotifier.addListener(_onVerdictChanged);
      widget.controller.issuesNotifier.addListener(_onIssuesChanged);
      widget.controller.overlayUiState.addListener(_onUiStateChanged);
      _readGeometry();
      _lastSeverityFilter = {..._ui.severityFilter};
      _expandedIndices.clear();
      _orderSnapshot = null;
      _selectedIssueId = null;
      _chatIssueStableId = null;
      _chatHistories.clear();
      _cachedJankKeys = const {};
      _onVerdictChanged();
    }
  }

  /// Escape closes the innermost layer, then the card. Runs before focus
  /// dispatch, so no focus is taken from the app. The key event still
  /// reaches the focused widget afterwards, so Escape is left to the app
  /// when its focus is in a text field or in a dismissible route (a
  /// dialog or sheet closes on Escape through `DismissIntent`).
  bool _onKeyEvent(KeyEvent event) {
    if (!mounted ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    final focusContext = FocusManager.instance.primaryFocus?.context;
    if (focusContext != null &&
        focusContext.mounted &&
        focusContext.findAncestorStateOfType<_FloatingIssuesCardState>() !=
            this &&
        (focusContext.findAncestorWidgetOfExactType<EditableText>() != null ||
            (ModalRoute.of(focusContext)?.barrierDismissible ?? false))) {
      return false;
    }
    if (!closeInnermostLayer()) widget.onClose();
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    widget.controller.verdictNotifier.removeListener(_onVerdictChanged);
    widget.controller.issuesNotifier.removeListener(_onIssuesChanged);
    widget.controller.overlayUiState.removeListener(_onUiStateChanged);
    _toast.dispose();
    _preTransitionOffset = null;
    _preTransitionWidth = null;
    _preTransitionHeight = null;
    _expandedIndices.clear();
    _orderSnapshot = null;
    super.dispose();
  }

  // ─── Window controls (M2) ──────────────────────────────────────────

  void _minimize() {
    if (_windowState == CardWindowState.minimized) return;
    setState(() {
      _preTransitionOffset ??= _cardOffset;
      _preTransitionWidth ??= _cardWidth;
      _preTransitionHeight ??= _cardHeight;
      _windowState = CardWindowState.minimized;
      _cardHeight = _minimizedHeight;
    });
    _commitGeometry();
  }

  void _maximize(BuildContext context) {
    if (_windowState == CardWindowState.maximized) return;
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.viewPaddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    setState(() {
      _preTransitionOffset ??= _cardOffset;
      _preTransitionWidth ??= _cardWidth;
      _preTransitionHeight ??= _cardHeight;
      _windowState = CardWindowState.maximized;
      _cardOffset = Offset(safe.left + 16, safe.top + 16);
      _cardWidth = math.max(0.0, size.width - safe.horizontal - 32);
      _cardHeight = _maximizedHeight(size, safe, keyboard);
    });
    _commitGeometry();
  }

  /// Height of the maximized card: the safe area minus margins, above the
  /// keyboard.
  static double _maximizedHeight(Size size, EdgeInsets safe, double keyboard) =>
      math.max(
        0.0,
        size.height - safe.top - 32 - math.max(safe.bottom, keyboard),
      );

  void _restore() {
    setState(() {
      if (_preTransitionOffset != null) _cardOffset = _preTransitionOffset;
      if (_preTransitionWidth != null) _cardWidth = _preTransitionWidth!;
      _cardHeight = _preTransitionHeight; // nullable — default height
      _preTransitionOffset = null;
      _preTransitionWidth = null;
      _preTransitionHeight = null;
      _windowState = CardWindowState.normal;
    });
    _commitGeometry();
  }

  // ─── Layers and back handling ──────────────────────────────────────

  /// Number of layers open above the card: one per open full-screen
  /// page plus the Hidden list.
  @override
  int get openLayerDepth => [
    _showAiChat,
    _showDetail,
    _showRebuildStats,
    _showStartupDetail,
    _showGuide,
    _showHidden,
  ].where((open) => open).length;

  @override
  bool closeInnermostLayer() {
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    if (focus != null &&
        focusContext != null &&
        focusContext.mounted &&
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null &&
        focusContext.findAncestorStateOfType<_FloatingIssuesCardState>() ==
            this) {
      focus.unfocus();
      return true;
    }
    if (_showAiChat) {
      _closeAiChat();
    } else if (_showDetail) {
      _closeDetail();
    } else if (_showRebuildStats) {
      _closeRebuildStats();
    } else if (_showStartupDetail) {
      setState(() => _showStartupDetail = false);
    } else if (_showGuide) {
      setState(() => _showGuide = false);
    } else if (_showHidden) {
      setState(() => _showHidden = false);
    } else {
      return false;
    }
    return true;
  }

  void _closeAiChat() => setState(() {
    _showAiChat = false;
    _chatIssueStableId = null;
  });

  void _closeDetail() => setState(() {
    _showDetail = false;
    _detailStableId = null;
    _detailContextIssue = null;
  });

  void _closeRebuildStats() => setState(() {
    _showRebuildStats = false;
    _rebuildStatsSnapshot = null;
    _rebuildStatsRouteName = null;
  });

  // ─── Hide and copy ─────────────────────────────────────────────────

  /// Hides [issue]'s card from the overlay and offers Undo. The card has
  /// already collapsed through `onExpandedChanged(false)`.
  void _hideIssue(PerformanceIssue issue) {
    final key = hideKeyFor(issue);
    if (_selectedIssueId == listKeyFor(issue)) {
      _selectedIssueId = null;
      widget.controller.clearSelectedHighlight();
    }
    _ui.hide(key);
    _toast.show(
      'Issue hidden',
      actionLabel: 'Undo',
      onAction: () => _ui.unhide(key),
    );
  }

  Future<void> _copyIssue(PerformanceIssue issue) async {
    try {
      await Clipboard.setData(ClipboardData(text: issue.toClipboardText()));
    } catch (e) {
      debugPrint('Sleuth: copy failed: $e');
      if (mounted) {
        _toast.show("Couldn't copy", tone: OverlayToastTone.warning);
      }
      return;
    }
    unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
    if (mounted) _toast.show('Copied');
  }

  static String _themeModeLabel(SleuthThemeMode mode) => switch (mode) {
    SleuthThemeMode.system => 'System',
    SleuthThemeMode.light => 'Light',
    SleuthThemeMode.dark => 'Dark',
  };

  /// Header theme toggle: System -> Light -> Dark -> System. Light and
  /// Dark take precedence over a `Sleuth.updateTheme` override, which
  /// shows again on System.
  void _cycleThemeMode() {
    final next = switch (_ui.themeMode) {
      SleuthThemeMode.system => SleuthThemeMode.light,
      SleuthThemeMode.light => SleuthThemeMode.dark,
      SleuthThemeMode.dark => SleuthThemeMode.system,
    };
    _ui.themeMode = next;
    _toast.show('Theme: ${_themeModeLabel(next)}');
  }

  void _toggleSeverity(IssueSeverity severity) {
    if (!_ui.toggleSeverity(severity)) {
      _toast.show('Keep at least one severity', tone: OverlayToastTone.warning);
    }
  }

  PerformanceIssue _findIssueByStableId(String key) {
    return widget.controller.issuesNotifier.value.firstWhere(
      (i) => (i.stableId ?? i.title) == key,
      orElse: () => PerformanceIssue(
        title: key,
        detail: '',
        fixHint: '',
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        stableId: key,
      ),
    );
  }

  void _onVerdictChanged() {
    final newKeys = _matchingIssueKeys(widget.controller.verdictNotifier.value);
    if (!setEquals(newKeys, _cachedJankKeys)) {
      setState(() => _cachedJankKeys = newKeys);
    }
  }

  /// Combined listener for issuesNotifier — prunes stale state then updates
  /// jank keys in a single callback dispatch.
  ///
  /// **Invariant (load-bearing for freeze correctness):** `ValueNotifier`
  /// listeners fire synchronously before any `ValueListenableBuilder`
  /// rebuilds. That means by the time `_buildIssuesList` reads
  /// `_expandedIndices` on the new list, `_pruneStaleState` has already
  /// evicted stale ids from the map — no "zombie expand entry" can apply
  /// `initiallyExpanded: true` to a coincidentally-matching new-route
  /// issue. Do not move pruning to a post-frame callback or microtask:
  /// that would break this invariant and re-introduce the bug.
  void _onIssuesChanged() {
    _pruneStaleState();
    _onVerdictChanged();
  }

  /// Clears pin/selection/chat state when referenced issues are no longer
  /// present.
  ///
  /// v0.15.5 (C1 fix): pin pruning is keyed against the VISIBLE list —
  /// not the raw `issuesNotifier.value` — because a pinned root's
  /// downstream children may churn without the root itself disappearing.
  /// Using raw keys leaked "zombie pins" for cards that stopped rendering
  /// when their root got collapsed into an expanded parent.
  ///
  /// The visible list is [applyOverlayFilters] — the same list
  /// [_buildIssuesList] renders — so a hidden or filtered-out card drops
  /// its expansion entry here.
  ///
  /// `_chatIssueStableId` and `_chatHistories` intentionally stay on the
  /// raw-key check — those surfaces operate on ALL issues (including
  /// downstream ones reachable via Ask AI), and narrowing them here would
  /// hide entries the user can still reach through the expanded parent's
  /// downstream list. `_selectedIssueId` is dropped, together with the
  /// controller's highlight selection, when its issue disappears or is
  /// hidden.
  void _pruneStaleState() {
    final issues = widget.controller.issuesNotifier.value;
    final visible = _ui.visibleIssues(issues);
    final visibleKeys = <String>{for (final i in visible) listKeyFor(i)};
    final rawKeys = <String>{for (final i in issues) i.stableId ?? i.title};
    var changed = false;

    final expandedBefore = _expandedIndices.length;
    _expandedIndices.removeWhere((id, _) => !visibleKeys.contains(id));
    if (_expandedIndices.length != expandedBefore) changed = true;

    // Drop cards that left the visible list from the order snapshot, so
    // one that comes back (Undo, restore, a detector re-emitting) lands
    // below the frozen zone instead of pushing the expanded card down.
    final snapshot = _orderSnapshot;
    if (snapshot != null && _expandedIndices.isNotEmpty) {
      final kept = [
        for (final i in snapshot)
          if (visibleKeys.contains(listKeyFor(i))) i,
      ];
      if (kept.length != snapshot.length) {
        _repointExpansions(kept);
        _orderSnapshot = kept;
        changed = true;
      }
    }

    // Release the order snapshot when the freeze zone has emptied out —
    // otherwise the snapshot lingers and a subsequent render would still
    // anchor to a zero-width freeze zone (harmless but the invariant
    // asserted in `applyFreezeZone` would fire). Covers the
    // all-absorbed-into-downstream case.
    if (_expandedIndices.isEmpty && _orderSnapshot != null) {
      _orderSnapshot = null;
      changed = true;
    }

    final selected = _selectedIssueId;
    if (selected != null &&
        (_ui.hiddenKeys.contains(selected) ||
            !issues.any((i) => listKeyFor(i) == selected))) {
      _selectedIssueId = null;
      widget.controller.clearSelectedHighlight();
      changed = true;
    }
    if (_showAiChat &&
        _chatIssueStableId != null &&
        !rawKeys.contains(_chatIssueStableId)) {
      _chatIssueStableId = null;
      _showAiChat = false;
      changed = true;
    }
    _chatHistories.removeWhere((key, _) => !rawKeys.contains(key));
    if (changed) setState(() {});
  }

  Listenable? _hiddenSources;
  SleuthController? _hiddenSourcesController;

  /// Issues plus suppressed count of the current controller, merged once.
  Listenable _hiddenPageSources() {
    final c = widget.controller;
    if (_hiddenSources == null || !identical(c, _hiddenSourcesController)) {
      _hiddenSources = Listenable.merge([
        c.issuesNotifier,
        c.suppressedCountNotifier,
      ]);
      _hiddenSourcesController = c;
    }
    return _hiddenSources!;
  }

  /// Points every expansion at its card's position in [snapshot], the
  /// list about to become [_orderSnapshot]; expansions whose card is not
  /// in it are dropped. The caller sets [_orderSnapshot] (or clears it
  /// when no expansion is left).
  void _repointExpansions(List<PerformanceIssue> snapshot) {
    final positions = <String, int>{};
    for (var i = 0; i < snapshot.length; i++) {
      positions.putIfAbsent(listKeyFor(snapshot[i]), () => i);
    }
    _expandedIndices
      ..removeWhere((key, _) => !positions.containsKey(key))
      ..updateAll((key, _) => positions[key]!);
  }

  /// Stable keys from verdict.relatedIssues that match current issuesNotifier.
  Set<String> _matchingIssueKeys(FrameVerdict? verdict) {
    if (verdict == null || verdict.relatedIssues.isEmpty) return const {};
    final verdictKeys = <String>{
      for (final ri in verdict.relatedIssues) ri.stableId ?? ri.title,
    };
    final currentKeys = <String>{
      for (final issue in widget.controller.issuesNotifier.value)
        issue.stableId ?? issue.title,
    };
    return verdictKeys.intersection(currentKeys);
  }

  Future<void> _exportToClipboard() async {
    final json = widget.controller.exportSnapshotJson();
    try {
      await Clipboard.setData(ClipboardData(text: json));
    } catch (e) {
      debugPrint('Sleuth: snapshot copy failed: $e');
      if (mounted) {
        _toast.show("Couldn't copy snapshot", tone: OverlayToastTone.warning);
      }
      return;
    }
    if (!mounted) return;
    _toast.show('Snapshot copied to clipboard');
  }

  void _onHighlightChanged(
    bool checked,
    String issueKey,
    PerformanceIssue issue,
  ) {
    if (checked) {
      setState(() => _selectedIssueId = issueKey);
      widget.controller.highlightEnabledNotifier.value = true;
      final found = widget.controller.selectHighlightForIssue(issue);
      if (!found) {
        widget.controller.pendingIssueSelection = issue;
        _toast.show(
          'Widget not currently visible. Navigate to the screen where this '
          'issue occurs.',
          tone: OverlayToastTone.warning,
          duration: const Duration(seconds: 3),
        );
      }
    } else {
      setState(() => _selectedIssueId = null);
      widget.controller.clearSelectedHighlight();
    }
  }

  /// Whether an issue can be visually located on screen.
  static bool _isLocatableIssue(PerformanceIssue issue) {
    return switch (issue.category) {
      IssueCategory.layout => true,
      IssueCategory.build => issue.widgetName != null,
      IssueCategory.paint => true,
      IssueCategory.memory => issue.widgetName != null,
      IssueCategory.raster => false,
      IssueCategory.channel => false,
      IssueCategory.font => false,
      IssueCategory.network => false,
      IssueCategory.startup => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final safe = MediaQuery.viewPaddingOf(context);
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    // Chrome grows with the text inside it (up to 1.3x); the minimum
    // height grows with it but never past the screen's usable height
    // (a landscape phone). The stored height is left alone, so the card
    // returns to it at 1.0x.
    final chromeScale = chromeScaleOf(context);
    final available = screenSize.height - safe.top - math.max(safe.bottom, 20);
    final minHeight = math.min(
      _minCardHeight * chromeScale,
      math.max(_minCardHeight, available),
    );
    final maxAllowedHeight = math.max(minHeight, available);
    final isMinimized = _windowState == CardWindowState.minimized;

    final double cardHeight;
    if (_windowState == CardWindowState.maximized) {
      // Tracks the keyboard so the card shrinks above it, down to the
      // header, the summary bar and the footer.
      _cardHeight = _maximizedHeight(screenSize, safe, keyboardHeight);
      cardHeight = math.max(
        _cardHeight!,
        _headerHeight +
            _footerHeight +
            _IssuesSummaryBar.hitHeightFor(chromeScale),
      );
    } else {
      cardHeight = (_cardHeight ?? screenSize.height * 0.55).clamp(
        isMinimized ? _minimizedHeight * chromeScale : minHeight,
        maxAllowedHeight,
      );
    }
    final effectiveWidth = _cardWidth
        .clamp(_minCardWidth, math.max(_minCardWidth, screenSize.width))
        .toDouble();
    _cachedSafePadding = safe;
    _cachedEffectiveWidth = effectiveWidth;
    _cachedKeyboardHeight = keyboardHeight;
    final theme = SleuthTheme.of(context);
    // Toasts stay three times longer while a screen reader is on.
    _toast.durationScale =
        (MediaQuery.maybeAccessibleNavigationOf(context) ?? false) ? 3 : 1;

    _cardOffset ??= Offset(
      screenSize.width - safe.right - effectiveWidth - 5,
      screenSize.height * 0.30,
    );

    final clamped = _clampOffset(
      screenSize,
      safe,
      effectiveWidth,
      keyboardHeight,
    );

    final layerDepth = openLayerDepth;
    if (layerDepth != _reportedLayerDepth) {
      _reportedLayerDepth = layerDepth;
      widget.onLayersChanged?.call();
    }

    return Stack(
      children: [
        if (layerDepth == 0)
          Positioned(
            left: clamped.dx,
            top: clamped.dy,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _buildCardBody(
                  effectiveWidth,
                  cardHeight,
                  theme,
                  screenSize,
                  chromeScale,
                  clamped,
                ),
                if (!isMinimized)
                  _buildResizeHandle(
                    screenSize,
                    clamped,
                    cardHeight,
                    maxAllowedHeight,
                    theme,
                  ),
              ],
            ),
          ),
        if (_showHidden)
          // Issues and the suppressed count are read live; hidden keys
          // rebuild the card through `_onUiStateChanged`.
          _page(
            SleuthListenableBuilder(
              listenable: _hiddenPageSources(),
              builder: (context) => HiddenIssuesPage(
                hiddenKeys: _ui.hiddenKeys.toList(),
                issues: widget.controller.issuesNotifier.value,
                configSuppressions: widget.controller.config.suppressedIssues,
                suppressedCount:
                    widget.controller.suppressedCountNotifier.value,
                onRestore: _ui.unhide,
                onRestoreAll: _ui.restoreAll,
                onClose: () => setState(() => _showHidden = false),
              ),
            ),
          ),
        if (_showGuide)
          _page(GuidePage(onClose: () => setState(() => _showGuide = false))),
        if (_showDetail)
          _page(
            IssueEncyclopediaPage(
              onClose: _closeDetail,
              scrollToStableId: _detailStableId,
              contextIssue: _detailContextIssue,
            ),
          ),
        if (_showAiChat) _page(_buildAiChatPage(_chatIssueStableId!)),
        if (_showStartupDetail)
          _page(
            StartupMetricsPage(
              onClose: () => setState(() => _showStartupDetail = false),
            ),
          ),
        if (_showRebuildStats && _rebuildStatsSnapshot != null)
          _page(
            RebuildStatsPage(
              routeDisplayName: _rebuildStatsRouteName,
              countsByType: _rebuildStatsSnapshot!,
              onClose: _closeRebuildStats,
            ),
          ),
        // Single toast slot for every confirmation and notice; above the
        // card and any full-screen page.
        OverlayToast(controller: _toast),
      ],
    );
  }

  /// The chat about the issue keyed [chatKey]. The history callback
  /// holds [chatKey]: the page commits a stopped reply from `dispose`,
  /// after close or prune has cleared [_chatIssueStableId]. A write for
  /// an issue that is no longer reported is dropped, as
  /// [_pruneStaleState] would drop it.
  Widget _buildAiChatPage(String chatKey) {
    return AiChatPage(
      issue: _findIssueByStableId(chatKey),
      allIssues: widget.controller.issuesNotifier.value,
      adapter: widget.controller.config.aiChat!,
      history: _chatHistories[chatKey] ?? const [],
      onHistoryChanged: (msgs) {
        final reported = widget.controller.issuesNotifier.value.any(
          (i) => (i.stableId ?? i.title) == chatKey,
        );
        if (reported) _chatHistories[chatKey] = msgs;
      },
      onClose: _closeAiChat,
      onNotify: (message) => _toast.show(message),
      sessionContext: _sessionContext,
    );
  }

  /// The app's state for the AI prompt: counts and rates only, the
  /// hidden issues as a count.
  AiSessionContext _sessionContext() {
    final c = widget.controller;
    var critical = 0, warning = 0, ok = 0;
    for (final issue in c.issuesNotifier.value) {
      switch (issue.severity) {
        case IssueSeverity.critical:
          critical++;
        case IssueSeverity.warning:
          warning++;
        case IssueSeverity.ok:
          ok++;
      }
    }
    final frames = c.frameStatsNotifier.value;
    final verdict = c.verdictNotifier.value;
    return AiSessionContext(
      route: c.activeRouteSession?.routeName,
      actualFps: frames.isEmpty ? null : frames.actualFps,
      throughputFps: frames.isEmpty ? null : frames.throughputFps,
      fpsTarget: c.config.fpsTarget,
      verdictPhase: verdict?.suspectedPhase,
      verdictReason: verdict?.reason,
      verdictMode: verdict == null
          ? null
          : verdict.isCorrelated
          ? 'correlated'
          : verdict.isFullMode
          ? 'full'
          : 'basic',
      criticalCount: critical,
      warningCount: warning,
      okCount: ok,
      hiddenCount: _ui.hiddenKeys.length,
      isDebugMode: c.isDebugMode,
      connectionMode: computeConnectionMode(c),
      platform: defaultTargetPlatform.name,
    );
  }

  /// A full-screen page over the card. While one is open, [SleuthOverlay]
  /// drops the app's semantics below the overlay (see
  /// [OverlayLayerHost.openLayerDepth]), so a screen reader stays on the
  /// page; the floating card alone leaves the app reachable.
  static Widget _page(Widget page) => Positioned.fill(child: page);

  /// Triggered by [_RebuildStatsBanner] when its frozen snapshot is
  /// discarded by an automatic resume on route change. Shows a toast so
  /// the user knows their pause was cleared and isn't surprised by
  /// suddenly-live counts.
  void _onRebuildPauseDiscarded() {
    if (!mounted) return;
    _toast.show(
      'Pause cleared — route changed',
      tone: OverlayToastTone.warning,
    );
  }

  /// Called when the user taps `See all M →` in the expanded
  /// [_RebuildStatsBanner] panel. When the panel is paused, [overrideCounts]
  /// carries the panel's frozen snapshot and the drilldown opens against
  /// THAT map (panel and drilldown agree on what the user is reading).
  /// Otherwise reads the active [RouteSession] live and snapshots
  /// [RouteSession.rebuildCountsByType] at tap time.
  ///
  /// If the session was cleared between the panel rendering and the tap
  /// (pathological: route change mid-gesture), shows a "Session no longer
  /// active" toast instead of pushing.
  void _onSeeAllRebuildsTap([Map<String, int>? overrideCounts]) {
    final session = widget.controller.activeRouteSession;
    // Choose the source of truth for the drilldown snapshot:
    //   * paused panel → frozen counts (what the user is currently reading)
    //   * live panel   → fresh read of the session map
    // If both are missing/empty, we have nothing to drill into.
    final source = overrideCounts ?? session?.rebuildCountsByType;
    if (source == null || source.isEmpty) {
      _toast.show('Session no longer active', tone: OverlayToastTone.warning);
      return;
    }
    setState(() {
      // Defensive copy — snapshot semantics mean mutations to either the
      // live session or the panel's frozen map must not reorder rows in
      // the open drilldown.
      _rebuildStatsSnapshot = Map<String, int>.of(source);
      _rebuildStatsRouteName = session?.routeName;
      _showRebuildStats = true;
    });
  }

  // ─── Build helpers ──────────────────────────────────────────────────

  /// Keeps the card's top-left inside the safe area: within the
  /// horizontal view padding, below the top inset, and with at least
  /// 100 px of title bar above the keyboard or bottom inset.
  Offset _clampOffset(
    Size screenSize,
    EdgeInsets safe,
    double effectiveWidth, [
    double keyboardHeight = 0,
  ]) {
    final minX = safe.left;
    final maxX = math.max(
      minX,
      screenSize.width - safe.right - effectiveWidth - 5,
    );
    final minY = safe.top;
    final maxY = math.max(
      minY,
      screenSize.height - math.max(safe.bottom, keyboardHeight) - 100,
    );
    return Offset(
      _cardOffset!.dx.clamp(minX, maxX),
      _cardOffset!.dy.clamp(minY, maxY),
    );
  }

  Widget _buildCardBody(
    double effectiveWidth,
    double cardHeight,
    SleuthThemeData theme,
    Size screenSize,
    double chromeScale,
    Offset position,
  ) {
    final isMinimized = _windowState == CardWindowState.minimized;
    // The status row and banners scroll once they would take more than
    // half of the space between header and footer and leave the list less
    // than the summary bar plus about two collapsed cards (large text, a
    // short card, an open FPS explainer).
    final middle = math.max(0.0, cardHeight - _headerHeight - _footerHeight);
    final minList = _IssuesSummaryBar.hitHeightFor(chromeScale) + 96;
    final bannersMaxHeight = math.max(middle * 0.5, middle - minList);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: effectiveWidth,
        maxHeight: cardHeight,
      ),
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(theme.radiusCard),
        color: theme.cardBackground,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(
              screenSize,
              effectiveWidth,
              cardHeight,
              position,
              theme,
            ),
            if (!isMinimized) ...[
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: bannersMaxHeight),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _StatusRow(controller: widget.controller),
                      Divider(color: theme.border, height: 1),
                      _WarningBanners(
                        isDeepInstrumentationActive:
                            widget.controller.isDeepInstrumentationActive,
                      ),
                      if (widget.isDebugMode &&
                          widget.controller.config.showDebugModeBanner &&
                          !_debugBannerDismissed)
                        _DebugModeBanner(
                          onDismiss: () =>
                              setState(() => _debugBannerDismissed = true),
                        ),
                      if (Sleuth.startupMetrics != null)
                        _StartupMetricsBanner(
                          onTap: () =>
                              setState(() => _showStartupDetail = true),
                        ),
                      // Always-on inline rebuild-stats panel; see
                      // [_RebuildStatsBanner].
                      _RebuildStatsBanner(
                        controller: widget.controller,
                        onTap: _onSeeAllRebuildsTap,
                        onPauseDiscarded: _onRebuildPauseDiscarded,
                      ),
                    ],
                  ),
                ),
              ),
              Flexible(
                child: RepaintBoundary(child: _buildIssuesList(chromeScale)),
              ),
              _CardFooter(
                controller: widget.controller,
                hiddenCount: _ui.hiddenKeys.length,
                onShowHidden: () => setState(() => _showHidden = true),
                onExport: _exportToClipboard,
                onEncyclopedia: () => setState(() {
                  _detailStableId = null;
                  _showDetail = true;
                }),
                onGuide: () => setState(() => _showGuide = true),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResizeHandle(
    Size screenSize,
    Offset clamped,
    double cardHeight,
    double maxAllowedHeight,
    SleuthThemeData theme,
  ) {
    // The stored height keeps the unscaled minimum: the scaled floor
    // (large text) is display-only, so the card returns to its own height
    // at 1.0x. Growing starts from the shown height; shrinking from the
    // stored one while the floor holds the shown height up.
    void resizeBy(double dw, double dh) {
      _cardWidth = (_cardWidth + dw).clamp(
        _minCardWidth,
        math.max(_minCardWidth, screenSize.width - clamped.dx),
      );
      final stored = _cardHeight ?? cardHeight;
      final base = dh < 0 ? math.min(stored, cardHeight) : cardHeight;
      _cardHeight = (base + dh).clamp(
        math.min(_minCardHeight, maxAllowedHeight),
        maxAllowedHeight,
      );
    }

    void resizeAndCommit(double dw, double dh) {
      setState(() => resizeBy(dw, dh));
      _commitGeometry();
    }

    // 48 x 48 hit box; the grip dots keep their corner position. Screen
    // readers resize through the custom actions in 48 px steps, offered
    // only in the normal window state (a maximized card's size follows
    // the screen).
    final isNormal = _windowState == CardWindowState.normal;
    return Positioned(
      right: 0,
      bottom: 0,
      width: 48,
      height: 48,
      child: Semantics(
        container: true,
        label: 'Resize card',
        value: _sizeValue(_cachedEffectiveWidth, cardHeight),
        customSemanticsActions: isNormal
            ? {
                const CustomSemanticsAction(label: 'Taller'): () =>
                    resizeAndCommit(0, _a11yStep),
                const CustomSemanticsAction(label: 'Shorter'): () =>
                    resizeAndCommit(0, -_a11yStep),
                const CustomSemanticsAction(label: 'Wider'): () =>
                    resizeAndCommit(_a11yStep, 0),
                const CustomSemanticsAction(label: 'Narrower'): () =>
                    resizeAndCommit(-_a11yStep, 0),
              }
            : null,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeDownRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // The custom actions resize; pan scroll actions would not.
            excludeFromSemantics: true,
            onPanUpdate: (details) {
              setState(() => resizeBy(details.delta.dx, details.delta.dy));
            },
            onPanEnd: (_) => _commitGeometry(),
            child: CustomPaint(
              painter: _CornerGripPainter(gripColor: theme.gripDots),
            ),
          ),
        ),
      ),
    );
  }

  /// Step of the move and resize custom semantics actions.
  static const double _a11yStep = 48;

  /// Moves the card by [delta], kept inside the safe area.
  void _moveCardBy(Offset delta) {
    setState(() {
      _cardOffset = (_cardOffset ?? Offset.zero) + delta;
      _cardOffset = _clampOffset(
        MediaQuery.sizeOf(context),
        _cachedSafePadding,
        _cachedEffectiveWidth,
        _cachedKeyboardHeight,
      );
    });
    _commitGeometry();
  }

  /// Card size read back by screen readers after a move or resize.
  static String _sizeValue(double width, double height) =>
      '${width.round()} by ${height.round()} points';

  /// Moves the card to the top-left corner of the safe area.
  void _moveCardToCorner() {
    setState(() {
      _cardOffset = Offset(_cachedSafePadding.left, _cachedSafePadding.top);
    });
    _commitGeometry();
  }

  // ─── Header ──────────────────────────────────────────────────────────

  Widget _buildHeader(
    Size screenSize,
    double effectiveWidth,
    double cardHeight,
    Offset position,
    SleuthThemeData theme,
  ) {
    final isMinimized = _windowState == CardWindowState.minimized;
    final isNormal = _windowState == CardWindowState.normal;
    // Only show window controls when the card is wide enough to avoid overflow.
    final showWindowControls = effectiveWidth >= 280 || !isNormal;
    // The header is the drag handle; screen readers move the card through
    // the custom actions in 48 px steps and hear the size and position
    // back. The pan recognizer is kept out of semantics: its scroll
    // actions would move the card by most of its own size.
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Sleuth',
      value:
          '${_sizeValue(effectiveWidth, cardHeight)}, at '
          '${position.dx.round()}, ${position.dy.round()}',
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Move up'): () =>
            _moveCardBy(const Offset(0, -_a11yStep)),
        const CustomSemanticsAction(label: 'Move down'): () =>
            _moveCardBy(const Offset(0, _a11yStep)),
        const CustomSemanticsAction(label: 'Move left'): () =>
            _moveCardBy(const Offset(-_a11yStep, 0)),
        const CustomSemanticsAction(label: 'Move right'): () =>
            _moveCardBy(const Offset(_a11yStep, 0)),
        const CustomSemanticsAction(label: 'Move to top left'):
            _moveCardToCorner,
      },
      child: GestureDetector(
        excludeFromSemantics: true,
        onPanUpdate: (details) {
          setState(() {
            _cardOffset = (_cardOffset ?? Offset.zero) + details.delta;
            _cardOffset = _clampOffset(
              screenSize,
              _cachedSafePadding,
              _cachedEffectiveWidth,
              _cachedKeyboardHeight,
            );
          });
        },
        onPanEnd: (_) => _commitGeometry(),
        behavior: HitTestBehavior.opaque,
        child: SleuthTextScaleClamp(
          maxScaleFactor: kChromeMaxTextScale,
          child: Padding(
            padding: EdgeInsets.only(
              left: theme.spacingMd,
              right: theme.spacingXs,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: _controlRowHeight),
              child: Row(
                children: [
                  Icon(Icons.pets, size: 14, color: theme.textPrimary),
                  SizedBox(width: theme.spacingXs),
                  // The title gives way first: it ellipsizes before any
                  // control loses its 48 px height. The header node carries
                  // the name.
                  Expanded(
                    child: ExcludeSemantics(
                      child: Text(
                        'Sleuth',
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: theme.fontBase,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  // Issue count badge (visible when minimized so user sees at a glance)
                  if (isMinimized)
                    ValueListenableBuilder<List<PerformanceIssue>>(
                      valueListenable: widget.controller.issuesNotifier,
                      builder: (_, issues, _) => _minimizedCountBadge(
                        _ui.visibleIssues(issues),
                        theme,
                      ),
                    ),
                  // Highlight overlay toggle (hidden when minimized)
                  if (!isMinimized)
                    ValueListenableBuilder<bool>(
                      valueListenable:
                          widget.controller.highlightEnabledNotifier,
                      builder: (_, enabled, _) => _compactHeaderButton(
                        icon: enabled ? Icons.layers : Icons.layers_outlined,
                        color: enabled
                            ? theme.checkboxActive
                            : theme.textTertiary,
                        onTap: () {
                          final newValue = !enabled;
                          widget.controller.highlightEnabledNotifier.value =
                              newValue;
                          if (!newValue) {
                            widget.controller.clearSelectedHighlight();
                          }
                        },
                        tooltip: enabled ? 'Hide overlay' : 'Show overlay',
                      ),
                    ),
                  // Theme toggle: System -> Light -> Dark (hidden when minimized).
                  if (!isMinimized)
                    _compactHeaderButton(
                      icon: switch (_ui.themeMode) {
                        SleuthThemeMode.system => Icons.brightness_auto,
                        SleuthThemeMode.light => Icons.light_mode,
                        SleuthThemeMode.dark => Icons.dark_mode,
                      },
                      color: theme.textTertiary,
                      onTap: _cycleThemeMode,
                      tooltip: 'Toggle theme',
                      value: _themeModeLabel(_ui.themeMode),
                    ),
                  // Window controls. Hidden at narrow widths (<280px) so the
                  // title keeps some room.
                  if (showWindowControls && isNormal)
                    _compactHeaderButton(
                      icon: Icons.minimize,
                      color: theme.textTertiary,
                      onTap: _minimize,
                      tooltip: 'Minimize',
                    ),
                  if (showWindowControls && isNormal)
                    _compactHeaderButton(
                      icon: Icons.crop_square,
                      color: theme.textTertiary,
                      onTap: () => _maximize(context),
                      tooltip: 'Maximize',
                    ),
                  if (showWindowControls && !isNormal)
                    _compactHeaderButton(
                      icon: Icons.filter_none,
                      color: theme.textTertiary,
                      onTap: _restore,
                      tooltip: 'Restore',
                    ),
                  // Close button
                  _headerIconButton(
                    icon: Icons.close,
                    color: theme.textTertiary,
                    onTap: widget.onClose,
                    tooltip: 'Close Sleuth',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Issue count shown in the minimized header; nothing without issues.
  Widget _minimizedCountBadge(
    List<PerformanceIssue> visible,
    SleuthThemeData theme,
  ) {
    if (visible.isEmpty) return const SizedBox.shrink();
    final count = visible.length;
    return Semantics(
      label: '$count issue${count == 1 ? '' : 's'}',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.badgeFill(theme.severityWarning),
          borderRadius: BorderRadius.circular(theme.radiusLg),
          border: Border.all(color: theme.severityWarning),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Text(
            '$count',
            style: TextStyle(
              color: theme.badgeTextOn(
                theme.severityWarning,
                tinted: theme.severityWarningText,
              ),
              fontSize: theme.fontXs,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }

  /// 48 x 48 header button (close).
  Widget _headerIconButton({
    required IconData icon,
    required VoidCallback onTap,
    required Color color,
    String? tooltip,
  }) {
    // GestureDetector instead of IconButton to avoid tooltip OverlayPortal
    // crash — the sleuth overlay sits outside the app's Navigator/Overlay,
    // so OverlayPortal can't find a _RenderTheaterMarker ancestor.
    return Semantics(
      label: tooltip,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: _controlRowHeight,
          height: _controlRowHeight,
          child: Center(child: Icon(icon, color: color, size: 16)),
        ),
      ),
    );
  }

  /// 36 x 48 header button. Five 48 px wide controls plus the title do not
  /// fit the narrowest card, so the header controls are 36 wide; 36 x 48
  /// with no gap is above the WCAG 2.5.8 24 px minimum.
  Widget _compactHeaderButton({
    required IconData icon,
    required VoidCallback onTap,
    required Color color,
    String? tooltip,
    String? value,
  }) {
    return Semantics(
      label: tooltip,
      value: value,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 36,
          height: _controlRowHeight,
          child: Center(child: Icon(icon, color: color, size: 14)),
        ),
      ),
    );
  }

  // ─── Issues List ─────────────────────────────────────────────────────

  Widget _buildIssuesList(double chromeScale) {
    // The list rebuilds only when the issue set changes. Each card's
    // recurrence badge re-reads `recurrenceTrends` on the scan pulse by
    // itself, so a tick that leaves the issues unchanged rebuilds badges,
    // not cards.
    return ValueListenableBuilder<List<PerformanceIssue>>(
      valueListenable: widget.controller.issuesNotifier,
      builder: (context, issues, _) {
        final theme = SleuthTheme.of(context);
        if (issues.isEmpty) {
          return Center(
            child: Text(
              '✅ No issues detected',
              style: TextStyle(
                color: theme.severityOkText,
                fontSize: theme.fontMd,
              ),
            ),
          );
        }

        // Severity filter, then collapse, then hide — the same list
        // `_pruneStaleState` keys against. See [applyOverlayFilters].
        final ui = _ui;
        final visibleIssues = ui.visibleIssues(issues);

        // Lists behind the summary chips and the "Showing X of Y" line.
        final allSeverities = {...IssueSeverity.values};
        final unfiltered = applyOverlayFilters(
          issues,
          severities: allSeverities,
          hiddenKeys: ui.hiddenKeys,
        );
        final unhidden = applyOverlayFilters(
          issues,
          severities: allSeverities,
          hiddenKeys: const {},
        );
        // `unhidden` is the default-state list (every severity, nothing
        // hidden), so its length is the card total. Stale hidden keys
        // that match nothing leave the count unchanged and do not narrow.
        final totalCards = unhidden.length;
        final isNarrowed = visibleIssues.length < totalCards;

        final summary = _IssuesSummaryBar(
          chromeScale: chromeScale,
          issues: visibleIssues,
          severityCounts: unfiltered,
          enabledSeverities: ui.severityFilter,
          shownOfTotal: isNarrowed
              ? (shown: visibleIssues.length, total: totalCards)
              : null,
          onToggleSeverity: _toggleSeverity,
        );

        if (visibleIssues.isEmpty) {
          final allHidden = unfiltered.isEmpty;
          return _IssuesSummaryBar.above(
            chromeScale: chromeScale,
            summary: summary,
            body: _EmptyListMessage(
              message: allHidden
                  ? 'All ${unhidden.length} '
                        '${unhidden.length == 1 ? 'issue' : 'issues'} hidden'
                  : 'No issues match the severity filter',
              actionLabel: allHidden ? 'Show hidden' : 'Reset',
              onAction: allHidden
                  ? () => setState(() => _showHidden = true)
                  : ui.resetSeverityFilter,
            ),
          );
        }

        // Apply the freeze zone AFTER the summary bar reads the flow
        // ordering. Freezing is a render-order concern only — counts in
        // the summary bar must not change based on which cards are
        // currently expanded. Always feed the flow (pre-freeze) list
        // into `_IssuesSummaryBar`.
        final orderedIssues = applyFreezeZone(
          visibleIssues: visibleIssues,
          orderSnapshot: _orderSnapshot,
          expandedIndices: _expandedIndices,
        );

        // Pre-build stableId → issue map across the FULL live list (not
        // just `orderedIssues` — downstream/parent issues collapsed under
        // a root card are filtered out of the visible set but still need
        // to render inside that card). Used by both downstream and parent
        // resolution below; without this, each itemBuilder pass would do
        // O(n) inner scans, dropping FloatingIssuesCard rebuild cost on
        // every scan-tick to O(n²).
        final stableIdToIssue = <String, PerformanceIssue>{
          for (final i in issues) (i.stableId ?? i.title): i,
        };

        // Pre-build key → index map for `findChildIndexCallback`. Without
        // this, the callback would scan `orderedIssues` linearly for
        // every kept-alive keyed child, making each rebuild O(n²) in
        // the visible-card count. Tall maximized overlays with ~30 issues
        // otherwise do ~900 string compares per scan-tick rebuild.
        //
        // Two issues can share a list key (a detector that emits one
        // issue per occurrence under the same stable id and widget
        // name). The sliver needs distinct keys or its child-order
        // check fails, so repeats get an occurrence suffix. Expansion,
        // hide and highlight bookkeeping keep the shared key.
        final listKeys = List<String>.generate(orderedIssues.length, (i) {
          return listKeyFor(orderedIssues[i]);
        });
        final seenKeys = <String, int>{};
        for (var i = 0; i < listKeys.length; i++) {
          final n = (seenKeys[listKeys[i]] ?? 0) + 1;
          seenKeys[listKeys[i]] = n;
          if (n > 1) listKeys[i] = '${listKeys[i]}#$n';
        }
        final orderedIndexByKey = <String, int>{
          for (var i = 0; i < listKeys.length; i++) listKeys[i]: i,
        };

        return _IssuesSummaryBar.above(
          chromeScale: chromeScale,
          summary: summary,
          body: ValueListenableBuilder<WidgetHighlight?>(
            valueListenable: widget.controller.selectedHighlightNotifier,
            builder: (_, selectedHighlight, _) => ListView.builder(
              padding: EdgeInsets.all(theme.spacingSm),
              itemCount: orderedIssues.length,
              // Keyed-reorder remount fix: without a
              // `findChildIndexCallback`, `SliverChildBuilderDelegate`
              // cannot locate a keyed child whose index has shifted
              // between builds, so Flutter destroys the Element and
              // builds a fresh one — which resets `_IssueCardState`
              // (loses expansion, scroll, and all local UI state).
              // This hits any issue whose rank position moves when
              // the ranker reorders the list. Cards are already
              // `ValueKey`-stamped with `listKeyFor`; this callback
              // just tells the sliver where each key landed.
              //
              // Looks up `orderedIndexByKey` (the POST-pin map) so
              // the sliver locates keyed children at their rendered
              // positions. Using the pre-pin list here would remount
              // every pinned card on the first render after pin
              // application, which resets `_IssueCardState` — the
              // very bug the `ValueKey` + findChildIndexCallback
              // pair exists to prevent.
              findChildIndexCallback: (Key key) {
                if (key is! ValueKey<String>) return null;
                return orderedIndexByKey[key.value];
              },
              itemBuilder: (_, index) {
                final issue = orderedIssues[index];
                final locatable = _isLocatableIssue(issue);
                final issueKey = listKeyFor(issue);
                final isHighlighted =
                    selectedHighlight != null &&
                    locatable &&
                    _selectedIssueId == issueKey;

                // Look up downstream issue objects for root issues.
                // Uses the precomputed stableId→issue map (O(1) per
                // lookup) so this resolution does not blow up to
                // O(n²) on tall overlays.
                List<PerformanceIssue>? downstream;
                if (issue.downstreamIds != null &&
                    issue.downstreamIds!.isNotEmpty) {
                  downstream = <PerformanceIssue>[];
                  for (final downId in issue.downstreamIds!) {
                    final found = stableIdToIssue[downId];
                    if (found != null) downstream.add(found);
                  }
                }

                // Resolve parent issues for the multi-parent "Caused
                // by" badge. parentIssues is null when no annotation
                // exists or when every parent is suppressed by the
                // ranker. Suppressed-but-annotated parents surface
                // as a count for the IssueCard's "(+N not shown)"
                // annotation so a partial parent list does not look
                // complete.
                List<PerformanceIssue>? parents;
                var suppressedParentCount = 0;
                final parentIds = issue.rootCauseIds;
                if (parentIds != null && parentIds.isNotEmpty) {
                  parents = <PerformanceIssue>[];
                  for (final parentId in parentIds) {
                    final found = stableIdToIssue[parentId];
                    if (found != null) {
                      parents.add(found);
                    } else {
                      suppressedParentCount++;
                    }
                  }
                  if (parents.isEmpty) parents = null;
                }

                // Capture the build-time `index` into a local so the
                // `onExpandedChanged` closure closes over a
                // deterministic value instead of whatever `index`
                // would be at callback-time (which could be stale
                // if a scan tick fired between build and tap).
                final capturedIndex = index;

                // Capture the build-time visibleIssues reference so
                // the snapshot taken on 0→1 expand reflects what the
                // user actually saw, NOT a newer value that may have
                // been published to `issuesNotifier` between the
                // frame commit and the tap arriving. Defensive copy
                // is made inside the callback so the snapshot
                // outlives this build closure without being aliased
                // to the live list.
                final capturedVisibleIssues = visibleIssues;

                // The list `capturedIndex` indexes. An expansion below the
                // frozen zone re-captures the snapshot from it.
                final capturedOrdered = orderedIssues;

                return IssueCard(
                  key: ValueKey(listKeys[index]),
                  issue: issue,
                  recurrenceTrendOf: () =>
                      widget.controller.recurrenceTrends[issue.stableId ??
                          issue.title],
                  scanTick: widget.controller.scanTickNotifier,
                  deepInstrumentationActive:
                      widget.controller.isDeepInstrumentationActive,
                  initiallyExpanded: _expandedIndices.containsKey(issueKey),
                  collapseEpoch: _collapseEpoch,
                  onExpandedChanged: (expanded) {
                    setState(() {
                      if (expanded) {
                        // 0→1 transition: capture snapshot before
                        // recording the expand entry so the class
                        // invariant (snapshot != null ↔ map not
                        // empty) holds at every observable state.
                        if (_expandedIndices.isEmpty) {
                          _orderSnapshot = List<PerformanceIssue>.of(
                            capturedVisibleIssues,
                          );
                        } else if (capturedIndex >
                            _expandedIndices.values.reduce(math.max)) {
                          // The zone grows past the snapshot's frozen
                          // slice, whose tail may no longer match the rows
                          // on screen. Re-capture what the user sees so
                          // the new index points into the list it came
                          // from.
                          final snapshot = List<PerformanceIssue>.of(
                            capturedOrdered,
                          );
                          _repointExpansions(snapshot);
                          _orderSnapshot = snapshot;
                        }
                        _expandedIndices[issueKey] = capturedIndex;
                      } else {
                        _expandedIndices.remove(issueKey);
                        // 1→0 transition: release the snapshot so
                        // the next expand captures a fresh one from
                        // whatever the ranker currently shows.
                        if (_expandedIndices.isEmpty) {
                          _orderSnapshot = null;
                        }
                      }
                    });
                  },
                  locatable: locatable,
                  highlighted: isHighlighted,
                  onHighlightChanged: locatable
                      ? (checked) =>
                            _onHighlightChanged(checked, issueKey, issue)
                      : null,
                  jankCorrelated: _cachedJankKeys.contains(
                    issue.stableId ?? issue.title,
                  ),
                  jankFlash: false,
                  downstreamIssues: downstream,
                  parentIssues: parents,
                  suppressedParentCount: suppressedParentCount,
                  onLearnMore:
                      IssueExplanationBuilder.explain(issue.stableId) != null
                      ? () => setState(() {
                          _detailStableId = issue.stableId;
                          _detailContextIssue = issue;
                          _showDetail = true;
                        })
                      : null,
                  onAskAi: widget.controller.config.aiChat != null
                      ? () => setState(() {
                          _chatIssueStableId = issue.stableId ?? issue.title;
                          _showAiChat = true;
                        })
                      : null,
                  onCopy: () => _copyIssue(issue),
                  onHide: () => _hideIssue(issue),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

// ─── Status Row ─────────────────────────────────────────────────────────

enum _LineSlot { lead, trail }

/// [lead] at the start and [trail] at the end of one line, vertically
/// centred; when they do not fit side by side, [trail] moves below
/// [lead] and stays at the end.
class _LeadTrailLine
    extends SlottedMultiChildRenderObjectWidget<_LineSlot, RenderBox> {
  const _LeadTrailLine({
    required this.lead,
    required this.trail,
    required this.gap,
  });

  final Widget lead;
  final Widget trail;

  /// Smallest horizontal gap between [lead] and [trail] on one line.
  final double gap;

  @override
  Iterable<_LineSlot> get slots => _LineSlot.values;

  @override
  Widget? childForSlot(_LineSlot slot) => switch (slot) {
    _LineSlot.lead => lead,
    _LineSlot.trail => trail,
  };

  @override
  _RenderLeadTrailLine createRenderObject(BuildContext context) =>
      _RenderLeadTrailLine(gap);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderLeadTrailLine renderObject,
  ) {
    renderObject.gap = gap;
  }
}

class _RenderLeadTrailLine extends RenderBox
    with SlottedContainerRenderObjectMixin<_LineSlot, RenderBox> {
  _RenderLeadTrailLine(this._gap);

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  RenderBox? get _lead => childForSlot(_LineSlot.lead);
  RenderBox? get _trail => childForSlot(_LineSlot.trail);

  Size _layout(
    BoxConstraints constraints,
    ChildLayouter layoutChild, {
    bool position = false,
  }) {
    final lead = _lead;
    final trail = _trail;
    final loose = constraints.loosen();
    final leadSize = lead == null ? Size.zero : layoutChild(lead, loose);
    final trailSize = trail == null ? Size.zero : layoutChild(trail, loose);
    final oneLineWidth = leadSize.width + _gap + trailSize.width;
    final width = constraints.hasBoundedWidth
        ? constraints.maxWidth
        : oneLineWidth;
    final oneLine = oneLineWidth <= width;
    final height = oneLine
        ? math.max(leadSize.height, trailSize.height)
        : leadSize.height + trailSize.height;
    if (position) {
      final trailX = math.max(0.0, width - trailSize.width);
      if (lead != null) {
        (lead.parentData! as BoxParentData).offset = Offset(
          0,
          oneLine ? (height - leadSize.height) / 2 : 0,
        );
      }
      if (trail != null) {
        (trail.parentData! as BoxParentData).offset = Offset(
          trailX,
          oneLine ? (height - trailSize.height) / 2 : leadSize.height,
        );
      }
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _layout(constraints, ChildLayoutHelper.dryLayoutChild);

  @override
  void performLayout() {
    size = _layout(constraints, ChildLayoutHelper.layoutChild, position: true);
  }

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
    _lead?.getMinIntrinsicWidth(height) ?? 0,
    _trail?.getMinIntrinsicWidth(height) ?? 0,
  );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      (_lead?.getMaxIntrinsicWidth(height) ?? 0) +
      _gap +
      (_trail?.getMaxIntrinsicWidth(height) ?? 0);

  double _intrinsicHeight(double width, bool max) {
    double h(RenderBox? box) => box == null
        ? 0
        : max
        ? box.getMaxIntrinsicHeight(width)
        : box.getMinIntrinsicHeight(width);
    final fits = computeMaxIntrinsicWidth(double.infinity) <= width;
    return fits ? math.max(h(_lead), h(_trail)) : h(_lead) + h(_trail);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight(width, false);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight(width, true);

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final child in children) {
      final parentData = child.parentData! as BoxParentData;
      context.paintChild(child, offset + parentData.offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final child in children) {
      final parentData = child.parentData! as BoxParentData;
      final hit = result.addWithPaintOffset(
        offset: parentData.offset,
        position: position,
        hitTest: (result, transformed) =>
            child.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }
}

class _StatusRow extends StatefulWidget {
  const _StatusRow({required this.controller});

  final SleuthController controller;

  @override
  State<_StatusRow> createState() => _StatusRowState();
}

class _StatusRowState extends State<_StatusRow> {
  /// Minimum frames in the buffer before the primary numeral shows.
  /// Shown as `—` while the buffer warms up so the first tick does not
  /// flash a red 0.
  static const int _warmupFrameCount = 3;

  /// True when the user has tapped the info icon — reveals the Actual /
  /// Throughput FPS detail row and short explainer.
  bool _infoExpanded = false;

  SleuthController get controller => widget.controller;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    // The FPS group and the VM+/FRAME and DBG badges wrap; the issue count
    // stays at the right edge, below them when it does not fit beside.
    return SleuthTextScaleClamp(
      maxScaleFactor: kChromeMaxTextScale,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.symmetric(horizontal: theme.spacingLg),
            child: _LeadTrailLine(
              gap: theme.spacingXs,
              lead: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: theme.spacingXs,
                children: [
                  _fpsGroup(theme),
                  _modeBadge(theme),
                  if (kDebugMode && controller.isDebugCallbacksActive)
                    _badge(theme, 'DBG', theme.badgeDbgBg, theme.badgeDbgText),
                ],
              ),
              trail: _issueCount(theme),
            ),
          ),
          if (_infoExpanded) ...[
            Padding(
              padding: EdgeInsets.fromLTRB(
                theme.spacingLg,
                0,
                theme.spacingLg,
                theme.spacingXs,
              ),
              child: Text(
                'TPUT (primary): latency-derived capacity estimate.\n'
                'ACTUAL: presented frames/sec (count — low when idle).',
                style: TextStyle(
                  color: theme.textTertiary,
                  fontSize: theme.fontXs,
                  height: 1.4,
                ),
              ),
            ),
            _ThroughputDetailRow(controller: controller),
          ],
        ],
      ),
    );
  }

  // Primary numeral shows throughputFps (latency-derived) so idle screens
  // read smooth — actualFps counts presented frames and drops to low
  // values when Flutter is not repainting. True device rate is still
  // exposed in the expanded detail row (ACTUAL cell) and the snapshot
  // export.
  Widget _fpsGroup(SleuthThemeData theme) {
    return ValueListenableBuilder<FrameStatsBuffer>(
      valueListenable: controller.frameStatsNotifier,
      builder: (_, buffer, _) {
        final target = controller.config.fpsTarget;
        final isWarming = buffer.length < _warmupFrameCount;
        final fps = buffer.throughputFps.clamp(0.0, target.toDouble());
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              isWarming ? '—' : fps.toStringAsFixed(0),
              style: TextStyle(
                color: isWarming
                    ? theme.textTertiary
                    : theme.fpsTextColor(fps, target: target),
                fontSize: theme.fontXxl,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(width: theme.spacingXxs),
            Text(
              'FPS',
              style: TextStyle(
                color: theme.textTertiary,
                fontSize: theme.fontSm,
              ),
            ),
            Semantics(
              label: _infoExpanded
                  ? 'Hide FPS explainer'
                  : 'Show FPS explainer',
              button: true,
              expanded: _infoExpanded,
              child: GestureDetector(
                onTap: () => setState(() => _infoExpanded = !_infoExpanded),
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Icon(
                      Icons.info_outline,
                      size: 14,
                      color: theme.textQuaternary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// VM+ when the VM service is connected, FRAME otherwise.
  Widget _modeBadge(SleuthThemeData theme) {
    return ValueListenableBuilder<bool>(
      valueListenable: controller.vmConnectedNotifier,
      builder: (_, connected, _) => _badge(
        theme,
        connected ? 'VM+' : 'FRAME',
        connected ? theme.badgeVmBg : theme.badgeFrameBg,
        connected ? theme.badgeVmText : theme.badgeFrameText,
      ),
    );
  }

  Widget _badge(SleuthThemeData theme, String label, Color bg, Color fg) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(theme.radiusLg),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          label,
          style: TextStyle(
            color: fg,
            fontSize: theme.fontXxs,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  /// Issue count with a severity dot.
  Widget _issueCount(SleuthThemeData theme) {
    return ValueListenableBuilder<List<PerformanceIssue>>(
      valueListenable: controller.issuesNotifier,
      builder: (_, issues, _) {
        if (issues.isEmpty) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle, color: theme.severityOk, size: 14),
              SizedBox(width: theme.spacingXs),
              Text(
                '0 issues',
                style: TextStyle(
                  color: theme.severityOkText,
                  fontSize: theme.fontMd,
                ),
              ),
            ],
          );
        }
        final hasCritical = issues.any(
          (i) => i.severity == IssueSeverity.critical,
        );
        final severityColor = hasCritical
            ? theme.severityCritical
            : theme.severityWarning;
        final severityText = hasCritical
            ? theme.severityCriticalText
            : theme.severityWarningText;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: severityColor,
                shape: BoxShape.circle,
              ),
              child: const SizedBox(width: 8, height: 8),
            ),
            SizedBox(width: theme.spacingXs),
            Text(
              '${issues.length} issue${issues.length == 1 ? '' : 's'}',
              style: TextStyle(color: severityText, fontSize: theme.fontMd),
            ),
          ],
        );
      },
    );
  }
}

/// Expanded-card detail row showing actualFps alongside throughputFps.
/// Visible only when the user taps the info icon on `_StatusRow`.
class _ThroughputDetailRow extends StatelessWidget {
  const _ThroughputDetailRow({required this.controller});
  final SleuthController controller;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        theme.spacingLg,
        0,
        theme.spacingLg,
        theme.spacingXs,
      ),
      child: ValueListenableBuilder<FrameStatsBuffer>(
        valueListenable: controller.frameStatsNotifier,
        builder: (_, buffer, _) {
          final target = controller.config.fpsTarget;
          final actual = buffer.actualFps.clamp(0.0, target.toDouble());
          final throughput = buffer.throughputFps.clamp(0.0, target.toDouble());
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _FpsCell(value: actual, target: target, label: 'ACTUAL'),
              SizedBox(width: theme.spacingLg),
              _FpsCell(value: throughput, target: target, label: 'TPUT'),
            ],
          );
        },
      ),
    );
  }
}

class _FpsCell extends StatelessWidget {
  const _FpsCell({
    required this.value,
    required this.target,
    required this.label,
  });
  final double value;
  final int target;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value.toStringAsFixed(0),
          style: TextStyle(
            color: theme.fpsTextColor(value, target: target),
            fontSize: theme.fontXxl,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: theme.textTertiary,
            fontSize: theme.fontXs,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

// ─── Debug Mode Banner ──────────────────────────────────────────────────

class _DebugModeBanner extends StatelessWidget {
  const _DebugModeBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: theme.bannerWarningBg),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: theme.spacingSm,
          vertical: theme.spacingXs,
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber, size: 14, color: theme.bannerWarningText),
            SizedBox(width: theme.spacingXs),
            Expanded(
              child: Text(
                'Debug mode \u2014 timings are ~10\u00D7 slower than production. '
                'Run with flutter run --profile for accurate measurements.',
                style: TextStyle(
                  color: theme.bannerWarningText,
                  fontSize: theme.fontSm,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Semantics(
              label: 'Dismiss debug mode banner',
              button: true,
              child: GestureDetector(
                onTap: onDismiss,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Icon(
                      Icons.close,
                      size: 14,
                      color: theme.bannerWarningText,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Warning Banners ────────────────────────────────────────────────────

class _WarningBanners extends StatelessWidget {
  const _WarningBanners({required this.isDeepInstrumentationActive});

  final bool isDeepInstrumentationActive;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (kDebugMode)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: theme.spacingSm,
            ),
            decoration: BoxDecoration(
              color: theme.bannerDebugBg,
              borderRadius: BorderRadius.circular(theme.radiusLg),
            ),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Text('⚠️', style: TextStyle(fontSize: theme.fontBase)),
                ),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    'Debug mode — data inaccurate.\nRun: flutter run --profile',
                    style: TextStyle(
                      color: theme.bannerDebugText,
                      fontSize: theme.fontSm,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (kDebugMode && isDeepInstrumentationActive)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: theme.spacingSm,
            ),
            decoration: BoxDecoration(
              color: theme.bannerInstrumentationBg,
              borderRadius: BorderRadius.circular(theme.radiusLg),
            ),
            child: Row(
              children: [
                ExcludeSemantics(
                  child: Text('🔬', style: TextStyle(fontSize: theme.fontBase)),
                ),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    'Instrumentation active — rebuild/paint counts useful for '
                    'attribution. Timings not representative of real performance.',
                    style: TextStyle(
                      color: theme.bannerInstrumentationText,
                      fontSize: theme.fontSm,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ─── Card Footer ────────────────────────────────────────────────────────

/// Footer text for [hidden] runtime-hidden and [suppressed]
/// config-suppressed issues, e.g. `2 hidden · 3 suppressed`; a part is
/// omitted when its count is 0, and null when both are.
@visibleForTesting
String? hiddenFooterLabel(int hidden, int suppressed) {
  final parts = [
    if (hidden > 0) '$hidden hidden',
    if (suppressed > 0) '$suppressed suppressed',
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

class _CardFooter extends StatelessWidget {
  const _CardFooter({
    required this.controller,
    required this.hiddenCount,
    required this.onShowHidden,
    required this.onExport,
    required this.onEncyclopedia,
    required this.onGuide,
  });

  final SleuthController controller;

  /// Issues hidden from the overlay at runtime.
  final int hiddenCount;

  /// Opens the Hidden list.
  final VoidCallback onShowHidden;
  final VoidCallback onExport;
  final VoidCallback onEncyclopedia;
  final VoidCallback onGuide;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Container(
      // The right inset leaves the corner to the 48 px resize handle.
      padding: EdgeInsets.only(left: theme.spacingMd, right: 48),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.border, width: 1)),
      ),
      child: SleuthTextScaleClamp(
        maxScaleFactor: kChromeMaxTextScale,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Semantics(
              label: 'Encyclopedia',
              button: true,
              child: GestureDetector(
                onTap: onEncyclopedia,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Icon(
                      Icons.menu_book_outlined,
                      color: theme.textTertiary,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              label: 'Export',
              button: true,
              child: GestureDetector(
                onTap: onExport,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Icon(
                      Icons.ios_share,
                      color: theme.textTertiary,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              label: 'Guide',
              button: true,
              child: GestureDetector(
                onTap: onGuide,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Icon(
                      Icons.help_outline,
                      color: theme.textTertiary,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ),
            ValueListenableBuilder<int>(
              valueListenable: controller.suppressedCountNotifier,
              builder: (_, suppressed, _) {
                final label = hiddenFooterLabel(hiddenCount, suppressed);
                if (label == null) return const SizedBox.shrink();
                return Flexible(
                  child: Semantics(
                    button: true,
                    label: '$label. Show hidden issues',
                    onTap: onShowHidden,
                    container: true,
                    excludeSemantics: true,
                    child: GestureDetector(
                      onTap: onShowHidden,
                      behavior: HitTestBehavior.opaque,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        child: Padding(
                          padding: EdgeInsets.only(left: theme.spacingMd),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            widthFactor: 1,
                            child: Text(
                              label,
                              style: TextStyle(
                                color: theme.textQuaternary,
                                fontSize: theme.fontSm,
                                decoration: TextDecoration.underline,
                                decorationColor: theme.textQuaternary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Issues Summary Bar ──────────────────────────────────────────────────

class _IssuesSummaryBar extends StatelessWidget {
  const _IssuesSummaryBar({
    required this.chromeScale,
    required this.issues,
    required this.severityCounts,
    required this.enabledSeverities,
    required this.shownOfTotal,
    required this.onToggleSeverity,
  });

  /// Cards currently shown; drives the confirmed/heuristic split.
  final List<PerformanceIssue> issues;

  /// Cards per severity with every severity enabled (hidden cards
  /// excluded); drives the chip counts.
  final List<PerformanceIssue> severityCounts;

  final Set<IssueSeverity> enabledSeverities;

  /// Set when a severity is off or a card is hidden: shown and total
  /// card counts for "Showing X of Y".
  final ({int shown, int total})? shownOfTotal;

  final ValueChanged<IssueSeverity> onToggleSeverity;

  /// Chrome text scale (1.0 to 1.3); the bar grows with it.
  final double chromeScale;

  static const _order = [
    IssueSeverity.critical,
    IssueSeverity.warning,
    IssueSeverity.ok,
  ];

  /// Height the bar takes from the list at 1.0x text.
  static const double barHeight = 36;

  /// Minimum height of the chips' hit boxes.
  static const double minHitHeight = 48;

  /// Bar height at [chromeScale].
  static double barHeightFor(double chromeScale) => barHeight * chromeScale;

  /// Height of the chips' hit boxes at [chromeScale]: at least
  /// [minHitHeight]. The part below the bar overlaps the top of the list
  /// and takes taps only where a chip is.
  static double hitHeightFor(double chromeScale) =>
      math.max(minHitHeight, barHeightFor(chromeScale));

  /// [summary] over [body]: [body] starts one bar height below the top,
  /// and [summary] is laid over it so the chips keep their hit boxes
  /// without taking more height from the list.
  static Widget above({
    required double chromeScale,
    required Widget summary,
    required Widget body,
  }) => Stack(
    children: [
      Positioned.fill(top: barHeightFor(chromeScale), child: body),
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: hitHeightFor(chromeScale),
        child: SleuthTextScaleClamp(
          maxScaleFactor: kChromeMaxTextScale,
          child: summary,
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final counts = <IssueSeverity, int>{};
    for (final issue in severityCounts) {
      counts[issue.severity] = (counts[issue.severity] ?? 0) + 1;
    }
    var confirmed = 0;
    var heuristic = 0;
    for (final issue in issues) {
      if (issue.confidence == IssueConfidence.confirmed) {
        confirmed++;
      } else {
        heuristic++;
      }
    }
    final narrowed = shownOfTotal;
    final caption = narrowed != null
        ? 'Showing ${narrowed.shown} of ${narrowed.total}'
        : [
            if (confirmed > 0) '$confirmed confirmed',
            if (heuristic > 0) '$heuristic heuristic',
          ].join(' · ');

    // Only the chips take taps; the rest of the hit box lets them through
    // to the list below.
    final bar = barHeightFor(chromeScale);
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: bar,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: theme.border, width: 1),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: theme.spacingSm),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final severity in _order)
                  // A disabled severity keeps its chip so it can be
                  // turned back on, even when it has no cards right now.
                  if ((counts[severity] ?? 0) > 0 ||
                      !enabledSeverities.contains(severity))
                    _SeverityChip(
                      chromeScale: chromeScale,
                      severity: severity,
                      count: counts[severity] ?? 0,
                      selected: enabledSeverities.contains(severity),
                      onTap: () => onToggleSeverity(severity),
                    ),
                SizedBox(width: theme.spacingXs),
                Expanded(
                  child: IgnorePointer(
                    child: SizedBox(
                      height: bar,
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          caption,
                          style: TextStyle(
                            color: theme.textTertiary,
                            fontSize: theme.fontSm,
                          ),
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Severity count in the summary bar that toggles the overlay's severity
/// filter. The hit box is 48 x 48 at least; the pill sits centred in the
/// bar's visible height.
class _SeverityChip extends StatelessWidget {
  const _SeverityChip({
    required this.chromeScale,
    required this.severity,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final double chromeScale;
  final IssueSeverity severity;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final color = theme.severityColor(severity);
    final name = switch (severity) {
      IssueSeverity.critical => 'critical',
      IssueSeverity.warning => 'warning',
      IssueSeverity.ok => 'ok',
    };
    return Semantics(
      button: true,
      selected: selected,
      label: selected ? '$count $name, on' : '$count $name, off, tap to show',
      onTap: onTap,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: _IssuesSummaryBar.minHitHeight,
          ),
          child: SizedBox(
            height: _IssuesSummaryBar.hitHeightFor(chromeScale),
            child: Align(
              alignment: Alignment.topCenter,
              widthFactor: 1,
              child: SizedBox(
                height: _IssuesSummaryBar.barHeightFor(chromeScale),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: theme.spacingXxs),
                  child: Center(
                    widthFactor: 1,
                    child: _SeverityChipPill(
                      color: color,
                      textColor: theme.badgeTextOn(
                        color,
                        tinted: theme.severityTextColor(severity),
                      ),
                      count: count,
                      selected: selected,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The visible pill of a [_SeverityChip]; animates between selected
/// (severity fill at 0.15, border at 0.6) and unselected (border token at
/// 0.5, muted text) over 200 ms, or at once under reduced motion.
class _SeverityChipPill extends StatefulWidget {
  const _SeverityChipPill({
    required this.color,
    required this.textColor,
    required this.count,
    required this.selected,
  });

  final Color color;

  /// Count and dot colour when selected.
  final Color textColor;
  final int count;
  final bool selected;

  @override
  State<_SeverityChipPill> createState() => _SeverityChipPillState();
}

class _SeverityChipPillState extends State<_SeverityChipPill>
    with SingleTickerProviderStateMixin {
  static const Duration _lerp = Duration(milliseconds: 200);

  late final AnimationController _selection = AnimationController(
    vsync: this,
    duration: _lerp,
    value: widget.selected ? 1 : 0,
  )..addListener(_tick);

  void _tick() => setState(() {});

  @override
  void didUpdateWidget(_SeverityChipPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected) {
      _selection.duration = motionDuration(context, _lerp);
      if (widget.selected) {
        _selection.forward();
      } else {
        _selection.reverse();
      }
    }
  }

  @override
  void dispose() {
    _selection.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final t = _selection.value;
    final color = widget.color;
    final foreground = Color.lerp(theme.textQuaternary, widget.textColor, t)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: theme.badgeFillAlpha * t),
        borderRadius: BorderRadius.circular(theme.radiusMd),
        border: Border.all(
          // High contrast keeps both state borders at full strength.
          color: Color.lerp(
            theme.border.withValues(alpha: theme.badgeFillAlpha >= 1 ? 1 : 0.5),
            color.withValues(alpha: theme.badgeFillAlpha >= 1 ? 1 : 0.6),
            t,
          )!,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: theme.spacingSm,
          vertical: theme.spacingXxs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: foreground,
                shape: BoxShape.circle,
              ),
              child: const SizedBox(width: 6, height: 6),
            ),
            const SizedBox(width: 3),
            Text(
              '${widget.count}',
              style: TextStyle(
                color: foreground,
                fontSize: theme.fontSm,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Centered message with one action, shown when no card survives the
/// severity filter or hiding.
class _EmptyListMessage extends StatelessWidget {
  const _EmptyListMessage({
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: EdgeInsets.all(theme.spacingMd),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: theme.fontMd,
              ),
            ),
            Semantics(
              button: true,
              label: actionLabel,
              onTap: onAction,
              container: true,
              excludeSemantics: true,
              child: GestureDetector(
                onTap: onAction,
                behavior: HitTestBehavior.opaque,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      actionLabel,
                      style: TextStyle(
                        color: theme.checkboxActive,
                        fontSize: theme.fontMd,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paints diagonal grip dots in the bottom-right corner.
/// 6 dots in a triangle pattern, inset to sit within the card's 16px corner radius.
class _CornerGripPainter extends CustomPainter {
  const _CornerGripPainter({required this.gripColor});

  final Color gripColor;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = gripColor
      ..style = PaintingStyle.fill;

    const r = 1.3; // dot radius
    const gap = 4.5; // spacing between dots
    // Inset from bottom-right to stay inside the 16px corner radius
    final bx = size.width - 6;
    final by = size.height - 6;

    // Row 1 (bottom): 3 dots
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(Offset(bx - i * gap, by), r, paint);
    }
    // Row 2: 2 dots
    for (var i = 0; i < 2; i++) {
      canvas.drawCircle(Offset(bx - i * gap, by - gap), r, paint);
    }
    // Row 3: 1 dot
    canvas.drawCircle(Offset(bx, by - 2 * gap), r, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerGripPainter oldDelegate) =>
      gripColor != oldDelegate.gripColor;
}

// ─── Startup Metrics Banner ─────────────────────────────────────────────

class _StartupMetricsBanner extends StatelessWidget {
  const _StartupMetricsBanner({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final metrics = Sleuth.startupMetrics;
    if (metrics == null) return const SizedBox.shrink();

    final theme = SleuthTheme.of(context);
    final parts = <String>[];
    if (metrics.ttffMs != null) {
      parts.add('TTFF: ${metrics.ttffMs!.round()} ms');
    }
    if (metrics.ttiMs != null) {
      parts.add('TTI: ${metrics.ttiMs!.round()} ms');
    }
    if (parts.isEmpty) return const SizedBox.shrink();

    final color = theme.categoryStartup;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Semantics(
        label: 'Startup metrics, tap for details',
        button: true,
        child: DecoratedBox(
          decoration: BoxDecoration(color: color.withValues(alpha: 0.1)),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: theme.spacingSm,
              vertical: theme.spacingXxs,
            ),
            // 48 px tall target; the banners scroll when the card is short.
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  Icon(Icons.rocket_launch_outlined, size: 12, color: color),
                  SizedBox(width: theme.spacingXs),
                  Expanded(
                    child: Text(
                      parts.join(' \u00B7 '),
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: theme.fontSm,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right,
                    size: 14,
                    color: color.withValues(alpha: 0.6),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Always-on entry point to the per-route rebuild data. Renders an inline
/// banner whenever the active [RouteSession] has any rebuild attribution,
/// regardless of whether any detector has emitted a warning. This is the
/// sole data-discovery surface for rebuild stats since v0.15.2 — the
/// previous `rebuild_hotspot_summary` rollup IssueCard was removed because
/// (a) the panel covers both the data and the signal, (b) an always-pinned
/// IssueCard collided with ranker reorders,
/// and (c) profile-mode KDD-5 inflations made route entry look like a
/// warning storm in the issues list.
///
/// **Two states:**
///
/// * **Collapsed (default)** — single row with `Rebuilds: N across M
///   widgets` + a chevron. Tap to expand.
/// * **Expanded** — collapsed header + top-3 widget rows with rank, name,
///   live-tweened count, and a normalised bar fill. A Pause toggle freezes
///   the displayed counts so the user can read a stable snapshot. A
///   `See all M →` link pushes the full [RebuildStatsPage] drilldown via
///   the same snapshot-and-push handler the rollup card used to use.
///
/// **Reactivity:** rebuilds on every scan tick (`scanTickNotifier`, the
/// pulse for rebuild-attribution updates) or when the active route session
/// itself changes (`routeHistoryNotifier`, which fires on route push/pop
/// and tab switches). The panel reads `controller.activeRouteSession` at
/// build time, so the union of these two notifiers is sufficient — no
/// extra per-frame work.
///
/// **Pause semantics:** when the user taps Pause, the panel snapshots
/// `RouteSession.rebuildCountsByType` into [_frozenCounts] and renders
/// from that map until the user taps Resume. If the route session
/// changes while paused (auto-detected via [routeHistoryNotifier]), the
/// freeze is automatically cleared so the user is never looking at
/// stale data from a previous route — the new route's panel starts
/// fresh in live mode.
class _RebuildStatsBanner extends StatefulWidget {
  const _RebuildStatsBanner({
    required this.controller,
    required this.onTap,
    required this.onPauseDiscarded,
  });

  final SleuthController controller;

  /// Called when the user taps `See all M →`. Reuses the same
  /// snapshot-and-push code path the rollup IssueCard used before
  /// v0.15.2 (`_FloatingIssuesCardState._onSeeAllRebuildsTap`), so the
  /// drilldown's snapshot semantics are unchanged.
  ///
  /// When the panel is paused, the banner passes its [_frozenCounts] map
  /// as [overrideCounts] so the drilldown opens against the same data the
  /// user is currently reading on the panel — without this, a paused
  /// panel showing N rebuilds would push a drilldown showing the live
  /// (unfrozen) count, which is the snapshot-drift bug fixed in v0.15.2.
  final void Function(Map<String, int>? overrideCounts) onTap;

  /// Called when the panel auto-resumes due to a route change while the
  /// user had it paused. The host card uses this to surface a transient
  /// "Pause cleared — route changed" snackbar so the user is never
  /// silently dropped from a frozen view back into live updates.
  final VoidCallback onPauseDiscarded;

  @override
  State<_RebuildStatsBanner> createState() => _RebuildStatsBannerState();
}

class _RebuildStatsBannerState extends State<_RebuildStatsBanner> {
  /// Collapsed by default per the v0.15.2 UX choice. The panel header
  /// stays one row tall when nothing surprising is happening; the user
  /// expands only when they want to inspect the breakdown.
  bool _expanded = false;

  /// True when the user has tapped Pause. Frozen counts in
  /// [_frozenCounts] are rendered instead of the live session map.
  bool _paused = false;

  /// Snapshot copy of `session.rebuildCountsByType` taken at the moment
  /// the user tapped Pause. Defensive copy so subsequent live mutations
  /// to the session map cannot reorder rows or change totals while the
  /// user is reading a frozen view. Cleared on Resume or on route change.
  Map<String, int>? _frozenCounts;

  /// F3/P3: Hoisted `Listenable.merge` so the panel attaches its
  /// listeners exactly once instead of allocating a fresh merge wrapper
  /// (which detaches and re-attaches both source listeners) on every
  /// build. The panel rebuilds frequently — once per scan tick plus
  /// once per route push/pop — so the per-build allocation showed up as
  /// pointless churn in the listener path. Field is `late final` and
  /// set in [initState] from the same two source notifiers that used
  /// to be merged inline in `build()`.
  late final Listenable _mergedListenable;

  @override
  void initState() {
    super.initState();
    _mergedListenable = Listenable.merge([
      widget.controller.scanTickNotifier,
      widget.controller.routeHistoryNotifier,
    ]);
    // Auto-resume on route change: a frozen view of route A's counts is
    // confusing once the user has navigated to route B. The panel's
    // listener clears the freeze the instant a new session is created,
    // so the new route's panel starts fresh in live mode without the
    // user having to manually tap Resume.
    widget.controller.routeHistoryNotifier.addListener(_onRouteSessionChanged);
  }

  @override
  void dispose() {
    widget.controller.routeHistoryNotifier.removeListener(
      _onRouteSessionChanged,
    );
    super.dispose();
  }

  void _onRouteSessionChanged() {
    if (!mounted) return;
    if (!_paused) return;
    setState(() {
      _paused = false;
      _frozenCounts = null;
    });
    // H2: notify the host card so it can surface a transient
    // "Pause cleared — route changed" snackbar. Without this signal the
    // user comes back from a tab swap to find their pause silently gone.
    widget.onPauseDiscarded();
  }

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
  }

  void _togglePause() {
    setState(() {
      if (_paused) {
        _paused = false;
        _frozenCounts = null;
        return;
      }
      final session = widget.controller.activeRouteSession;
      if (session == null) return;
      _frozenCounts = Map<String, int>.of(session.rebuildCountsByType);
      _paused = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SleuthListenableBuilder(
      // F3/P3: hoisted merge — see field declaration. Allocating
      // `Listenable.merge(...)` inline here would re-create the wrapper
      // on every build and detach/re-attach both source listeners.
      listenable: _mergedListenable,
      builder: (context) {
        final session = widget.controller.activeRouteSession;
        // H4: distinguish "no session" from "session exists but no
        // counts" — the latter is debug-info-worthy when the user is
        // expecting to see attribution. Both paths still suppress the
        // panel from view, but with explicit reasons rather than a
        // single silent SizedBox.shrink() that hides three different
        // failure modes (null session, empty map, zero total).
        if (session == null) return const SizedBox.shrink();
        final liveCounts = session.rebuildCountsByType;
        // Source-of-truth selection — frozen wins over live when paused.
        final counts = _paused && _frozenCounts != null
            ? _frozenCounts!
            : liveCounts;
        if (counts.isEmpty) return const SizedBox.shrink();
        final total = counts.values.fold<int>(0, (a, b) => a + b);
        if (total <= 0) return const SizedBox.shrink();
        final widgetCount = counts.length;

        // Sort once per build — counts are tiny (10s of entries at most)
        // so this is cheap. Top-3 lifted out of the same sorted list to
        // avoid a second pass.
        final sorted = counts.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final top = sorted.take(_topN).toList(growable: false);
        final topMax = top.isNotEmpty ? top.first.value : 0;

        final theme = SleuthTheme.of(context);
        final color = theme.categoryBuild;

        return DecoratedBox(
          decoration: BoxDecoration(color: color.withValues(alpha: 0.1)),
          // H1 compromise: tightened the panel's internal vertical
          // padding (4 → 2) and the header→rows spacer (8 → 2) to
          // reclaim the pixels spent on enlarged tap targets, so the
          // expanded panel still fits the cramped 330dp overlay budget.
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              theme.spacingSm,
              2,
              theme.spacingSm,
              2,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeaderRow(theme, color, total, widgetCount),
                if (_expanded) ...[
                  const SizedBox(height: 2),
                  for (var i = 0; i < top.length; i++)
                    _buildTopRow(
                      theme: theme,
                      color: color,
                      rank: i + 1,
                      typeName: top[i].key,
                      count: top[i].value,
                      barFraction: topMax == 0 ? 0.0 : top[i].value / topMax,
                    ),
                  _buildExpandedFooter(theme, color, widgetCount),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// v0.15.2 UX knob: the panel surfaces the top-3 rebuilders inline.
  /// The full list is reachable via the `See all M →` drilldown link.
  /// Three is the sweet spot for "scan-at-a-glance" — five rows turns
  /// the panel into a list and competes with the issue cards below it.
  static const int _topN = 3;

  Widget _buildHeaderRow(
    SleuthThemeData theme,
    Color color,
    int total,
    int widgetCount,
  ) {
    final widgetWord = widgetCount == 1 ? 'widget' : 'widgets';
    final summary = 'Rebuilds: $total across $widgetCount $widgetWord';
    final pausedHint = _paused ? ', paused' : '';
    final semanticsHint = _expanded
        ? '$summary$pausedHint, expanded, tap to collapse'
        : '$summary$pausedHint, collapsed, tap to expand';

    return Semantics(
      label: semanticsHint,
      button: true,
      // A full-width row at least 48 px tall; the banners scroll when the
      // card is short. `HitTestBehavior.opaque` makes every pixel of the
      // row hittable.
      child: GestureDetector(
        onTap: _toggleExpanded,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Icon(Icons.repeat, size: 12, color: color),
              SizedBox(width: theme.spacingXs),
              Expanded(
                child: Text(
                  summary,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: theme.fontSm,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // F1: pause indicator on the COLLAPSED header. Without
              // this, a user who pauses, collapses, and walks away has
              // no visual signal that the displayed total is frozen.
              if (!_expanded && _paused) ...[
                SizedBox(width: theme.spacingXxs),
                Icon(
                  Icons.pause,
                  size: 10,
                  color: color.withValues(
                    alpha: theme.badgeFillAlpha >= 1 ? 1 : 0.5,
                  ),
                ),
              ],
              if (_expanded) ...[
                Semantics(
                  label: _paused
                      ? 'Resume live rebuild updates'
                      : 'Pause live rebuild updates',
                  button: true,
                  // 48 x 48 hit box; the banners scroll when the card is
                  // short. `HitTestBehavior.opaque` is critical: without it
                  // the OUTER header GestureDetector would intercept
                  // the tap when the finger lands on the padding rather
                  // than on the icon glyph itself, toggling expansion
                  // instead of pause/resume.
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: GestureDetector(
                      onTap: _togglePause,
                      behavior: HitTestBehavior.opaque,
                      child: Center(
                        child: Icon(
                          _paused ? Icons.play_arrow : Icons.pause,
                          size: 14,
                          color: color,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
              Icon(
                _expanded ? Icons.expand_less : Icons.expand_more,
                size: 14,
                color: color.withValues(
                  alpha: theme.badgeFillAlpha >= 1 ? 1 : 0.7,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopRow({
    required SleuthThemeData theme,
    required Color color,
    required int rank,
    required String typeName,
    required int count,
    required double barFraction,
  }) {
    // H1 compromise: per-row bottom gap tightened from spacingXxs (4dp)
    // to 2dp so 3 rows reclaim 6dp toward the enlarged tap-target
    // budget. The bar still has visible separation thanks to the row's
    // intrinsic Text + bar layout.
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 18,
                child: Text(
                  '$rank.',
                  style: TextStyle(
                    color: theme.textTertiary,
                    fontSize: theme.fontXs,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  typeName,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: theme.fontSm,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(width: theme.spacingXs),
              // Animated count tween — when live counts move, the number
              // smoothly interpolates so eye-catching frames don't feel
              // like a glitch. 200ms matches Material's "short" duration
              // — long enough to read, short enough not to lag behind a
              // 1-second scan tick.
              //
              // F2: `IntTween(begin: 0, end: count)` is the canonical
              // pattern. On first appearance the row tweens from 0 → N;
              // on subsequent rebuilds with a different `end`,
              // TweenAnimationBuilder's `didUpdateWidget` substitutes
              // the current animated value as the new `begin` and
              // animates from the old end to the new one. The previous
              // `IntTween(begin: count, end: count)` form happened to
              // work because the substitution overwrites `begin`, but
              // it misled the reader and set the wrong starting value
              // when the row first appeared.
              TweenAnimationBuilder<int>(
                key: ValueKey(typeName),
                tween: IntTween(begin: 0, end: count),
                duration: motionDuration(
                  context,
                  const Duration(milliseconds: 200),
                ),
                builder: (context, value, _) => Text(
                  '\u00d7$value',
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: theme.fontSm,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          // H1 compromise: 1dp gap + 2dp bar (from 4dp + 3dp) reclaims
          // 4dp/row × 3 rows = 12dp toward the enlarged tap-target
          // budget. The bar is still a visible rule.
          const SizedBox(height: 1),
          Padding(
            padding: const EdgeInsets.only(left: 18),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 2,
                child: LinearProgressIndicator(
                  value: barFraction.clamp(0.0, 1.0),
                  backgroundColor: color.withValues(alpha: 0.15),
                  valueColor: AlwaysStoppedAnimation<Color>(color),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedFooter(
    SleuthThemeData theme,
    Color color,
    int widgetCount,
  ) {
    // C2: the "See all N →" link is only meaningful when the drilldown
    // would actually surface widgets that are NOT already shown inline.
    // With top-N = 3, a route with ≤ 3 widgets has nothing to drill into,
    // so the link is suppressed to avoid a redundant tap target.
    final showSeeAll = widgetCount > _topN;
    return SleuthTextScaleClamp(
      maxScaleFactor: kChromeMaxTextScale,
      child: _expandedFooterRow(theme, color, widgetCount, showSeeAll),
    );
  }

  Widget _expandedFooterRow(
    SleuthThemeData theme,
    Color color,
    int widgetCount,
    bool showSeeAll,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // KDD-5 inflation footnote — abbreviated form of the disclaimer
        // that the drilldown page renders in full. The inline panel only
        // has room for a one-liner; users who need the full caveat (and
        // the KDD-10 self-measurement note) tap through to the drilldown.
        Flexible(
          child: Text(
            'incl. inflations',
            style: TextStyle(
              color: theme.textTertiary,
              fontSize: theme.fontXxs,
              fontStyle: FontStyle.italic,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (showSeeAll) ...[
          SizedBox(width: theme.spacingSm),
          Semantics(
            label: 'See all $widgetCount rebuilds',
            button: true,
            // 48 px tall hit box. `HitTestBehavior.opaque` makes the
            // whole padded box receive taps even where the text doesn't
            // cover it.
            child: SizedBox(
              height: 48,
              child: GestureDetector(
                onTap: () {
                  // C1: pass the panel's frozen snapshot through to the
                  // drilldown when paused, so the drilldown opens against
                  // the same data the user is reading on the panel.
                  widget.onTap(_paused ? _frozenCounts : null);
                },
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: theme.spacingXs),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      'See all $widgetCount \u2192',
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: theme.fontXs,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor: theme.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
