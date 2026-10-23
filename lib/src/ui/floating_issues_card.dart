import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show GestureBinding, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../sleuth.dart' show Sleuth;
import '../analyzer/jank_relation.dart';
import '../controller/highlight_lookup.dart';
import '../controller/sleuth_controller.dart';
import '../models/performance_issue.dart';
import '../models/frame_stats.dart';
import 'issue_card.dart';
import 'issue_card_details.dart' show RebuildCause, RelatedLink;
import 'ai_chat_page.dart';
import 'issue_encyclopedia_page.dart';
import 'focus_ink_well.dart';
import 'more_menu.dart';
import 'guide_page.dart';
import 'rebuild_stats_page.dart';
import 'startup_metrics_page.dart';
import '../models/ai_chat_adapter.dart';
import '../utils/measurement_text.dart' show copyDetailsText;
import '../utils/ai_session_context.dart';
import '../utils/issue_explanation_builder.dart';
import '../utils/own_work_log.dart';
import '../vm/connection_mode.dart';
import 'hidden_issues_page.dart';
import 'overlay_filters.dart';
import 'highlight_bar.dart';
import 'issue_list_scroll_controller.dart';
import 'overlay_toast.dart';
import 'overlay_ui_state.dart';
import 'sleuth_listenable_builder.dart';
import 'sleuth_theme.dart';
import 'status_lines.dart';
import 'text_scale_clamp.dart';

export 'overlay_filters.dart'
    show
        applyOverlayFilters,
        computeVisibleIssues,
        hideKeyFor,
        isHiddenBy,
        listKeyFor,
        occurrenceKeysFor;

/// A card of the frozen zone ([applyFreezeZone]).
typedef FrozenCard = ({
  /// The key the card renders under, fixed when the zone is captured, so
  /// a card keeps its state when a twin ahead of it goes.
  String key,

  /// Its latest report, or the last one while it is not reported.
  PerformanceIssue issue,

  /// Whether the card is expanded.
  bool expanded,

  /// Whether the visible list held its report at the last match.
  bool reported,
});

/// Result of [applyFreezeZone].
typedef FrozenOrder = ({
  /// The cards in display order: the frozen zone, then the flow.
  List<PerformanceIssue> issues,

  /// The key of each card in [issues].
  List<String> keys,

  /// The frozen zone matched to the visible list, one entry per leading
  /// card of [issues]: the next call's `frozen`. Null when no card is
  /// expanded.
  List<FrozenCard>? frozen,
});

/// The card order while a card is expanded.
///
/// When the user expands a card, the cards from the top down to it are
/// captured as [frozen] and keep their order on later updates; the rest
/// of [visibleIssues] flows below them in its own order, so a new
/// critical arriving mid-read lands under the frozen zone. With several
/// cards expanded, the zone ends at the lowest one.
///
/// Each frozen card is matched to its report in [visibleIssues]: the same
/// [listKeyFor] and [PerformanceIssue.occurrenceId], and for twins with
/// no occurrence id, the next unclaimed one in order. Expanded cards claim
/// first. A matched card shows its latest report. An expanded card with no
/// report stays as last reported (`reported: false`) until the user
/// collapses it; a collapsed one leaves the zone, as do the collapsed
/// cards below the lowest expanded one.
///
/// Frozen cards render under their own keys; the flow takes
/// [occurrenceKeysFor] keys that skip them.
@visibleForTesting
FrozenOrder applyFreezeZone({
  required List<PerformanceIssue> visibleIssues,
  required List<FrozenCard>? frozen,
}) {
  final matched = frozen == null ? null : _matchFrozen(frozen, visibleIssues);
  final issues = <PerformanceIssue>[];
  final keys = <String>[];
  // By identity: PerformanceIssue equality compares stable ids, which
  // twins share.
  final shown = Set<PerformanceIssue>.identity();
  for (final card in matched ?? const <FrozenCard>[]) {
    issues.add(card.issue);
    keys.add(card.key);
    if (card.reported) shown.add(card.issue);
  }
  final used = keys.toSet();
  final counts = <String, int>{};
  for (final issue in visibleIssues) {
    if (shown.contains(issue)) continue;
    final base = listKeyFor(issue);
    var n = counts[base] ?? 0;
    String key;
    do {
      n++;
      key = n == 1 ? base : '$base#$n';
    } while (!used.add(key));
    counts[base] = n;
    issues.add(issue);
    keys.add(key);
  }
  return (issues: issues, keys: keys, frozen: matched);
}

List<FrozenCard>? _matchFrozen(
  List<FrozenCard> frozen,
  List<PerformanceIssue> visible,
) {
  var end = -1;
  for (var s = 0; s < frozen.length; s++) {
    if (frozen[s].expanded) end = s;
  }
  if (end < 0) return null;
  final byKey = <String, List<int>>{};
  for (var i = 0; i < visible.length; i++) {
    (byKey[listKeyFor(visible[i])] ??= []).add(i);
  }
  final claimed = <int>{};
  final match = List<int?>.filled(end + 1, null);
  for (final expandedFirst in const [true, false]) {
    for (var s = 0; s <= end; s++) {
      final known = frozen[s].issue;
      if (frozen[s].expanded != expandedFirst) continue;
      for (final i in byKey[listKeyFor(known)] ?? const <int>[]) {
        if (visible[i].occurrenceId == known.occurrenceId && claimed.add(i)) {
          match[s] = i;
          break;
        }
      }
    }
  }
  return [
    for (var s = 0; s <= end; s++)
      if (match[s] case final i?)
        (
          key: frozen[s].key,
          issue: visible[i],
          expanded: frozen[s].expanded,
          reported: true,
        )
      else if (frozen[s].expanded)
        (
          key: frozen[s].key,
          issue: frozen[s].issue,
          expanded: true,
          reported: false,
        ),
  ];
}

/// Result of [holdIssueOrder].
typedef HeldIssueOrder = ({
  /// The issues in display order.
  List<PerformanceIssue> issues,

  /// Distinct list keys in display order: the next call's `heldKeys`.
  List<String> keys,

  /// Severity per key: the next call's `heldSeverities`.
  Map<String, IssueSeverity> severities,

  /// Keys that were not in `heldKeys` (empty when nothing was held).
  Set<String> added,

  /// Whether the ranker's order differs from [keys] (new keys sit at the
  /// top until it is applied).
  bool pending,
});

/// The collapsed card order while the dashboard is open.
///
/// [visibleIssues] is the ranker's order; [heldKeys] the list keys
/// ([listKeyFor]) in the order the user sees, or null to adopt the
/// ranker's order. Held keys keep their order and keys that left drop
/// out. New keys go to the top, in ranker order; with [newAtTop] false
/// (a screen reader) each goes just above the first held key the ranker
/// places below it, so a new critical never lands under older warnings
/// while the held cards keep their order. When [promote] is true,
/// a key whose severity rose since [heldSeverities] moves at once, to
/// just above the first held key the ranker places below it, and only
/// when that is higher than where it sits. Any other difference from the
/// ranker's order, new keys' placement included, is reported as
/// `pending` for the host to apply in a quiet period. Issues sharing a
/// key stay together, in ranker order, on every call.
///
/// Runs before [applyFreezeZone]: the freeze snapshot captures the held
/// order, and new keys land at the top of the flow below the frozen
/// slice.
@visibleForTesting
HeldIssueOrder holdIssueOrder({
  required List<PerformanceIssue> visibleIssues,
  required List<String>? heldKeys,
  Map<String, IssueSeverity> heldSeverities = const {},
  bool promote = true,
  bool newAtTop = true,
}) {
  final byKey = <String, List<PerformanceIssue>>{};
  for (final issue in visibleIssues) {
    (byKey[listKeyFor(issue)] ??= <PerformanceIssue>[]).add(issue);
  }
  final rankKeys = byKey.keys.toList();
  final severities = <String, IssueSeverity>{
    for (final e in byKey.entries) e.key: e.value.first.severity,
  };
  if (heldKeys == null) {
    return (
      issues: [for (final k in rankKeys) ...byKey[k]!],
      keys: rankKeys,
      severities: severities,
      added: const <String>{},
      pending: false,
    );
  }

  final rankIndex = <String, int>{
    for (var i = 0; i < rankKeys.length; i++) rankKeys[i]: i,
  };
  final heldSet = heldKeys.toSet();
  final added = <String>{
    for (final k in rankKeys)
      if (!heldSet.contains(k)) k,
  };
  final kept = <String>[
    for (final k in heldKeys)
      if (byKey.containsKey(k)) k,
  ];
  if (promote) {
    final promoted = <String>[
      for (final k in kept)
        if (heldSeverities[k] case final before?
            when severities[k]!.index > before.index)
          k,
    ]..sort((a, b) => rankIndex[a]!.compareTo(rankIndex[b]!));
    for (final p in promoted) {
      final current = kept.indexOf(p);
      kept.removeAt(current);
      var at = kept.indexWhere((k) => rankIndex[k]! > rankIndex[p]!);
      if (at < 0) at = kept.length;
      // A promotion never moves a card down.
      kept.insert(at < current ? at : current, p);
    }
  }
  final List<String> keys;
  if (newAtTop) {
    keys = [
      for (final k in rankKeys)
        if (added.contains(k)) k,
      ...kept,
    ];
  } else {
    keys = [...kept];
    for (final k in rankKeys) {
      if (!added.contains(k)) continue;
      final at = keys.indexWhere((h) => rankIndex[h]! > rankIndex[k]!);
      keys.insert(at < 0 ? keys.length : at, k);
    }
  }
  return (
    issues: [for (final k in keys) ...byKey[k]!],
    keys: keys,
    severities: severities,
    added: added,
    pending: !listEquals(keys, rankKeys),
  );
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
  /// else closes the open full-screen page, else the Hidden list, else
  /// the More menu, else the highlight bar. Returns false when none of
  /// these is open.
  bool closeInnermostLayer();

  /// Number of full-screen layers (pages and the Hidden list) open above
  /// the card. Read from [FloatingIssuesCard.onLayersChanged].
  int get openLayerDepth;

  /// Whether the More menu is open inside the card. Read from
  /// [FloatingIssuesCard.onLayersChanged].
  bool get menuOpen;

  /// Ends the card's highlight (the bar, or a lookup still running) when
  /// the dashboard closes, so the outline goes with it.
  void endHighlight();
}

/// A full-screen layer over the card.
enum _OverlayLayer { hidden, guide, detail, chat, startup, rebuildStats }

/// Identity of an AI chat: the card's [listKeyFor] plus the issue's
/// [PerformanceIssue.occurrenceId]. Cards sharing a list key (one issue per
/// flagged element) keep separate chats; an issue without an occurrence
/// identity is keyed by its list key alone.
typedef _ChatKey = ({String listKey, int? occurrence});

_ChatKey _chatKeyFor(PerformanceIssue issue) =>
    (listKey: listKeyFor(issue), occurrence: issue.occurrenceId);

class _FloatingIssuesCardState extends State<FloatingIssuesCard>
    implements OverlayLayerHost {
  OverlayUiState get _ui => widget.controller.overlayUiState;

  /// Drag offset — applied via inner [Positioned], null until first build.
  /// Seeded from [OverlayUiState.cardOffset]; written back on drag end.
  Offset? _cardOffset;

  /// The frozen zone while a card is expanded ([applyFreezeZone]), null
  /// otherwise: the cards from the top down to the lowest expanded one,
  /// each with the key it renders under and its latest report.
  ///
  /// Captured from the list the user saw when they tapped (the build's
  /// list, not a newer notifier value), so the zone holds the rows that
  /// were on screen. Matched to each new visible list by
  /// [_pruneStaleState] and the list build; released when the last card
  /// collapses.
  List<FrozenCard>? _frozen;

  /// Key of the card whose crosshair is on, as it rendered when tapped.
  String? _selectedIssueId;

  /// The issue of the card whose crosshair is on. A card with an
  /// occurrence id is found by it ([_isSelectedCard]), as a twin ahead of
  /// it going renumbers the flow's keys.
  PerformanceIssue? _selectedIssue;

  /// The selected issue's widget is outlined, and the card has shrunk to
  /// [SleuthHighlightBar] until Back to issues, close, or the issue goes.
  /// The window state, size and list offset stay as they were, and none
  /// of it is written to [OverlayUiState]. With [_selectedIssue] set and
  /// this false, the lookup is pending (Finding).
  bool _barOpen = false;

  /// The bar sat at the top of the screen when its widget was last on
  /// screen; while the widget is off screen it stays there.
  bool _barAtTop = false;

  final FocusNode _barBackFocus = FocusNode(
    debugLabel: 'Sleuth Back to issues',
  );

  /// Where the card was when the bar replaced it, held for a double tap's
  /// span so the second tap of a double tap on the crosshair does not
  /// reach the app below.
  Rect? _barShield;
  Timer? _barShieldTimer;

  /// The card whose crosshair takes focus once the bar closes, found as
  /// [_isCardOf] finds it (its key can change while the bar is up), the
  /// epoch that asks it to, and whether keyboard focus goes with it.
  PerformanceIssue? _crosshairFocusIssue;
  String? _crosshairFocusKey;

  /// The target card started its scroll; the host clears the target when
  /// the scroll ends rather than after the first frame.
  bool _crosshairFocusStarted = false;
  int _crosshairFocusEpoch = 0;
  bool _crosshairKeyboardFocus = false;

  /// Bumped when the host clears every expansion at once (severity filter
  /// change); [IssueCard] collapses without calling back.
  int _collapseEpoch = 0;

  /// The card a related row opens, until it has scrolled into view, and
  /// the epoch that asks it to. [_revealInline] is the folded issue it
  /// opens inline, if any.
  String? _revealKey;
  PerformanceIssue? _revealInline;
  int _revealEpoch = 0;

  /// The pending card began scrolling into view; the list stays built
  /// until the scroll ends.
  bool _revealStarted = false;

  /// The card that takes focus after a Hide, and the epoch that asks it to.
  String? _focusKey;
  int _focusEpoch = 0;
  bool _focusStarted = false;

  /// Set while a toast's Show turns a severity on, so that change keeps
  /// the expanded cards.
  bool _keepExpansionsOnFilter = false;

  /// The toast marking an issue not useful, which unmarking takes back.
  OverlayToastModel? _notUsefulToast;

  /// The cards and keys the list last built.
  List<PerformanceIssue> _shownIssues = const [];
  List<String> _shownKeys = const [];

  /// Severity filter seen by the last [_onUiStateChanged].
  Set<IssueSeverity> _lastSeverityFilter = const {};

  /// Hidden keys seen by the last [_onUiStateChanged].
  Set<String> _lastHiddenKeys = const {};

  /// Collapsed card order held while the dashboard is open (see
  /// [holdIssueOrder]): list keys in display order, or null to adopt the
  /// ranker's order on the next build. Reset when the dashboard opens
  /// (a new State), on a severity filter change, and on hide or unhide.
  List<String>? _heldKeys;
  Map<String, IssueSeverity> _heldSeverities = const {};

  /// Applies a pending rank change after [_quietPeriod] without a touch
  /// on the list. Runs only while a change is pending.
  Timer? _quietTimer;
  static const Duration _quietPeriod = Duration(seconds: 10);

  /// Pointers down on the list; the quiet timer waits for them to lift.
  int _pointersDown = 0;

  /// Whether the list was scrolled to the top at its last scroll
  /// notification. A pending change applies only there.
  bool _listAtTop = true;

  /// A screen reader is running (accessible navigation or semantics on):
  /// held cards change order only on open, a filter change, or hide and
  /// unhide; a new card enters at its rank position. Set each build.
  bool _screenReader = false;

  /// Cards that entered the held list recently, each drawn with a wider
  /// source accent for [_newCardAccent] from its own arrival.
  final Map<String, Timer> _newKeyTimers = {};
  static const Duration _newCardAccent = Duration(seconds: 2);

  final OverlayToastController _toast = OverlayToastController();

  /// Open layers reported through [FloatingIssuesCard.onLayersChanged].
  Set<_OverlayLayer> _reportedLayers = const {};

  /// Focus scope of each full-screen layer, focused when the layer opens
  /// so keys and traversal stay on the page.
  final Map<_OverlayLayer, FocusScopeNode> _layerScopes = {};

  /// [listKeyFor] occurrence key of the issue card whose Learn more or Ask
  /// AI opened the open layer; null for every other opener. Screen reader
  /// focus returns to that card, else to the header, when the layer
  /// closes.
  String? _layerOpener;

  /// The header's semantics node: screen reader focus lands there when
  /// the dashboard opens.
  final GlobalKey _headerKey = GlobalKey(debugLabel: 'Sleuth header');

  /// The More menu, open inside the card over a scrim, and what it shows,
  /// read when it opened.
  bool _menuOpen = false;
  MoreMenuValues? _menuValues;

  /// Menu open state reported through [FloatingIssuesCard.onLayersChanged].
  bool _reportedMenuOpen = false;

  /// Keeps keyboard focus in the menu while it is open.
  final FocusScopeNode _menuScope = FocusScopeNode(
    debugLabel: 'Sleuth More menu',
  );

  /// The More button's focus and semantics node: focus returns there
  /// when the menu, or a page opened from it, closes.
  final FocusNode _moreFocus = FocusNode(debugLabel: 'Sleuth More');
  final GlobalKey _moreKey = GlobalKey(debugLabel: 'Sleuth More');

  /// The menu panel's semantics node, which takes screen reader focus
  /// when the menu opens.
  final GlobalKey _menuKey = GlobalKey(debugLabel: 'Sleuth More menu');

  /// The first severity chip, which takes screen reader focus when Show
  /// all or Reset, the control that held it, goes away.
  final GlobalKey _firstChipKey = GlobalKey(debugLabel: 'Sleuth chip');

  /// The card with its grip and menu; a pointer down outside it closes the
  /// menu.
  final GlobalKey _cardKey = GlobalKey(debugLabel: 'Sleuth card');

  /// [_layerOpener] value of a page opened from the More menu.
  static const String _moreOpener = 'Sleuth More';

  /// Scroll position of the issue list, kept while a page covers the card
  /// (the list unmounts under it).
  final IssueListScrollController _listScroll = IssueListScrollController();

  /// Accessible navigation as of the last build; with
  /// [SemanticsBinding.semanticsEnabled] it sets the toast timing.
  bool _accessibleNavigation = false;

  bool _showHidden = false;

  /// A snapshot copy is running; another tap is ignored until it ends.
  bool _copyInFlight = false;
  bool _showGuide = false;
  bool _showDetail = false;
  bool _showStartupDetail = false;
  bool _showRebuildStats = false;
  // Snapshot captured at tap time so mutations to the live session
  // (from background scans) don't shuffle rows while the drilldown is open.
  // The drilldown is a snapshot taken at open, not live.
  Map<String, int>? _rebuildStatsSnapshot;
  String? _rebuildStatsRouteName;
  String? _detailStableId;
  PerformanceIssue? _detailContextIssue;
  bool _showAiChat = false;
  _ChatKey? _chatIssueKey;

  /// Chat conversations, held by the controller so they outlive the card
  /// (closing the dashboard unmounts it).
  Map<Object, List<AiChatMessage>> get _chatHistories =>
      widget.controller.aiChatHistories;

  /// Keys of the reported issues that carry the Jank tag.
  Set<String> _cachedJankKeys = const {};

  /// Fires when the first held jank cause leaves the controller's hold.
  Timer? _jankHoldTimer;

  double _cardWidth = _defaultCardWidth;
  static const double _defaultCardWidth = 320;
  static const double _minCardWidth = 320;
  static const double _minCardHeight = 300;

  /// Smallest card width on a screen of [size] with safe area [safe]:
  /// [_minCardWidth], or the safe area minus 16 px margins when that is
  /// narrower.
  static double _minWidthFor(Size size, EdgeInsets safe) =>
      math.max(0.0, math.min(_minCardWidth, size.width - safe.horizontal - 32));

  /// [_minWidthFor] the screen of the last build; 0 before it.
  double _cachedMinWidth = 0;

  /// Height of the minimized card: the 48 px header row.
  static const double _minimizedHeight = 48;

  /// Height of a header or footer control row.
  static const double _controlRowHeight = 48;

  /// Height of the card header.
  static const double _headerHeight = _controlRowHeight;

  /// Smallest height of the status row at [chromeScale], with the divider
  /// below it.
  static double _statusHeightFor(double chromeScale) =>
      _controlRowHeight * chromeScale + 1;

  // ─── Window state ──────────────────────────────────────────────────
  CardWindowState _windowState = CardWindowState.normal;

  /// Stored when transitioning away from normal so restore is exact.
  /// Drag while minimized does NOT update these — restore always returns
  /// to the position the card was in when minimize/maximize was tapped.
  Offset? _preTransitionOffset;
  double? _preTransitionWidth;
  double? _preTransitionHeight;

  /// User-set card height. Null = default (55% of screen).
  double? _cardHeight;

  /// Screen size and safe area the maximized card's offset and width were
  /// fitted to; null when not fitted yet (a maximized state read from the
  /// store). A rotation or a different window refits them in build.
  (Size, EdgeInsets)? _maximizedFor;

  // Cached for gesture handlers (set each build).
  EdgeInsets _cachedSafePadding = EdgeInsets.zero;
  double _cachedEffectiveWidth = 0;
  double _cachedKeyboardHeight = 0;

  /// Shown height of the card, and the floor and ceiling of a normal
  /// card's shown height, as of the last build.
  double _cachedCardHeight = 0;
  double _cachedMinHeight = 0;
  double _cachedMaxHeight = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.verdictNotifier.addListener(_onVerdictChanged);
    widget.controller.issuesNotifier.addListener(_onIssuesChanged);
    widget.controller.selectedHighlightNotifier.addListener(_onBarTarget);
    _ui.addListener(_onUiStateChanged);
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
    SemanticsBinding.instance.addSemanticsEnabledListener(_syncToastTiming);
    _readGeometry();
    _lastSeverityFilter = {..._ui.severityFilter};
    _lastHiddenKeys = {..._ui.hiddenKeys};
    _onVerdictChanged();
    // The trigger that opened the dashboard is gone; a screen reader
    // continues at the card's header.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && openLayerDepth == 0) _focusSemantics(_headerKey);
    });
  }

  /// [OverlayUiState]'s geometry when the card last read or wrote it. A
  /// different value seen in [_onUiStateChanged] was set elsewhere (a
  /// store read that finished after the card opened) and is adopted.
  Object? _seenGeometry;

  /// True while [_commitGeometry] writes, so its own change is not
  /// read back.
  bool _committingGeometry = false;

  Object _uiGeometry() {
    final ui = _ui;
    return (
      ui.cardOffset,
      ui.cardWidth,
      ui.cardHeight,
      ui.windowState,
      ui.restoreOffset,
      ui.restoreWidth,
      ui.restoreHeight,
    );
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
    _maximizedFor = null;
    _seenGeometry = _uiGeometry();
  }

  /// Writes the local geometry to [OverlayUiState]: once per drag end,
  /// resize end, or window-state change.
  void _commitGeometry() {
    // A width stored below the minimum (an older release allowed 220 px)
    // is raised here and at layout, not when the state is read.
    final minWidth = _cachedMinWidth;
    if (_cardWidth < minWidth) _cardWidth = minWidth;
    final restoreWidth = _preTransitionWidth;
    if (restoreWidth != null && restoreWidth < minWidth) {
      _preTransitionWidth = minWidth;
    }
    _committingGeometry = true;
    try {
      _ui.setCardGeometry(
        offset: _cardOffset,
        width: _cardWidth,
        height: _cardHeight,
        windowState: _windowState,
        restoreOffset: _preTransitionOffset,
        restoreWidth: _preTransitionWidth,
        restoreHeight: _preTransitionHeight,
      );
    } finally {
      _committingGeometry = false;
    }
    _seenGeometry = _uiGeometry();
  }

  /// Hidden keys or the severity filter changed. A filter change clears
  /// every expansion together with the freeze snapshot; then stale state
  /// is pruned against the new visible list.
  void _onUiStateChanged() {
    if (!mounted) return;
    if (!_committingGeometry && _uiGeometry() != _seenGeometry) {
      _readGeometry();
    }
    final filter = _ui.severityFilter;
    if (!setEquals(filter, _lastSeverityFilter)) {
      _lastSeverityFilter = {...filter};
      _releaseHeldOrder();
      if (_keepExpansionsOnFilter) {
        _keepExpansionsOnFilter = false;
      } else if (_frozen != null) {
        _frozen = null;
        _collapseEpoch++;
      }
    }
    final hidden = _ui.hiddenKeys;
    if (!setEquals(hidden, _lastHiddenKeys)) {
      _lastHiddenKeys = {...hidden};
      _releaseHeldOrder();
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
    // Without this, `_frozen` and listeners
    // would reference the old controller's issue ids and notifiers.
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.verdictNotifier.removeListener(_onVerdictChanged);
      oldWidget.controller.issuesNotifier.removeListener(_onIssuesChanged);
      oldWidget.controller.selectedHighlightNotifier.removeListener(
        _onBarTarget,
      );
      oldWidget.controller.overlayUiState.removeListener(_onUiStateChanged);
      widget.controller.verdictNotifier.addListener(_onVerdictChanged);
      widget.controller.issuesNotifier.addListener(_onIssuesChanged);
      widget.controller.selectedHighlightNotifier.addListener(_onBarTarget);
      widget.controller.overlayUiState.addListener(_onUiStateChanged);
      _readGeometry();
      _lastSeverityFilter = {..._ui.severityFilter};
      _lastHiddenKeys = {..._ui.hiddenKeys};
      _releaseHeldOrder();
      _frozen = null;
      _selectedIssueId = null;
      _selectedIssue = null;
      _barOpen = false;
      _showAiChat = false;
      _chatIssueKey = null;
      _chatIssue = null;
      _cachedJankKeys = const {};
      _onVerdictChanged();
    }
  }

  /// Escape closes the innermost layer, then the card. Runs before focus
  /// dispatch, so no focus is taken from the app. With only the card
  /// open, the key event still reaches the app's focused widget
  /// afterwards, so Escape is left to the app when its focus is in a text
  /// field or in a dismissible route (a dialog or sheet closes on Escape
  /// through `DismissIntent`). With a page or the Hidden list open the
  /// app holds no focus, and Escape always closes the layer; the menu and
  /// the highlight bar also take it, as system back does.
  bool _onKeyEvent(KeyEvent event) {
    if (!mounted || event is KeyUpEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) {
      return _moveOrActivate(event);
    }
    if (event is! KeyDownEvent) return false;
    if (openLayerDepth == 0 && !_menuOpen && !_barOpen && _appTakesEscape()) {
      return false;
    }
    if (!closeInnermostLayer()) widget.onClose();
    return true;
  }

  static final _activateKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
  };

  /// Tab and Shift+Tab move focus, and Enter and Space activate the
  /// focused control, while focus is in the card. The overlay sits above
  /// the app's `WidgetsApp`, whose default shortcuts therefore never reach
  /// it; a card hosted inside a `WidgetsApp` leaves the keys to those
  /// shortcuts. A focused text field keeps Enter and Space.
  bool _moveOrActivate(KeyEvent event) {
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    if (focus == null ||
        focusContext == null ||
        !focusContext.mounted ||
        focusContext.findAncestorStateOfType<_FloatingIssuesCardState>() !=
            this ||
        focusContext.findAncestorWidgetOfExactType<WidgetsApp>() != null) {
      return false;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.tab) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        focus.previousFocus();
      } else {
        focus.nextFocus();
      }
      return true;
    }
    if (event is! KeyDownEvent ||
        !_activateKeys.contains(key) ||
        focusContext.findAncestorWidgetOfExactType<EditableText>() != null) {
      return false;
    }
    const intent = ActivateIntent();
    final action = Actions.maybeFind<ActivateIntent>(focusContext);
    if (action == null || !action.isEnabled(intent)) return false;
    Actions.invoke(focusContext, intent);
    return true;
  }

  /// Whether the app's focused widget handles Escape itself. The route
  /// lookup subscribes the focused element to its route: 3.32 has no
  /// route lookup without a dependency, so it runs last.
  bool _appTakesEscape() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext != null &&
        focusContext.mounted &&
        focusContext.findAncestorStateOfType<_FloatingIssuesCardState>() !=
            this &&
        (focusContext.findAncestorWidgetOfExactType<EditableText>() != null ||
            (ModalRoute.of(focusContext)?.barrierDismissible ?? false));
  }

  @override
  void dispose() {
    if (_menuOpen) {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    }
    _menuScope.dispose();
    _moreFocus.dispose();
    _barBackFocus.dispose();
    _barShieldTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    SemanticsBinding.instance.removeSemanticsEnabledListener(_syncToastTiming);
    widget.controller.verdictNotifier.removeListener(_onVerdictChanged);
    widget.controller.issuesNotifier.removeListener(_onIssuesChanged);
    widget.controller.selectedHighlightNotifier.removeListener(_onBarTarget);
    widget.controller.overlayUiState.removeListener(_onUiStateChanged);
    _toast.dispose();
    _listScroll.dispose();
    for (final scope in _layerScopes.values) {
      scope.dispose();
    }
    _quietTimer?.cancel();
    for (final timer in _newKeyTimers.values) {
      timer.cancel();
    }
    _newKeyTimers.clear();
    _jankHoldTimer?.cancel();
    _preTransitionOffset = null;
    _preTransitionWidth = null;
    _preTransitionHeight = null;
    _frozen = null;
    super.dispose();
  }

  // ─── Held card order ───────────────────────────────────────────────

  /// Drops the held order: the next build adopts the ranker's order.
  void _releaseHeldOrder() {
    _heldKeys = null;
    _quietTimer?.cancel();
    _quietTimer = null;
  }

  /// Records the order [held] put on screen and schedules a pending
  /// change (never under a screen reader). Called while building the
  /// list.
  void _recordHeldOrder(HeldIssueOrder held) {
    _heldKeys = held.keys;
    _heldSeverities = held.severities;
    if (!held.pending || _screenReader) {
      _quietTimer?.cancel();
      _quietTimer = null;
    } else if (_quietTimer == null) {
      _armQuietTimer();
    }
    for (final key in held.added) {
      _newKeyTimers[key]?.cancel();
      _newKeyTimers[key] = Timer(_newCardAccent, () {
        if (_newKeyTimers.remove(key) != null && mounted) setState(() {});
      });
    }
    // Cards that left the list drop their accent.
    if (_newKeyTimers.isNotEmpty) {
      final present = held.keys.toSet();
      _newKeyTimers.removeWhere((key, timer) {
        if (present.contains(key)) return false;
        timer.cancel();
        return true;
      });
    }
  }

  void _armQuietTimer() {
    _quietTimer?.cancel();
    _quietTimer = Timer(_quietPeriod, _onQuietPeriod);
  }

  /// Applies the pending change, unless a finger is down or the list is
  /// scrolled away from the top: then it waits for the next quiet period.
  void _onQuietPeriod() {
    _quietTimer = null;
    if (!mounted ||
        _screenReader ||
        SemanticsBinding.instance.semanticsEnabled) {
      return;
    }
    if (_pointersDown > 0 || !_listAtTop) {
      _armQuietTimer();
      return;
    }
    setState(_releaseHeldOrder);
  }

  /// A touch, drag, wheel, trackpad gesture or scroll on the list
  /// restarts the quiet period of a pending change.
  void _onListActivity() {
    if (_quietTimer != null) _armQuietTimer();
  }

  bool _onListScroll(ScrollNotification notification) {
    if (notification.depth == 0) {
      _listAtTop = notification.metrics.pixels <= 0;
      _onListActivity();
    }
    return false;
  }

  void _onListPointerDown(PointerDownEvent _) {
    _pointersDown++;
    _onListActivity();
  }

  void _onListPointerUp(PointerEvent _) {
    if (_pointersDown > 0) _pointersDown--;
    _onListActivity();
  }

  // ─── Window controls ───────────────────────────────────────────────

  void _minimize() {
    if (_windowState == CardWindowState.minimized) return;
    _closeMenu(refocus: false);
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
    _closeMenu(refocus: false);
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.viewPaddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    setState(() {
      _preTransitionOffset ??= _cardOffset;
      _preTransitionWidth ??= _cardWidth;
      _preTransitionHeight ??= _cardHeight;
      _windowState = CardWindowState.maximized;
      _fitMaximized(size, safe);
      _cardHeight = _maximizedHeight(size, safe, keyboard);
    });
    _commitGeometry();
  }

  /// Places the maximized card in the safe area of [size] with a 16 px
  /// margin.
  void _fitMaximized(Size size, EdgeInsets safe) {
    _cardOffset = Offset(safe.left + 16, safe.top + 16);
    _cardWidth = math.max(0.0, size.width - safe.horizontal - 32);
    _maximizedFor = (size, safe);
  }

  /// Height of the maximized card: the safe area minus margins, above the
  /// keyboard.
  static double _maximizedHeight(Size size, EdgeInsets safe, double keyboard) =>
      math.max(
        0.0,
        size.height - safe.top - 32 - math.max(safe.bottom, keyboard),
      );

  void _restore() {
    _closeMenu(refocus: false);
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
  int get openLayerDepth => _openLayers().length;

  Set<_OverlayLayer> _openLayers() => {
    if (_showHidden) _OverlayLayer.hidden,
    if (_showGuide) _OverlayLayer.guide,
    if (_showDetail) _OverlayLayer.detail,
    if (_showAiChat) _OverlayLayer.chat,
    if (_showStartupDetail) _OverlayLayer.startup,
    if (_showRebuildStats) _OverlayLayer.rebuildStats,
  };

  /// Runs after the layer change has been reported: [opened] (when
  /// given) takes focus, so the app's focus leaves for the page; with
  /// every layer closed, a screen reader goes back to the opener.
  void _afterLayersChanged(_OverlayLayer? opened) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (opened != null) {
        if (_openLayers().contains(opened)) {
          _layerScopes[opened]?.requestFocus();
        }
      } else if (openLayerDepth == 0) {
        _refocusOpener();
      }
    });
  }

  /// Moves screen reader focus to the issue card that opened the closed
  /// layer, else to the header. Input focus is the app's (see
  /// `SleuthOverlay`), so only the accessibility focus moves.
  void _refocusOpener() {
    final opener = _layerOpener;
    _layerOpener = null;
    if (opener == _moreOpener) {
      _focusSemantics(_moreKey);
      // Keyboard focus goes back to More unless something holds it; the
      // overlay gives an app node that had focus its focus back.
      final focus = FocusManager.instance.primaryFocus;
      if (focus == null || focus is FocusScopeNode) _moreFocus.requestFocus();
      return;
    }
    RenderObject? target;
    if (opener != null) {
      final wanted = ValueKey<String>(opener);
      void visit(Element element) {
        if (target != null) return;
        if (element.widget is IssueCard && element.widget.key == wanted) {
          target = element.renderObject;
          return;
        }
        element.visitChildElements(visit);
      }

      context.visitChildElements(visit);
    }
    if (target == null) {
      _focusSemantics(_headerKey);
    } else {
      target!.sendSemanticsEvent(const FocusSemanticEvent());
    }
  }

  /// Asks the platform screen reader to move to [key]'s semantics node.
  static void _focusSemantics(GlobalKey key) => key.currentContext
      ?.findRenderObject()
      ?.sendSemanticsEvent(const FocusSemanticEvent());

  /// Toasts stay three times longer, and an Undo toast waits to be used
  /// or dismissed, while a screen reader or another assistive service is
  /// on: accessible navigation, or semantics enabled (switch access,
  /// voice control).
  void _syncToastTiming() {
    final assisted =
        _accessibleNavigation || SemanticsBinding.instance.semanticsEnabled;
    _toast
      ..durationScale = assisted ? 3 : 1
      ..holdActions = assisted;
  }

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
    } else if (_menuOpen) {
      _closeMenu();
    } else if (_barOpen) {
      _leaveBar();
    } else {
      return false;
    }
    return true;
  }

  @override
  void endHighlight() => _endHighlight();

  // ─── More menu ─────────────────────────────────────────────────────

  @override
  bool get menuOpen => _menuOpen;

  void _toggleMenu() => _menuOpen ? _closeMenu() : _openMenu();

  /// Opens the menu with the startup time, the route's rebuild count and
  /// the hidden count as they are now. A pointer down outside the card
  /// closes it again (see [_onGlobalPointer]).
  void _openMenu() {
    if (_menuOpen) return;
    final counts = widget.controller.activeRouteSession?.rebuildCountsByType;
    final rebuilds = counts == null
        ? 0
        : counts.values.fold<int>(0, (a, b) => a + b);
    setState(() {
      _menuOpen = true;
      _menuValues = (
        ttffMs: Sleuth.startupMetrics?.ttffMs,
        rebuildTotal: rebuilds > 0 ? rebuilds : null,
        rebuildCounting: widget.controller.countsRouteRebuilds,
        hiddenCount:
            _ui.hiddenKeys.length +
            widget.controller.suppressedCountNotifier.value,
      );
    });
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onGlobalPointer);
    // Keyboard focus moves into the panel, from the app too: autofocus
    // alone does not take focus another scope holds.
    // The first enabled row takes keyboard focus, so Enter acts at once,
    // and the screen reader moves to the panel.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_menuOpen) return;
      _menuScope.requestFocus();
      _menuScope.nextFocus();
      _focusSemantics(_menuKey);
    });
  }

  /// Closes the menu. With [refocus], keyboard and screen reader focus
  /// return to the More button; a tap that closed it elsewhere keeps its
  /// own focus.
  void _closeMenu({bool refocus = true}) {
    if (!_menuOpen) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onGlobalPointer);
    setState(() {
      _menuOpen = false;
      _menuValues = null;
    });
    if (refocus) {
      _focusMore();
    } else if (_menuScope.hasFocus) {
      _menuScope.unfocus();
    }
  }

  /// Moves keyboard and screen reader focus to the More button.
  void _focusMore() {
    _moreFocus.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusSemantics(_moreKey);
    });
  }

  /// A pointer down on the app closes the menu and still reaches the app;
  /// the route exists only while the menu is open. A pointer down on the
  /// card is left to the scrim and the header.
  void _onGlobalPointer(PointerEvent event) {
    if (event is! PointerDownEvent || !_menuOpen) return;
    final box = _cardKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      final local = box.globalToLocal(event.position);
      if ((Offset.zero & box.size).contains(local)) return;
    }
    _closeMenu(refocus: false);
  }

  /// Turns every severity back on and moves screen reader focus to the
  /// first chip, since the Show all or Reset control that held it goes.
  void _showAllSeverities() {
    _ui.resetSeverityFilter();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusSemantics(_firstChipKey);
    });
  }

  /// Closes the menu, then opens a page with More recorded as the opener.
  void _openFromMenu(VoidCallback open) {
    _closeMenu(refocus: false);
    setState(() {
      open();
      _layerOpener = _moreOpener;
    });
  }

  void _closeAiChat() => setState(() {
    _showAiChat = false;
    _chatIssueKey = null;
    _chatIssue = null;
  });

  /// The open chat's issue as last reported, so the page outlives an
  /// issue that stops being reported mid-conversation.
  PerformanceIssue? _chatIssue;

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
  /// already collapsed through `onExpandedChanged(false)`; the prune that
  /// the hide triggers drops its highlight.
  Listenable? _statusSources;
  SleuthController? _statusSourcesController;

  /// Run state and coverage of the current controller, merged once.
  Listenable _statusListenable() {
    final c = widget.controller;
    if (_statusSources == null || !identical(c, _statusSourcesController)) {
      _statusSources = Listenable.merge([
        c.runStateNotifier,
        c.coverageNotifier,
      ]);
      _statusSourcesController = c;
    }
    return _statusSources!;
  }

  /// A manual reconnect from the status line is running.
  bool _reconnecting = false;

  /// The status line: in place of an empty list for every state, above
  /// the cards only while the VM link is lost.
  Widget _statusLine({required bool emptyList}) => SleuthListenableBuilder(
    listenable: _statusListenable(),
    builder: (context) {
      final controller = widget.controller;
      final run = controller.runStateNotifier.value;
      final kind = statusKindOf(run);
      final lost =
          kind == SleuthStatusKind.vmLost ||
          kind == SleuthStatusKind.stoppedRetrying;
      if (!emptyList && !lost) return const SizedBox.shrink();
      final box = SleuthStatusBox(
        key: _statusKey,
        kind: kind,
        run: run,
        coverage: controller.coverageNotifier.value,
        initializedAt: controller.initializedAt,
        warmupDuration: controller.config.frameTimingWarmupDuration,
        onCopyCommand: () => _copyText(sleuthRunCommand, 'Command copied'),
        onReconnect: run.stoppedRetrying && !run.vmConnected
            ? _reconnect
            : null,
        reconnecting: _reconnecting,
      );
      final guide =
          emptyList &&
          (kind == SleuthStatusKind.warmingUp || kind == SleuthStatusKind.noVm);
      if (!guide) return box;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          box,
          SleuthGuideLink(
            onOpen: () => setState(() {
              _showGuide = true;
              _layerOpener = null;
            }),
          ),
        ],
      );
    },
  );

  /// Reconnects by hand. Success moves the screen reader to the status
  /// line; a failure says so.
  Future<void> _reconnect() async {
    if (_reconnecting) return;
    final keyboard = _focusInCard();
    setState(() => _reconnecting = true);
    final ok = await widget.controller.reconnect();
    if (!mounted) return;
    setState(() => _reconnecting = false);
    if (ok) {
      // Reconnect is gone; with cards listed the whole line is, and the
      // header takes the screen reader instead.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (keyboard) _moreFocus.requestFocus();
        _focusSemantics(
          _statusKey.currentContext == null ? _headerKey : _statusKey,
        );
      });
    } else {
      _toast.show(
        "Couldn't reconnect. Restart the app with $sleuthRunCommand.",
        tone: OverlayToastTone.warning,
      );
    }
  }

  /// Dismisses the debug banner for the session; focus moves to the
  /// chips.
  void _dismissDebugBanner() {
    setState(() => widget.controller.debugBannerDismissed = true);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _focusSemantics(_firstChipKey),
    );
  }

  final GlobalKey _statusKey = GlobalKey(debugLabel: 'status line');

  /// Hides [issue]'s card, shown at [index], and moves focus to the card
  /// that takes its place. A card no longer reported cannot come back, so
  /// its toast offers no Undo.
  void _hideIssue(PerformanceIssue issue, {int? index, bool stale = false}) {
    final key = hideKeyFor(issue);
    _ui.hide(key);
    if (stale) {
      _toast.show('Issue hidden');
    } else {
      _toast.show(
        'Issue hidden',
        actionLabel: 'Undo',
        onAction: () => _ui.unhide(key),
      );
    }
    if (index != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final keys = _shownKeys;
        if (keys.isEmpty) {
          _focusSemantics(_headerKey);
          return;
        }
        final key = keys[math.min(index, keys.length - 1)];
        setState(() {
          _focusKey = key;
          _focusStarted = false;
          _focusEpoch++;
        });
        // The list builds every card while focus is pending; a card that
        // did not take it in the next frame is not coming.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          scheduleMicrotask(() {
            if (mounted && _focusKey == key && !_focusStarted) {
              setState(() => _focusKey = null);
            }
          });
        });
      });
    }
  }

  /// Shows every hidden card again and offers Undo, which hides the same
  /// keys again in their original order.
  void _restoreAllHidden() {
    final keys = _ui.hiddenKeys.toList();
    if (keys.isEmpty) return;
    _ui.restoreAll();
    _toast.show(
      keys.length == 1 ? '1 issue restored' : '${keys.length} issues restored',
      actionLabel: 'Undo',
      onAction: () {
        for (final key in keys) {
          _ui.hide(key);
        }
      },
    );
  }

  Future<void> _copyIssue(PerformanceIssue issue) =>
      _copyText(copyDetailsText(issue), 'Copied');

  /// Copies [text] and confirms with [confirmation], or says it failed.
  Future<void> _copyText(String text, String confirmation) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } catch (e) {
      debugPrint('Sleuth: copy failed: $e');
      if (mounted) {
        _toast.show("Couldn't copy", tone: OverlayToastTone.warning);
      }
      return;
    }
    unawaited(HapticFeedback.selectionClick().catchError((Object _) {}));
    if (mounted) _toast.show(confirmation);
  }

  /// Marks [issue] not useful, which exports and MCP output carry, or
  /// removes the mark without a toast.
  void _setNotUseful(PerformanceIssue issue, bool marked) {
    final controller = widget.controller;
    if (marked) {
      controller.markNotUseful(issue);
      _toast.show(
        'Marked not useful. Exports and MCP output include the mark.',
      );
      _notUsefulToast = _toast.value;
    } else {
      controller.clearNotUseful(listKeyFor(issue));
      // Unmarking makes no toast, and takes back the one marking made.
      final shown = _notUsefulToast;
      if (shown != null) _toast.dismissIfCurrent(shown);
    }
    setState(() {});
  }

  /// How a Caused by or Effects row opens [related]: a reported issue
  /// shown in the list, hidden or filtered out opens through the host; one
  /// collapsed into a card opens inline; one no longer reported is text.
  RelatedLink _relatedLinkOf(PerformanceIssue related) {
    final issues = widget.controller.issuesNotifier.value;
    final report = _reportOf(related, issues);
    if (report == null) return RelatedLink.plain;
    if (!_ui.severityFilter.contains(report.severity) ||
        _ui.isHidden(report) ||
        _reportOf(report, _shownIssues) != null) {
      return RelatedLink.open;
    }
    return RelatedLink.inline;
  }

  /// Opens [related]'s card, or says why it cannot be shown and offers to
  /// show it.
  void _openRelated(PerformanceIssue related) {
    final report =
        _reportOf(related, widget.controller.issuesNotifier.value) ?? related;
    if (!_ui.severityFilter.contains(report.severity)) {
      _toast.show(
        '"${report.title}" is filtered out',
        actionLabel: 'Show',
        onAction: () {
          if (!_ui.severityFilter.contains(report.severity)) {
            // This filter change keeps the expanded cards, the one the
            // user tapped from included.
            _keepExpansionsOnFilter = true;
            _ui.toggleSeverity(report.severity);
          }
          // A target also hidden needs both turned off to show.
          for (final key in hideKeysOf(report)) {
            _ui.unhide(key);
          }
          _revealAfterFrame(report);
        },
      );
      return;
    }
    if (_ui.isHidden(report)) {
      _toast.show(
        '"${report.title}" is hidden',
        actionLabel: 'Show',
        onAction: () {
          for (final key in hideKeysOf(report)) {
            _ui.unhide(key);
          }
          _revealAfterFrame(report);
        },
      );
      return;
    }
    _reveal(report);
  }

  void _revealAfterFrame(PerformanceIssue target) =>
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _reveal(target);
      });

  /// Expands [target]'s card in the list the user sees, as a tap on it
  /// would, and asks the card to scroll into view and take focus. A target
  /// folded under another card opens inline in that card.
  void _reveal(PerformanceIssue target) {
    final shown = _shownIssues;
    var index = shown.indexWhere((i) => identical(i, target));
    if (index < 0) {
      final report = _reportOf(target, shown);
      if (report != null) index = shown.indexWhere((i) => identical(i, report));
    }
    PerformanceIssue? inline;
    if (index < 0) {
      final id = target.stableId ?? target.title;
      index = shown.indexWhere((i) => i.downstreamIds?.contains(id) ?? false);
      inline = target;
    }
    if (index < 0) {
      _toast.show('"${target.title}" is not in the list');
      return;
    }
    final keys = _shownKeys;
    final key = keys[index];
    setState(() {
      final inZone = _frozen?.any((card) => card.key == key && card.expanded);
      if (!(inZone ?? false)) {
        _frozen = _expandInZone(key, index, shown[index], shown, keys);
      }
      _revealKey = key;
      _revealInline = inline;
      _revealStarted = false;
      _revealEpoch++;
    });
    // The list builds every card while a reveal is pending, so an
    // off-screen card can reveal itself in the next frame; one that did
    // not by then is not coming.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scheduleMicrotask(() {
        if (!mounted || _revealKey != key || _revealStarted) return;
        setState(_endReveal);
        _toast.show('"${target.title}" could not be shown');
      });
    });
  }

  /// The list shows no cards: nothing for a related row or a Hide to
  /// point at.
  void _clearShown() {
    _shownIssues = const [];
    _shownKeys = const [];
  }

  void _endReveal() {
    _revealKey = null;
    _revealInline = null;
  }

  /// The Why it rebuilds split for widget type [type] from the latest
  /// debug snapshot.
  RebuildCause? _rebuildCause(String type, PerformanceIssue issue) {
    final snapshot = widget.controller.lastDebugSnapshot;
    if (snapshot == null) return null;
    // The counts are the latest scan's screen; a card kept from another
    // screen must not read them as its own.
    final screen = widget.controller.lastDebugSnapshotScreen;
    final otherScreen =
        screen != null &&
        (screen.route != issue.routeName ||
            screen.scaffoldHash != issue.scaffoldHashKey);
    final by = snapshot.forcedRebuildsOf[type] ?? const <String, int>{};
    var forced = 0;
    var top = 0;
    String? parent;
    by.forEach((name, count) {
      forced += count;
      if (count > top) {
        top = count;
        parent = name;
      }
    });
    return (
      own: snapshot.rebuildCounts[type] ?? 0,
      forced: forced,
      parents: by.length,
      parent: parent,
      parentForced: top,
      window: snapshot.elapsed,
      capped: snapshot.rebuildTypesCapped || snapshot.forcedTypesCapped,
      otherScreen: otherScreen,
    );
  }

  /// The widget type a rebuild or setState card is about, for Why it
  /// rebuilds.
  static String? _rebuildTypeOf(PerformanceIssue issue) {
    final id = issue.stableId;
    if (id == 'setstate_scope') return issue.widgetName;
    if (id != null && id.startsWith('rebuild_debug_')) {
      return issue.widgetName ?? id.substring('rebuild_debug_'.length);
    }
    return null;
  }

  /// The active route session's rebuild count, for the Rebuild stats link.
  int _rebuildTotal() =>
      widget.controller.activeRouteSession?.rebuildCountsByType.values
          .fold<int>(0, (a, b) => a + b) ??
      0;

  /// Whether [issue] was reported on the screen the active route session
  /// counts: a card kept from another screen must not link to this one's
  /// stats.
  bool _onCurrentScreen(PerformanceIssue issue) {
    final screen = widget.controller.currentScreen;
    return screen.route == issue.routeName &&
        screen.scaffoldHash == issue.scaffoldHashKey;
  }

  static bool _showsRebuildStats(PerformanceIssue issue) {
    final id = issue.stableId;
    return id == 'rebuild_activity' ||
        id == 'setstate_scope' ||
        (id != null && id.startsWith('rebuild_debug_'));
  }

  void _toggleSeverity(IssueSeverity severity) {
    // A severity with no cards has no chip, so the chips could all read
    // off over an empty list. Refuse to turn a chip off when no card would
    // be left. Effects that surface once their cause's severity is off
    // count as cards.
    var refused = false;
    if (_ui.severityFilter.contains(severity)) {
      final issues = widget.controller.issuesNotifier.value;
      final after = applyOverlayFilters(
        issues,
        severities: {..._ui.severityFilter}..remove(severity),
        hiddenKeys: _ui.hiddenKeys,
      );
      refused = after.isEmpty && _ui.visibleIssues(issues).isNotEmpty;
    }
    if (refused || !_ui.toggleSeverity(severity)) {
      _toast.show('Keep at least one severity', tone: OverlayToastTone.warning);
    }
  }

  /// The reported issue whose chat key is [key], or null when none is or
  /// several are (issues sharing a list key without an occurrence
  /// identity). Matched by identity only: a title change or a new rank
  /// order does not move the chat to another card.
  PerformanceIssue? _findLiveChatIssue(_ChatKey key) {
    PerformanceIssue? match;
    for (final i in widget.controller.issuesNotifier.value) {
      if (_chatKeyFor(i) != key) continue;
      if (match != null) return null;
      match = i;
    }
    return match;
  }

  void _onVerdictChanged() {
    final held = widget.controller.heldJankCauses();
    _jankHoldTimer?.cancel();
    final wait = held.nextExpiry;
    _jankHoldTimer = wait == null
        ? null
        : Timer(wait, () {
            if (mounted) _onVerdictChanged();
          });
    final newKeys = _matchingIssueKeys(held.keys);
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
  /// `_frozen` on the new list, `_pruneStaleState` has already
  /// matched the zone to it — no "zombie expand entry" can apply
  /// `initiallyExpanded: true` to a coincidentally-matching new-route
  /// issue. Do not move pruning to a post-frame callback or microtask:
  /// that would break this invariant and re-introduce the bug.
  void _onIssuesChanged() {
    _pruneStaleState();
    _onVerdictChanged();
  }

  /// The report of [known] among [reported]: same list key and element
  /// identity. Of two cards sharing a list key, an occurrence key would
  /// point at the twin once the first one goes; the element does not.
  static PerformanceIssue? _reportOf(
    PerformanceIssue known,
    Iterable<PerformanceIssue> reported,
  ) {
    final key = listKeyFor(known);
    for (final r in reported) {
      if (r.occurrenceId == known.occurrenceId && listKeyFor(r) == key) {
        return r;
      }
    }
    return null;
  }

  /// Whether [a] and [b] hold the same cards in the same states; their
  /// reports may be newer instances.
  static bool _sameZone(List<FrozenCard>? a, List<FrozenCard>? b) {
    if (a == null || b == null) return a == b;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].key != b[i].key ||
          a[i].expanded != b[i].expanded ||
          a[i].reported != b[i].reported) {
        return false;
      }
    }
    return true;
  }

  /// The frozen zone once the user expands the card [key], shown at
  /// [index] of the rendered [shown] list under [shownKeys]. A card in the
  /// zone is marked expanded; any other card extends the zone down to it,
  /// or to a lower expanded card, captured from the rows the user saw
  /// with the keys they rendered under.
  List<FrozenCard> _expandInZone(
    String key,
    int index,
    PerformanceIssue issue,
    List<PerformanceIssue> shown,
    List<String> shownKeys,
  ) {
    final zone = _frozen ?? const <FrozenCard>[];
    final byKey = {for (final card in zone) card.key: card};
    if (byKey.containsKey(key)) {
      return [
        for (final card in zone)
          card.key == key
              ? (key: key, issue: issue, expanded: true, reported: true)
              : card,
      ];
    }
    var end = index;
    for (var j = index + 1; j < shownKeys.length; j++) {
      if (byKey[shownKeys[j]]?.expanded ?? false) end = j;
    }
    final next = <FrozenCard>[
      for (var j = 0; j <= end; j++)
        (
          key: shownKeys[j],
          issue: j == index ? issue : shown[j],
          expanded: j == index || (byKey[shownKeys[j]]?.expanded ?? false),
          reported: byKey[shownKeys[j]]?.reported ?? true,
        ),
    ];
    // A list published after the tapped build can leave an expanded card
    // out of those rows; it stays, below them.
    final captured = {for (final card in next) card.key};
    next.addAll(
      zone.where((card) => card.expanded && !captured.contains(card.key)),
    );
    return next;
  }

  /// Whether the card [issue], rendered under [key], is the one whose
  /// crosshair is on: the same occurrence when the issue has an
  /// occurrence id, else the same key.
  bool _isSelectedCard(PerformanceIssue issue, String key) =>
      _isCardOf(_selectedIssue, _selectedIssueId, issue, key);

  /// Whether the card [issue], rendered under [key], is [target]'s card,
  /// which rendered under [targetKey]: the same occurrence when [target]
  /// has an occurrence id, else the same key.
  static bool _isCardOf(
    PerformanceIssue? target,
    String? targetKey,
    PerformanceIssue issue,
    String key,
  ) {
    if (target == null) return false;
    if (target.occurrenceId == null) return key == targetKey;
    return issue.occurrenceId == target.occurrenceId &&
        listKeyFor(issue) == listKeyFor(target);
  }

  /// Clears pin/selection/chat state when referenced issues are no longer
  /// present.
  ///
  /// Since v0.15.5, pin pruning is keyed against the VISIBLE list —
  /// not the raw `issuesNotifier.value` — because a pinned root's
  /// downstream children may churn without the root itself disappearing.
  /// Using raw keys leaked "zombie pins" for cards that stopped rendering
  /// when their root got collapsed into an expanded parent.
  ///
  /// The visible list is [applyOverlayFilters], the same list
  /// [_buildIssuesList] renders, and the frozen zone is matched to it
  /// ([applyFreezeZone]).
  ///
  /// `_chatIssueKey` and `_chatHistories` intentionally stay on the
  /// raw-list check — those surfaces operate on ALL issues (including
  /// downstream ones reachable via Ask AI), and narrowing them here would
  /// hide entries the user can still reach through the expanded parent's
  /// downstream list. `_selectedIssueId` is dropped, together with the
  /// controller's highlight selection and the highlight bar, when its card
  /// leaves the visible list (the issue is gone, hidden, or filtered out
  /// by severity).
  void _pruneStaleState() {
    final issues = widget.controller.issuesNotifier.value;
    final visible = _ui.visibleIssues(issues);
    final chatKeys = <_ChatKey>{for (final i in issues) _chatKeyFor(i)};
    var changed = false;

    // An expanded card stays until the user collapses it, even when its
    // issue stops being reported or folds under another card: it does not
    // vanish while it is being read. A card the user hid goes, expanded or
    // not, judged on its current report, as hiding depends on its
    // severity: with a shared hide key, hiding one occurrence hides its
    // twin too. Collapsed cards that left the visible list leave the
    // zone, so one that comes back (Undo, restore, a detector
    // re-emitting) lands below it instead of pushing the expanded card
    // down.
    final frozen = _frozen;
    if (frozen != null) {
      final next = applyFreezeZone(
        visibleIssues: visible,
        frozen: [
          for (final card in frozen)
            card.expanded &&
                    _ui.isHidden(_reportOf(card.issue, issues) ?? card.issue)
                ? (
                    key: card.key,
                    issue: card.issue,
                    expanded: false,
                    reported: card.reported,
                  )
                : card,
        ],
      ).frozen;
      if (!_sameZone(frozen, next)) changed = true;
      _frozen = next;
    }

    // When the issue leaves the list, the highlight ends and the card comes
    // back. A toast says why when the bar was up and the issue is no
    // longer reported.
    final selectedIssue = _selectedIssue;
    if (selectedIssue != null && _reportOf(selectedIssue, visible) == null) {
      final gone = _barOpen && _reportOf(selectedIssue, issues) == null;
      _endHighlight(refocusHeader: true);
      if (gone) {
        _toast.show(
          'The issue on ${selectedIssue.widgetName} is no longer reported.',
        );
      }
    }
    // An open chat outlives its issue (the page holds the last reported
    // instance); only closed chats lose their history with the issue.
    final openChat = _showAiChat ? _chatIssueKey : null;
    _chatHistories.removeWhere(
      (key, _) => key != openChat && !chatKeys.contains(key),
    );
    // The open chat rebuilds with each update, so the page shows the
    // latest report of its own issue and the prompt sees the current list.
    if (openChat != null) changed = true;
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

  /// Keys of the reported issues among [held], the issues a jank verdict
  /// named within the jank window. Late frames alternate between phases,
  /// so a tag that followed only the latest verdict went on and off.
  ///
  /// Keys are returned only while a jank symptom is reported, so the tag
  /// leaves with the jank cards. The reported list is checked, not the
  /// visible one: collapsing, hiding or filtering a symptom keeps the tag.
  Set<String> _matchingIssueKeys(Set<String> held) {
    if (held.isEmpty) return const {};
    final current = widget.controller.issuesNotifier.value;
    if (!current.any(isJankSymptom)) return const {};
    return {
      for (final issue in current)
        if (held.contains(issue.stableId ?? issue.title))
          issue.stableId ?? issue.title,
    };
  }

  Future<void> _exportToClipboard() async {
    if (_copyInFlight) return;
    _copyInFlight = true;
    try {
      // Building and encoding the snapshot is Sleuth's own work, which the
      // jank rule leaves out of the next frame's start delay.
      ownWorkLog.recordUntilMicrotask();
      final json = widget.controller.exportSnapshotJson();
      try {
        await Clipboard.setData(ClipboardData(text: json));
      } catch (e) {
        debugPrint('Sleuth: snapshot copy failed: $e');
        if (mounted) {
          _toast.show(
            "Couldn't copy snapshot",
            tone: OverlayToastTone.warning,
            actionLabel: 'Try again',
            onAction: _exportToClipboard,
          );
        }
        return;
      }
      if (!mounted) return;
      _toast.show('Snapshot copied to clipboard');
    } finally {
      _copyInFlight = false;
    }
  }

  /// Handles a tap on the crosshair or Show on screen. [checked] starts a
  /// lookup, and false cancels one still running. If the widget is found,
  /// the card shrinks to the highlight bar; if not, a toast says so and
  /// the card stays.
  void _onHighlightChanged(
    bool checked,
    String issueKey,
    PerformanceIssue issue,
  ) {
    if (!checked) {
      _endHighlight();
      return;
    }
    final controller = widget.controller;
    _crosshairKeyboardFocus = _focusInCard();
    setState(() {
      _selectedIssueId = issueKey;
      _selectedIssue = issue;
    });
    void resolved(HighlightLookup result) {
      if (!mounted || _barOpen || _selectedIssueId != issueKey) return;
      if (result == HighlightLookup.found) {
        _enterBar();
      } else {
        _onHighlightNotFound(issue);
      }
    }

    final result = controller.selectHighlightForIssue(
      issue,
      onResolved: resolved,
    );
    if (result != HighlightLookup.pending) resolved(result);
  }

  void _clearSelection() {
    _selectedIssueId = null;
    _selectedIssue = null;
  }

  /// The card shrinks to the bar. The list unmounts and comes back at its
  /// offset; Back to issues takes focus.
  void _enterBar() {
    _listScroll.keepOffset();
    _closeMenu(refocus: false);
    final card = _cardKey.currentContext?.findRenderObject();
    _barShieldTimer?.cancel();
    _barShieldTimer = null;
    _barShield = card is RenderBox && card.hasSize
        ? card.localToGlobal(Offset.zero) & card.size
        : null;
    if (_barShield != null) {
      _barShieldTimer = Timer(kDoubleTapTimeout, () {
        if (mounted) setState(() => _barShield = null);
      });
    }
    setState(() => _barOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_barOpen) return;
      if (_crosshairKeyboardFocus) _barBackFocus.requestFocus();
      _barBackFocus.context?.findRenderObject()?.sendSemanticsEvent(
        const FocusSemanticEvent(),
      );
    });
  }

  /// Back to issues: the card returns as it was and the crosshair takes
  /// focus.
  void _leaveBar() {
    _crosshairKeyboardFocus = _focusInCard();
    _endHighlight(focusCrosshair: true);
  }

  /// The bar's close: the highlight ends with the dashboard.
  void _closeFromBar() {
    _endHighlight();
    widget.onClose();
  }

  /// Ends a lookup or the bar, and the outline with it. [focusCrosshair]
  /// moves focus to the card's crosshair, [refocusHeader] to the header.
  void _endHighlight({
    bool focusCrosshair = false,
    bool refocusHeader = false,
  }) {
    if (_selectedIssue == null && !_barOpen) return;
    final key = _selectedIssueId;
    final selected = _selectedIssue;
    final wasOpen = _barOpen;
    // Keyboard focus on the bar goes to the header with the screen reader.
    final keyboardToHeader = refocusHeader && _focusInCard();
    _barShieldTimer?.cancel();
    _barShieldTimer = null;
    setState(() {
      _barOpen = false;
      _barShield = null;
      _clearSelection();
      if (focusCrosshair && selected != null) {
        _crosshairFocusIssue = selected;
        _crosshairFocusKey = key;
        _crosshairFocusStarted = false;
        _crosshairFocusEpoch++;
      }
    });
    widget.controller.clearSelectedHighlight();
    if (!wasOpen) return;
    _listAtTop = _listScroll.keptOffset <= 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Runs after the frame's other callbacks, the card's included. When
      // no card started a scroll to its crosshair, the target is gone and
      // the list stops building every card; else the card's scroll end
      // clears it.
      scheduleMicrotask(() {
        if (mounted && !_crosshairFocusStarted) {
          setState(_clearCrosshairFocus);
        }
      });
      if (!refocusHeader) return;
      if (keyboardToHeader) _moreFocus.requestFocus();
      _focusSemantics(_headerKey);
    });
  }

  void _clearCrosshairFocus() {
    _crosshairFocusIssue = null;
    _crosshairFocusKey = null;
    _crosshairFocusStarted = false;
  }

  /// Rebuilds the bar when the outlined widget moves, leaves the screen or
  /// comes back.
  void _onBarTarget() {
    if (mounted && _barOpen) setState(() {});
  }

  /// The highlight bar at the safe-area edge away from the outlined
  /// widget, at most 480 px wide.
  Widget _highlightBar(
    Size screenSize,
    EdgeInsets safe,
    double keyboardHeight,
  ) {
    final issue = _selectedIssue!;
    final rect = widget.controller.selectedHighlightNotifier.value?.rect;
    // The keyboard covers the bottom of the screen.
    final visible = Rect.fromLTRB(
      0,
      0,
      screenSize.width,
      math.max(0.0, screenSize.height - keyboardHeight),
    );
    final onScreen = rect != null && !rect.isEmpty && rect.overlaps(visible);
    if (onScreen) _barAtTop = highlightBarAtTop(rect, visible);
    final margin = SleuthTheme.of(context).spacingMd;
    return Positioned(
      key: const ValueKey<String>('Sleuth highlight bar'),
      left: safe.left + margin,
      right: safe.right + margin,
      top: _barAtTop ? safe.top + margin : null,
      bottom: _barAtTop ? null : math.max(safe.bottom, keyboardHeight) + margin,
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SleuthHighlightBar(
            severity: issue.severity,
            widgetName: issue.widgetName ?? issue.title,
            offScreen: !onScreen,
            onBack: _leaveBar,
            onClose: _closeFromBar,
            backFocusNode: _barBackFocus,
          ),
        ),
      ),
    );
  }

  /// Whether keyboard focus is on a control of the card or the bar.
  bool _focusInCard() {
    final focusContext = FocusManager.instance.primaryFocus?.context;
    return focusContext != null &&
        focusContext.mounted &&
        focusContext.findAncestorStateOfType<_FloatingIssuesCardState>() ==
            this;
  }

  /// Ends the lookup, so the card does not claim an outline that never
  /// comes, and says why.
  void _onHighlightNotFound(PerformanceIssue issue) {
    _endHighlight();
    _toast.show(
      "Couldn't find ${issue.widgetName} on screen. It may be scrolled "
      'away or not built yet.',
      tone: OverlayToastTone.warning,
      duration: const Duration(seconds: 3),
    );
  }

  /// Whether an issue can be visually located on screen.
  /// A card can outline its widget only when the issue names one: the
  /// highlight lookup matches the reported element or the widget name.
  static bool _isLocatableIssue(PerformanceIssue issue) =>
      issue.widgetName != null;

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final safe = MediaQuery.viewPaddingOf(context);
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    // Chrome grows with the text inside it (up to 1.3x); the minimum
    // height grows with it but never past the screen's usable height
    // (a landscape phone, a split-screen pane), down to the card's own
    // chrome. The stored height is left alone, so the card returns to it
    // at 1.0x.
    final chromeScale = chromeScaleOf(context);
    final available = screenSize.height - safe.top - math.max(safe.bottom, 20);
    // The card never gets shorter than its header, its status row and one
    // 48 px row of the list.
    final chromeHeight =
        _headerHeight + _statusHeightFor(chromeScale) + _controlRowHeight;
    final minHeight = math.min(
      _minCardHeight * chromeScale,
      math.max(chromeHeight, available),
    );
    final maxAllowedHeight = math.max(minHeight, available);
    final isMinimized = _windowState == CardWindowState.minimized;

    final double cardHeight;
    if (_windowState == CardWindowState.maximized) {
      // Follows a rotation or window resize. Tracks the keyboard so the
      // card shrinks above it, down to the header, the status row and a
      // row of the list.
      if (_maximizedFor != (screenSize, safe)) _fitMaximized(screenSize, safe);
      _cardHeight = _maximizedHeight(screenSize, safe, keyboardHeight);
      cardHeight = math.max(_cardHeight!, chromeHeight);
    } else {
      cardHeight = _shownHeight(
        screenSize,
        isMinimized ? _minimizedHeight * chromeScale : minHeight,
        maxAllowedHeight,
      );
    }
    _cachedMinWidth = _minWidthFor(screenSize, safe);
    final effectiveWidth = _effectiveWidth(screenSize, safe);
    _cachedSafePadding = safe;
    _cachedEffectiveWidth = effectiveWidth;
    _cachedKeyboardHeight = keyboardHeight;
    _cachedCardHeight = cardHeight;
    _cachedMinHeight = minHeight;
    _cachedMaxHeight = maxAllowedHeight;
    final theme = SleuthTheme.of(context);
    _accessibleNavigation =
        MediaQuery.maybeAccessibleNavigationOf(context) ?? false;
    _syncToastTiming();

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

    final layers = _openLayers();
    final layerDepth = layers.length;
    if (!setEquals(layers, _reportedLayers)) {
      // The list unmounts under the page and comes back where it was.
      if (_reportedLayers.isEmpty) _listScroll.keepOffset();
      if (layerDepth == 0) _listAtTop = _listScroll.keptOffset <= 0;
      final opened = layers.difference(_reportedLayers);
      _reportedLayers = layers;
      _reportedMenuOpen = _menuOpen;
      widget.onLayersChanged?.call();
      _afterLayersChanged(opened.isEmpty ? null : opened.last);
    } else if (_menuOpen != _reportedMenuOpen) {
      // The overlay blocks the app's semantics while the menu is open.
      _reportedMenuOpen = _menuOpen;
      widget.onLayersChanged?.call();
    }

    return Stack(
      children: [
        if (layerDepth == 0 && _barOpen && _barShield != null)
          // Keyed, with the bar, so the shield going does not remount
          // the bar in its slot.
          Positioned.fromRect(
            key: const ValueKey<String>('Sleuth bar shield'),
            rect: _barShield!,
            child: Listener(behavior: HitTestBehavior.opaque),
          ),
        if (layerDepth == 0 && _barOpen)
          _highlightBar(screenSize, safe, keyboardHeight),
        if (layerDepth == 0 && !_barOpen)
          Positioned(
            left: clamped.dx,
            top: clamped.dy,
            child: Stack(
              key: _cardKey,
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
                if (_menuOpen && !isMinimized) _menuScrim(theme),
                if (!isMinimized)
                  _buildResizeHandle(
                    screenSize,
                    clamped,
                    cardHeight,
                    maxAllowedHeight,
                    theme,
                  ),
                if (_menuOpen && !isMinimized)
                  _menuPanel(effectiveWidth, cardHeight, theme, chromeScale),
              ],
            ),
          ),
        if (_showHidden)
          // Issues and the suppressed count are read live; hidden keys
          // rebuild the card through `_onUiStateChanged`.
          _page(
            _OverlayLayer.hidden,
            SleuthListenableBuilder(
              listenable: _hiddenPageSources(),
              builder: (context) => HiddenIssuesPage(
                hiddenKeys: _ui.hiddenKeys.toList(),
                issues: widget.controller.issuesNotifier.value,
                configSuppressions: widget.controller.config.suppressedIssues,
                suppressedCount:
                    widget.controller.suppressedCountNotifier.value,
                onRestore: _ui.unhide,
                onRestoreAll: _restoreAllHidden,
                onClose: () => setState(() => _showHidden = false),
              ),
            ),
          ),
        if (_showGuide)
          _page(
            _OverlayLayer.guide,
            GuidePage(onClose: () => setState(() => _showGuide = false)),
          ),
        if (_showDetail)
          _page(
            _OverlayLayer.detail,
            IssueEncyclopediaPage(
              onClose: _closeDetail,
              scrollToStableId: _detailStableId,
              contextIssue: _detailContextIssue,
            ),
          ),
        if (_showAiChat)
          _page(_OverlayLayer.chat, _buildAiChatPage(_chatIssueKey!)),
        if (_showStartupDetail)
          _page(
            _OverlayLayer.startup,
            StartupMetricsPage(
              onClose: () => setState(() => _showStartupDetail = false),
            ),
          ),
        if (_showRebuildStats && _rebuildStatsSnapshot != null)
          _page(
            _OverlayLayer.rebuildStats,
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

  /// The chat keyed [chatKey], captured when the chat opened. The page
  /// shows the reported issue with that identity, else the one it last
  /// showed. The history callback holds [chatKey] and the controller the
  /// page was built for: the page commits a stopped reply from `dispose`,
  /// after close or prune has cleared [_chatIssueKey], and after a
  /// controller swap that write stays with the old controller. A write for
  /// an issue that is no longer reported is dropped, as [_pruneStaleState]
  /// would drop it.
  Widget _buildAiChatPage(_ChatKey chatKey) {
    final live = _findLiveChatIssue(chatKey);
    if (live != null) _chatIssue = live;
    final controller = widget.controller;
    return AiChatPage(
      // Set together with [_chatIssueKey] when the chat opens.
      issue: _chatIssue!,
      // Hidden issues reach the prompt as a count only.
      allIssues: [
        for (final issue in widget.controller.issuesNotifier.value)
          if (!_ui.isHidden(issue)) issue,
      ],
      adapter: widget.controller.config.aiChat!,
      history: _chatHistories[chatKey] ?? const [],
      onHistoryChanged: (msgs) {
        // A closed chat's history is kept only while its issue is
        // reported; the open chat always keeps its own.
        final current = identical(controller, widget.controller);
        final open = current && _showAiChat && _chatIssueKey == chatKey;
        final reported = controller.issuesNotifier.value.any(
          (i) => _chatKeyFor(i) == chatKey,
        );
        if (open || reported) controller.aiChatHistories[chatKey] = msgs;
      },
      onClose: _closeAiChat,
      onNotify: (message) => _toast.show(message),
      onNotifyAction: (message, actionLabel, onAction) {
        _toast.show(message, actionLabel: actionLabel, onAction: onAction);
        final shown = _toast.value;
        return shown == null ? null : () => _toast.dismissIfCurrent(shown);
      },
      sessionContext: _sessionContext,
    );
  }

  /// The app's state for the AI prompt: counts and rates only, the
  /// hidden issues as a count of the reported issues the user hid.
  AiSessionContext _sessionContext() {
    final c = widget.controller;
    var critical = 0, warning = 0, ok = 0, hidden = 0;
    for (final issue in c.issuesNotifier.value) {
      if (_ui.isHidden(issue)) hidden++;
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
      hiddenCount: hidden,
      isDebugMode: c.isDebugMode,
      connectionMode: computeConnectionMode(c),
      platform: defaultTargetPlatform.name,
    );
  }

  /// A full-screen page over the card, in its own focus scope. While one
  /// is open, [SleuthOverlay] drops the app's semantics below the overlay
  /// and excludes the app's focus (see [OverlayLayerHost.openLayerDepth]),
  /// so a screen reader and the keyboard stay on the page; the floating
  /// card alone leaves the app reachable.
  Widget _page(_OverlayLayer layer, Widget page) => Positioned.fill(
    child: FocusScope(
      node: _layerScopes.putIfAbsent(
        layer,
        () => FocusScopeNode(debugLabel: 'Sleuth ${layer.name}'),
      ),
      includeSemantics: false,
      child: page,
    ),
  );

  /// Opens Rebuild stats on a snapshot of the active route's counts, taken
  /// at tap time so later scans do not reorder the rows. When the session
  /// ended before the tap (a route change mid-gesture) a toast says so
  /// instead.
  void _onSeeAllRebuildsTap() {
    final session = widget.controller.activeRouteSession;
    final source = session?.rebuildCountsByType;
    if (source == null || source.isEmpty) {
      _toast.show('Session no longer active', tone: OverlayToastTone.warning);
      return;
    }
    setState(() {
      _rebuildStatsSnapshot = Map<String, int>.of(source);
      _rebuildStatsRouteName = session?.routeName;
      _showRebuildStats = true;
    });
  }

  // ─── Build helpers ──────────────────────────────────────────────────

  /// Shown height of a normal or minimized card: the stored height (55 %
  /// of the screen by default) within [floor]..[ceiling].
  double _shownHeight(Size screenSize, double floor, double ceiling) =>
      (_cardHeight ?? screenSize.height * 0.55).clamp(floor, ceiling);

  /// Shown width of the card: the stored width, at least the minimum.
  double _effectiveWidth(Size screenSize, EdgeInsets safe) {
    final min = _minWidthFor(screenSize, safe);
    return _cardWidth.clamp(min, math.max(min, screenSize.width)).toDouble();
  }

  /// Fits the whole card inside the usable area (the safe area above the
  /// keyboard) before a move or resize is committed, so the resize grip
  /// stays on screen. A resize ([keepTop]) keeps the top
  /// edge and caps the height at the usable bottom, unless the minimum
  /// height does not fit below the top edge: then the card moves up and
  /// may take the whole usable height. A move keeps the height and moves
  /// the card up. The height gives way, down to its minimum, only when the
  /// card cannot fit otherwise. A maximized card is placed by
  /// [_fitMaximized] instead.
  void _fitToUsableArea({bool keepTop = false}) {
    if (_cardOffset == null || _windowState == CardWindowState.maximized) {
      return;
    }
    final screenSize = MediaQuery.sizeOf(context);
    final safe = _cachedSafePadding;
    final top = safe.top;
    final bottom =
        screenSize.height - math.max(safe.bottom, _cachedKeyboardHeight);
    final offset = _clampOffset(
      screenSize,
      safe,
      _effectiveWidth(screenSize, safe),
      _cachedKeyboardHeight,
    );
    var shown = _cachedCardHeight;
    if (_windowState == CardWindowState.normal) {
      shown = _shownHeight(screenSize, _cachedMinHeight, _cachedMaxHeight);
      final belowTop = bottom - offset.dy;
      final room = keepTop && belowTop >= _cachedMinHeight
          ? belowTop
          : bottom - top;
      if (shown > room) {
        // The stored height keeps the unscaled minimum; the scaled floor
        // holds the shown height up.
        _cardHeight = math.max(
          math.min(_cardHeight ?? shown, room),
          math.min(_minCardHeight, _cachedMaxHeight),
        );
        shown = _shownHeight(screenSize, _cachedMinHeight, _cachedMaxHeight);
      }
    }
    _cardOffset = Offset(
      offset.dx,
      offset.dy.clamp(top, math.max(top, bottom - shown)),
    );
  }

  /// Keeps the card's top-left inside the safe area: within the
  /// horizontal view padding, below the top inset, and with at least
  /// 100 px of title bar above the keyboard or bottom inset. A drag keeps
  /// to this while the finger is down; [_fitToUsableArea] brings the
  /// whole card on screen when it ends.
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
    // The banners scroll once they would take more than half of the space
    // below the status row and leave the list less than about two
    // collapsed cards (large text, a short card). They never leave the
    // list less than one row; in a card squeezed below that (a keyboard
    // over a maximized card) they give up all their space.
    final middle = math.max(
      0.0,
      cardHeight - _headerHeight - _statusHeightFor(chromeScale),
    );
    const minList = 96.0;
    final bannersMaxHeight = math
        .max(middle * 0.5, middle - minList)
        .clamp(0.0, math.max(0.0, middle - 48))
        .toDouble();
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
            if (!isMinimized)
              Flexible(
                // Under the menu's scrim the card's content is out of
                // reach, for touch and for a screen reader.
                child: ExcludeSemantics(
                  excluding: _menuOpen,
                  // The status row and the list share one pass over the
                  // reported issues.
                  child: ValueListenableBuilder<List<PerformanceIssue>>(
                    valueListenable: widget.controller.issuesNotifier,
                    builder: (context, issues, _) {
                      final model = _ListModel(issues, _ui);
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _StatusRow(
                            controller: widget.controller,
                            chromeScale: chromeScale,
                            severityCounts: model.severityCounts,
                            enabledSeverities: _ui.severityFilter,
                            onToggleSeverity: _toggleSeverity,
                            firstChipKey: _firstChipKey,
                          ),
                          Divider(color: theme.cardDivider, height: 1),
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: bannersMaxHeight,
                            ),
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (widget.isDebugMode &&
                                      widget
                                          .controller
                                          .config
                                          .showDebugModeBanner &&
                                      !widget.controller.debugBannerDismissed)
                                    SleuthDebugBanner(
                                      instrumentationActive: widget
                                          .controller
                                          .isDeepInstrumentationActive,
                                      onDismiss: _dismissDebugBanner,
                                    ),
                                  // With cards listed, only a lost link
                                  // takes room above them, also above an
                                  // expanded card whose issue is gone.
                                  if (issues.isNotEmpty || _frozen != null)
                                    _statusLine(emptyList: false),
                                ],
                              ),
                            ),
                          ),
                          Flexible(
                            child: RepaintBoundary(
                              child: _buildIssuesList(model),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The menu's scrim over the card below the header. A tap on it closes
  /// the menu and goes no further.
  Widget _menuScrim(SleuthThemeData theme) => Positioned(
    top: _headerHeight,
    left: 0,
    right: 0,
    bottom: 0,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: _closeMenu,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.dimOverlay,
          borderRadius: BorderRadius.vertical(
            bottom: Radius.circular(theme.radiusCard),
          ),
        ),
      ),
    ),
  );

  /// The More menu panel, under the More button, at most the card height
  /// below the header.
  Widget _menuPanel(
    double cardWidth,
    double cardHeight,
    SleuthThemeData theme,
    double chromeScale,
  ) {
    final margin = theme.spacingMd;
    final width = math.max(
      0.0,
      math.min(236 * chromeScale, cardWidth - 2 * margin),
    );
    // The More button's right edge: the header's right padding, close and
    // the window controls (minimize and maximize, or restore).
    final moreRight =
        theme.spacingXs +
        _controlRowHeight +
        (_windowState == CardWindowState.normal ? 2 : 1) * 36;
    final right = math.max(
      margin,
      math.min(moreRight, cardWidth - width - margin),
    );
    final values = _menuValues!;
    return Positioned(
      top: _headerHeight - theme.spacingXs,
      right: right,
      width: width,
      // Menu text grows like the header's, up to the chrome clamp; the
      // panel width grows with it.
      child: SleuthTextScaleClamp(
        maxScaleFactor: kChromeMaxTextScale,
        child: SleuthMoreMenu(
          semanticsKey: _menuKey,
          values: values,
          themeMode: _ui.themeMode,
          focusScope: _menuScope,
          maxHeight: math.max(0.0, cardHeight - _headerHeight - margin),
          onStartup: () => _openFromMenu(() => _showStartupDetail = true),
          onRebuildStats: () {
            _closeMenu(refocus: false);
            _onSeeAllRebuildsTap();
            if (_showRebuildStats) {
              _layerOpener = _moreOpener;
            } else {
              // No page opened (the route's session ended): focus goes
              // back to More, under the toast that says why.
              _focusMore();
            }
          },
          onHiddenIssues: () => _openFromMenu(() => _showHidden = true),
          onEncyclopedia: () => _openFromMenu(() {
            _detailStableId = null;
            _showDetail = true;
          }),
          onGuide: () => _openFromMenu(() => _showGuide = true),
          onCopySnapshot: () {
            _closeMenu();
            _exportToClipboard();
          },
          onThemeMode: (mode) => _ui.themeMode = mode,
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
    final grip = CustomPaint(
      painter: _CornerGripPainter(gripColor: theme.gripDots),
    );

    // A maximized card resizes too: the first step makes it a normal card
    // at the size and place it has now, then resizes that.
    void leaveMaximized() {
      if (_windowState != CardWindowState.maximized) return;
      _windowState = CardWindowState.normal;
      _cardOffset = clamped;
      _cardWidth = _cachedEffectiveWidth;
      _cardHeight = cardHeight;
      _preTransitionOffset = null;
      _preTransitionWidth = null;
      _preTransitionHeight = null;
    }

    // The stored height keeps the unscaled minimum: the scaled floor
    // (large text) is display-only, so the card returns to its own height
    // at 1.0x. Growing starts from the shown height; shrinking from the
    // stored one while the floor holds the shown height up.
    final minWidth = _cachedMinWidth;
    void resizeBy(double dw, double dh) {
      // A right-flush card grows leftwards ([_clampOffset] moves it), up
      // to the safe-area width minus [_clampOffset]'s 5 px margin, so it
      // never reaches under a landscape notch. The step starts from the
      // width shown: a stored width from an older release or a larger
      // screen is clamped first.
      leaveMaximized();
      final maxWidth = math.max(
        minWidth,
        screenSize.width - _cachedSafePadding.horizontal - 5,
      );
      final shown = _cardWidth.clamp(minWidth, maxWidth);
      _cardWidth = (shown + dw).clamp(minWidth, maxWidth);
      final stored = _cardHeight ?? cardHeight;
      final base = dh < 0 ? math.min(stored, cardHeight) : cardHeight;
      _cardHeight = (base + dh).clamp(
        math.min(_minCardHeight, maxAllowedHeight),
        maxAllowedHeight,
      );
    }

    // The committed size keeps the whole card on screen.
    void resizeAndCommit(double dw, double dh) {
      setState(() {
        resizeBy(dw, dh);
        _fitToUsableArea(keepTop: true);
      });
      _commitGeometry();
    }

    // 48 x 48 hit box; the grip dots keep their corner position. Screen
    // readers resize through the custom actions in 48 px steps.
    final atMinWidth = _cachedEffectiveWidth <= minWidth;
    final atMaxWidth =
        _cachedEffectiveWidth >=
        math.max(
          minWidth,
          screenSize.width - _cachedSafePadding.horizontal - 5,
        );
    return Positioned(
      right: 0,
      bottom: 0,
      width: 48,
      height: 48,
      child: Semantics(
        container: true,
        label: 'Resize card',
        value: _sizeValue(_cachedEffectiveWidth, cardHeight),
        customSemanticsActions: {
          const CustomSemanticsAction(label: 'Taller'): () =>
              resizeAndCommit(0, _a11yStep),
          const CustomSemanticsAction(label: 'Shorter'): () =>
              resizeAndCommit(0, -_a11yStep),
          if (!atMaxWidth)
            const CustomSemanticsAction(label: 'Wider'): () =>
                resizeAndCommit(_a11yStep, 0),
          if (!atMinWidth)
            const CustomSemanticsAction(label: 'Narrower'): () =>
                resizeAndCommit(-_a11yStep, 0),
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeDownRight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // The custom actions resize; pan scroll actions would not.
            excludeFromSemantics: true,
            // The grip follows the finger; the card is fitted on screen
            // when the drag ends.
            onPanStart: (_) {
              _closeMenu(refocus: false);
              setState(leaveMaximized);
            },
            onPanUpdate: (details) =>
                setState(() => resizeBy(details.delta.dx, details.delta.dy)),
            onPanEnd: (_) {
              setState(() => _fitToUsableArea(keepTop: true));
              _commitGeometry();
            },
            child: grip,
          ),
        ),
      ),
    );
  }

  /// Step of the move and resize custom semantics actions.
  static const double _a11yStep = 48;

  /// Moves the card by [delta], the whole card kept inside the usable
  /// area.
  void _moveCardBy(Offset delta) {
    setState(() {
      _cardOffset = (_cardOffset ?? Offset.zero) + delta;
      _fitToUsableArea();
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
      _fitToUsableArea();
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
    // A maximized card fills the safe area: it neither drags nor moves.
    final movable = _windowState != CardWindowState.maximized;
    // Only show window controls when the card is wide enough to avoid overflow.
    final showWindowControls = effectiveWidth >= 280 || !isNormal;
    // The header is the drag handle; screen readers move the card through
    // the custom actions in 48 px steps and hear the size and position
    // back. The pan recognizer is kept out of semantics: its scroll
    // actions would move the card by most of its own size.
    return Semantics(
      key: _headerKey,
      container: true,
      explicitChildNodes: true,
      label: 'Sleuth',
      value:
          '${_sizeValue(effectiveWidth, cardHeight)}, at '
          '${position.dx.round()}, ${position.dy.round()}',
      customSemanticsActions: movable
          ? {
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
            }
          : null,
      child: GestureDetector(
        excludeFromSemantics: true,
        // A drag closes the menu. While the finger is down the card keeps
        // at least its title bar on screen; on release the whole card is
        // fitted on screen.
        onPanStart: movable ? (_) => _closeMenu(refocus: false) : null,
        onPanUpdate: movable
            ? (details) {
                setState(() {
                  _cardOffset = (_cardOffset ?? Offset.zero) + details.delta;
                  _cardOffset = _clampOffset(
                    screenSize,
                    _cachedSafePadding,
                    _cachedEffectiveWidth,
                    _cachedKeyboardHeight,
                  );
                });
              }
            : null,
        onPanEnd: movable
            ? (_) {
                setState(_fitToUsableArea);
                _commitGeometry();
              }
            : null,
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
                  // The title area gives way first (see [_headerTitle]);
                  // the controls keep their 48 px height.
                  Expanded(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: widget.controller.vmConnectedNotifier,
                      builder: (_, connected, _) =>
                          _headerTitle(theme, connected),
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
                  // Flagged-widget markers toggle (hidden when minimized)
                  if (!isMinimized)
                    ValueListenableBuilder<bool>(
                      valueListenable:
                          widget.controller.highlightEnabledNotifier,
                      builder: (_, enabled, _) => _compactHeaderButton(
                        icon: enabled ? Icons.layers : Icons.layers_outlined,
                        color: enabled
                            ? theme.checkboxActive
                            : theme.textTertiary,
                        // The markers only: an issue's outline and its
                        // lookup stay as they are.
                        onTap: () {
                          _closeMenu(refocus: false);
                          widget.controller.highlightEnabledNotifier.value =
                              !enabled;
                        },
                        tooltip: 'Mark flagged widgets',
                        toggled: enabled,
                      ),
                    ),
                  if (!isMinimized) _moreButton(theme),
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

  /// Measured fit of the header title, cached for one set of inputs: a
  /// drag rebuilds the header every frame. The theme and the inherited
  /// style are part of the key, since `Sleuth.updateTheme` can change a
  /// font size or a spacing while the card is open.
  ({
    double width,
    TextScaler scaler,
    bool vm,
    bool debug,
    SleuthThemeData theme,
    TextStyle inherited,
  })?
  _titleFitFor;
  ({bool title, _RunLabelSize label})? _titleFit;

  /// The paw, "Sleuth" and the run label, stepped down to the width the
  /// controls leave: all three, then without the "Sleuth" text (the paw
  /// keeps the label), then the short run label, then its dot alone.
  /// Widths are measured with the header's clamped text scale; the run
  /// label never ellipsizes, and its semantics always carry the full text.
  Widget _headerTitle(SleuthThemeData theme, bool vmConnected) {
    final debug = widget.isDebugMode;
    final mode = debug ? 'Debug' : 'Profile';
    final titleStyle = TextStyle(
      color: theme.textPrimary,
      fontSize: theme.fontBase,
      fontWeight: FontWeight.bold,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final scaler = MediaQuery.textScalerOf(context);
        // Text merges the inherited style (Material's letter spacing), so
        // the measurement does too.
        final inherited = DefaultTextStyle.of(context).style;
        final key = (
          width: constraints.maxWidth,
          scaler: scaler,
          vm: vmConnected,
          debug: debug,
          theme: theme,
          inherited: inherited,
        );
        var fit = _titleFit;
        if (fit == null || _titleFitFor != key) {
          double measure(String text, TextStyle style) {
            final painter = TextPainter(
              text: TextSpan(text: text, style: inherited.merge(style)),
              textDirection: TextDirection.ltr,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            final width = painter.width;
            painter.dispose();
            return width;
          }

          final gap = theme.spacingXs;
          const paw = 14.0;
          final labelStyle = _RunLabel.textStyle(theme);
          final chrome = _RunLabel.chromeWidth(theme);
          final full =
              chrome + measure(_RunLabel.text(mode, vmConnected), labelStyle);
          final short = chrome + measure(mode, labelStyle);
          final title = measure('Sleuth', titleStyle) + gap;
          final room = constraints.maxWidth - paw - gap;
          fit = title + full <= room
              ? (title: true, label: _RunLabelSize.full)
              : full <= room
              ? (title: false, label: _RunLabelSize.full)
              : short <= room
              ? (title: false, label: _RunLabelSize.short)
              : (title: false, label: _RunLabelSize.dot);
          _titleFit = fit;
          _titleFitFor = key;
        }
        return Row(
          children: [
            Icon(Icons.pets, size: 14, color: theme.textPrimary),
            SizedBox(width: theme.spacingXs),
            if (fit.title) ...[
              // The header node carries the name.
              ExcludeSemantics(
                child: Text(
                  'Sleuth',
                  style: titleStyle,
                  maxLines: 1,
                  softWrap: false,
                ),
              ),
              SizedBox(width: theme.spacingXs),
            ],
            _RunLabel(mode: mode, vmConnected: vmConnected, size: fit.label),
          ],
        );
      },
    );
  }

  /// The header's More button. It opens and closes the menu, and keyboard
  /// focus returns to it when the menu closes.
  Widget _moreButton(SleuthThemeData theme) {
    final radius = BorderRadius.circular(theme.radiusLg);
    return Semantics(
      key: _moreKey,
      label: 'More',
      button: true,
      expanded: _menuOpen,
      onTap: _toggleMenu,
      excludeSemantics: true,
      child: SleuthFocusInkWell(
        focusNode: _moreFocus,
        onTap: _toggleMenu,
        borderRadius: radius,
        builder: (context, showFocus) => SizedBox(
          width: 36,
          height: _controlRowHeight,
          child: Center(
            child: SleuthFocusOutline(
              show: showFocus,
              color: theme.checkboxActive,
              borderRadius: radius,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _menuOpen
                      ? theme.checkboxActive.withValues(alpha: 0.22)
                      : null,
                  borderRadius: radius,
                ),
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: Icon(
                    Icons.more_horiz,
                    size: 16,
                    color: theme.textTertiary,
                  ),
                ),
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
    // The only signal on screen while minimized: red when a critical
    // card is among them.
    final critical = visible.any((i) => i.severity == IssueSeverity.critical);
    final color = critical ? theme.severityCritical : theme.severityWarning;
    final tinted = critical
        ? theme.severityCriticalText
        : theme.severityWarningText;
    return Semantics(
      label:
          '$count issue${count == 1 ? '' : 's'}'
          '${critical ? ', critical' : ''}',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.badgeFill(color),
          borderRadius: BorderRadius.circular(theme.radiusLg),
          border: Border.all(color: color),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Text(
            '$count',
            style: TextStyle(
              color: theme.badgeTextOn(color, tinted: tinted),
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
    bool? toggled,
  }) {
    return Semantics(
      label: tooltip,
      value: value,
      toggled: toggled,
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

  Widget _buildIssuesList(_ListModel model) {
    // The list rebuilds only when the issue set changes. Each card's
    // recurrence badge re-reads `recurrenceTrends` on the scan pulse by
    // itself, so a tick that leaves the issues unchanged rebuilds badges,
    // not cards.
    {
      {
        final theme = SleuthTheme.of(context);
        final issues = model.issues;
        // An expanded card outlives its issue, so the empty states wait
        // until it is collapsed.
        final expanded = _frozen != null;
        if (issues.isEmpty && !expanded) {
          _clearShown();
          // The next list starts at the top.
          _listScroll.dropKeptOffset();
          // Fills the card's body as the list would, so the card keeps
          // its height.
          return Align(
            alignment: Alignment.topCenter,
            child: SingleChildScrollView(child: _statusLine(emptyList: true)),
          );
        }

        // Severity filter, then collapse, then hide: the same list
        // `_pruneStaleState` keys against. See [applyOverlayFilters].
        final visibleIssues = model.visible;

        if (visibleIssues.isEmpty && !expanded) {
          _clearShown();
          // The next list starts at the top.
          _listAtTop = true;
          _listScroll.dropKeptOffset();
          final allHidden = model.unfiltered.isEmpty;
          return _EmptyListMessage(
            message: allHidden
                ? 'All ${model.unhidden.length} '
                      '${model.unhidden.length == 1 ? 'issue' : 'issues'} hidden'
                : 'No issues match the severity filter',
            actionLabel: allHidden ? 'Show hidden' : 'Reset',
            onAction: allHidden
                ? () => setState(() => _showHidden = true)
                : _showAllSeverities,
          );
        }

        // The freeze zone only orders the cards; the status row counts
        // the flow list, whatever is expanded.
        //
        // The held order runs first, so the freeze snapshot captures
        // what the user saw and new cards enter the flow below it.
        _screenReader =
            MediaQuery.accessibleNavigationOf(context) ||
            SemanticsBinding.instance.semanticsEnabled;
        final held = holdIssueOrder(
          visibleIssues: visibleIssues,
          heldKeys: _heldKeys,
          heldSeverities: _heldSeverities,
          promote: !_screenReader,
          newAtTop: !_screenReader,
        );
        _recordHeldOrder(held);
        final heldIssues = held.issues;
        final order = applyFreezeZone(
          visibleIssues: heldIssues,
          frozen: _frozen,
        );
        final orderedIssues = order.issues;
        final frozenCards = order.frozen ?? const <FrozenCard>[];

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
        // name). Repeats get an occurrence suffix, which keys the sliver
        // child and the expansion; the held order, the new-card accent
        // and hiding use the shared key.
        final listKeys = order.keys;
        // What a related row's reveal and link state read.
        _shownIssues = orderedIssues;
        _shownKeys = listKeys;
        final orderedIndexByKey = <String, int>{
          for (var i = 0; i < listKeys.length; i++) listKeys[i]: i,
        };

        final list = Listener(
          // Touches on the list hold back a pending reorder.
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onListPointerDown,
          onPointerMove: (_) => _onListActivity(),
          onPointerUp: _onListPointerUp,
          onPointerCancel: _onListPointerUp,
          onPointerSignal: (_) => _onListActivity(),
          onPointerPanZoomStart: (_) => _onListActivity(),
          onPointerPanZoomUpdate: (_) => _onListActivity(),
          // Scrolls that reach no Listener (a screen reader's scroll
          // action) also hold it back, and report the offset.
          child: NotificationListener<ScrollNotification>(
            onNotification: _onListScroll,
            child: ListView.builder(
              controller: _listScroll,
              // The grip sits over the bottom-right corner; the last
              // card scrolls clear of it.
              padding: EdgeInsets.fromLTRB(
                theme.spacingSm,
                theme.spacingSm,
                theme.spacingSm,
                48,
              ),
              itemCount: orderedIssues.length,
              // While a related row reveals a card, a Hide hands focus on,
              // or the bar hands focus back to a crosshair, every card
              // builds so an off-screen one can scroll itself into view.
              // Its replacement, scrollCacheExtent, is not in Flutter 3.32.
              // ignore: deprecated_member_use
              cacheExtent:
                  _revealKey != null ||
                      _focusKey != null ||
                      _crosshairFocusIssue != null
                  ? 1e6
                  : null,
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
                final issueKey = listKeys[index];
                final rebuildType = _rebuildTypeOf(issue);
                final frozenCard = index < frozenCards.length
                    ? frozenCards[index]
                    : null;
                final stale = !(frozenCard?.reported ?? true);
                final locatable = !stale && _isLocatableIssue(issue);
                // The bar replaces the card once the lookup finds the
                // widget, so a selected card is one still finding it.
                final finding =
                    locatable && !_barOpen && _isSelectedCard(issue, issueKey);

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

                // The build's index, rows and keys: a tap that arrives
                // after a newer issue list was published still freezes
                // the rows the user saw.
                final capturedIndex = index;
                final capturedOrdered = orderedIssues;
                final capturedKeys = listKeys;

                return IssueCard(
                  key: ValueKey(listKeys[index]),
                  issue: issue,
                  recurrenceTrendOf: () =>
                      widget.controller.recurrenceTrends[issue.stableId ??
                          issue.title],
                  scanTick: widget.controller.scanTickNotifier,
                  initiallyExpanded: frozenCard?.expanded ?? false,
                  collapseEpoch: _collapseEpoch,
                  onExpandedChanged: (expanded) {
                    setState(() {
                      if (expanded) {
                        _frozen = _expandInZone(
                          issueKey,
                          capturedIndex,
                          issue,
                          capturedOrdered,
                          capturedKeys,
                        );
                        return;
                      }
                      final frozen = _frozen;
                      if (frozen == null) return;
                      final next = [
                        for (final card in frozen)
                          card.key == issueKey
                              ? (
                                  key: card.key,
                                  issue: card.issue,
                                  expanded: false,
                                  reported: card.reported,
                                )
                              : card,
                      ];
                      if (next.any((card) => card.expanded)) {
                        _frozen = next;
                        return;
                      }
                      // 1→0: release the zone so the next expand captures
                      // a fresh one. The order on screen becomes the held
                      // order, so nothing moves under the finger; a
                      // pending change waits for the next quiet period.
                      _frozen = null;
                      _heldKeys = [
                        ...{for (final i in capturedOrdered) listKeyFor(i)},
                      ];
                    });
                  },
                  locatable: locatable,
                  stale: stale,
                  finding: finding,
                  crosshairFocusEpoch:
                      _isCardOf(
                        _crosshairFocusIssue,
                        _crosshairFocusKey,
                        issue,
                        issueKey,
                      )
                      ? _crosshairFocusEpoch
                      : 0,
                  crosshairKeyboardFocus: _crosshairKeyboardFocus,
                  onCrosshairFocused: (scrolled) {
                    _crosshairFocusStarted = true;
                    final epoch = _crosshairFocusEpoch;
                    scrolled.whenComplete(() {
                      if (mounted && epoch == _crosshairFocusEpoch) {
                        setState(_clearCrosshairFocus);
                      }
                    });
                  },
                  onHighlightChanged: locatable
                      ? (checked) =>
                            _onHighlightChanged(checked, issueKey, issue)
                      : null,
                  jankCorrelated: _cachedJankKeys.contains(
                    issue.stableId ?? issue.title,
                  ),
                  downstreamIssues: downstream,
                  parentIssues: parents,
                  suppressedParentCount: suppressedParentCount,
                  onLearnMore:
                      IssueExplanationBuilder.explain(issue.stableId) != null
                      ? () => setState(() {
                          _detailStableId = issue.stableId;
                          _detailContextIssue = issue;
                          _showDetail = true;
                          _layerOpener = issueKey;
                        })
                      : null,
                  onAskAi: widget.controller.config.aiChat != null
                      ? () => setState(() {
                          _chatIssueKey = _chatKeyFor(issue);
                          _chatIssue = issue;
                          _showAiChat = true;
                          _layerOpener = issueKey;
                        })
                      : null,
                  onCopy: () => _copyIssue(issue),
                  onHide: () =>
                      _hideIssue(issue, index: capturedIndex, stale: stale),
                  isNew: _newKeyTimers.containsKey(listKeyFor(issue)),
                  lastSeenOf: () => widget.controller.lastSeenAt(issue),
                  relatedLinkOf: _relatedLinkOf,
                  onOpenRelated: _openRelated,
                  // The screen can change without the issue list
                  // changing (a kept card, a screen with no issues), so
                  // the count and the tap check it each time.
                  onSeeRebuildStats: _showsRebuildStats(issue)
                      ? () {
                          if (!_onCurrentScreen(issue)) return;
                          _onSeeAllRebuildsTap();
                          if (_showRebuildStats) _layerOpener = issueKey;
                        }
                      : null,
                  rebuildStatsTotalOf: () =>
                      _onCurrentScreen(issue) ? _rebuildTotal() : 0,
                  onSeeStartup: issue.stableId == 'slow_startup_ttff'
                      ? () => setState(() {
                          _showStartupDetail = true;
                          _layerOpener = issueKey;
                        })
                      : null,
                  whyItRebuilds: kDebugMode && rebuildType != null,
                  rebuildCauseOf:
                      rebuildType != null &&
                          widget.controller.isRebuildHookInstalled
                      ? () => _rebuildCause(rebuildType, issue)
                      : null,
                  rebuildCauseUnavailable:
                      widget.controller.config.enableDebugCallbacks
                      ? 'Rebuilds are not counted: '
                            'advanced.rebuildAttribution is off, or '
                            'DevTools holds the rebuild callback.'
                      : null,
                  onCopyText: _copyText,
                  notUseful: widget.controller.isNotUseful(issue),
                  onNotUsefulChanged: (marked) => _setNotUseful(issue, marked),
                  revealEpoch: issueKey == _revealKey ? _revealEpoch : 0,
                  revealInline: issueKey == _revealKey ? _revealInline : null,
                  onRevealed: (scrolled) {
                    _revealStarted = true;
                    scrolled.whenComplete(() {
                      if (mounted && _revealKey == issueKey) {
                        setState(_endReveal);
                      }
                    });
                  },
                  focusEpoch: issueKey == _focusKey ? _focusEpoch : 0,
                  onFocused: (scrolled) {
                    _focusStarted = true;
                    scrolled.whenComplete(() {
                      if (mounted && _focusKey == issueKey) {
                        setState(() => _focusKey = null);
                      }
                    });
                  },
                );
              },
            ),
          ),
        );
        // The list keeps its place in the tree whether or not the row
        // shows, so a scan that only flips the row keeps the scroll offset
        // and each card's state.
        return Column(
          children: [
            if (model.narrowed)
              _ShowingRow(
                shown: visibleIssues.length,
                total: model.unfiltered.length,
                onShowAll: _showAllSeverities,
              ),
            Expanded(key: const ValueKey('issue-list'), child: list),
          ],
        );
      }
    }
  }
}

// ─── Status Row ─────────────────────────────────────────────────────────

/// The cards behind the status row and the list, worked out once per
/// issue change: severity filter, then collapse, then hide.
class _ListModel {
  _ListModel(this.issues, OverlayUiState ui) {
    visible = ui.visibleIssues(issues);
    final allSeverities = {...IssueSeverity.values};
    unfiltered = applyOverlayFilters(
      issues,
      severities: allSeverities,
      hiddenKeys: ui.hiddenKeys,
    );
    // The default-state list (every severity, nothing hidden). Stale
    // hidden keys that match nothing leave it unchanged.
    unhidden = applyOverlayFilters(
      issues,
      severities: allSeverities,
      hiddenKeys: const {},
    );
    // A chip counts the cards its severity shows under the current
    // filter. Turning a severity off can surface an effect that was
    // collapsed under one of its cards, so a disabled severity is counted
    // with itself added to the filter.
    for (final issue in visible) {
      severityCounts.update(issue.severity, (n) => n + 1, ifAbsent: () => 1);
    }
    for (final severity in IssueSeverity.values) {
      if (ui.severityFilter.contains(severity)) continue;
      final withSeverity = applyOverlayFilters(
        issues,
        severities: {...ui.severityFilter, severity},
        hiddenKeys: ui.hiddenKeys,
      );
      severityCounts[severity] = withSeverity
          .where((i) => i.severity == severity)
          .length;
    }
  }

  /// The reported issues.
  final List<PerformanceIssue> issues;

  /// The cards the list shows.
  late final List<PerformanceIssue> visible;

  /// The cards with every severity on and hidden cards left out.
  late final List<PerformanceIssue> unfiltered;

  /// The cards with every severity on and nothing hidden.
  late final List<PerformanceIssue> unhidden;

  final Map<IssueSeverity, int> severityCounts = {};

  /// A severity filter leaves cards out. Hidden cards are counted in the
  /// More menu, not here.
  bool get narrowed => visible.length < unfiltered.length;
}

/// The row under the header: the severity chips, which are the headline
/// and the filter, and the frame rate at the end.
class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.controller,
    required this.chromeScale,
    required this.severityCounts,
    required this.enabledSeverities,
    required this.onToggleSeverity,
    required this.firstChipKey,
  });

  final SleuthController controller;

  /// Chrome text scale (1.0 to 1.3); the row's minimum height grows with
  /// it.
  final double chromeScale;

  final Map<IssueSeverity, int> severityCounts;
  final Set<IssueSeverity> enabledSeverities;
  final ValueChanged<IssueSeverity> onToggleSeverity;

  /// Goes on whichever chip comes first.
  final GlobalKey firstChipKey;

  static const _order = [
    IssueSeverity.critical,
    IssueSeverity.warning,
    IssueSeverity.ok,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    // A disabled severity keeps its chip so it can be turned back on, even
    // when it has no cards now.
    final shown = [
      for (final severity in _order)
        if ((severityCounts[severity] ?? 0) > 0 ||
            !enabledSeverities.contains(severity))
          severity,
    ];
    return SleuthTextScaleClamp(
      maxScaleFactor: kChromeMaxTextScale,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: _FloatingIssuesCardState._controlRowHeight * chromeScale,
        ),
        child: Padding(
          padding: EdgeInsets.only(
            left: theme.spacingSm,
            right: theme.spacingLg,
          ),
          // One line: the chips scroll sideways when they do not fit, so
          // the row keeps its height in a squeezed card and the frame rate
          // stays at the end.
          child: Row(
            children: [
              Expanded(
                child: shown.isEmpty
                    // No card is counted: the row names the state the
                    // status line explains.
                    ? SleuthListenableBuilder(
                        listenable: controller.runStateNotifier,
                        // A container, or the label lands on the overlay's
                        // full-screen node.
                        builder: (_) => Semantics(
                          container: true,
                          child: Text(
                            statusRowLabel(
                              statusKindOf(controller.runStateNotifier.value),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: theme.textSecondary,
                              fontSize: theme.fontLg,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final (i, severity) in shown.indexed)
                              Padding(
                                padding: EdgeInsets.only(
                                  right: theme.spacingXxs,
                                ),
                                child: _SeverityChip(
                                  key: i == 0 ? firstChipKey : null,
                                  severity: severity,
                                  count: severityCounts[severity] ?? 0,
                                  selected: enabledSeverities.contains(
                                    severity,
                                  ),
                                  onTap: () => onToggleSeverity(severity),
                                ),
                              ),
                          ],
                        ),
                      ),
              ),
              SizedBox(width: theme.spacingSm),
              _FpsText(controller: controller),
            ],
          ),
        ),
      ),
    );
  }
}

/// The frame rate at the end of the status row: the throughput estimate,
/// which stays steady on an idle screen, or a dash while the first frames
/// arrive.
class _FpsText extends StatelessWidget {
  const _FpsText({required this.controller});

  final SleuthController controller;

  /// Frames in the buffer before a rate shows.
  static const int _warmupFrameCount = 3;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return ValueListenableBuilder<FrameStatsBuffer>(
      valueListenable: controller.frameStatsNotifier,
      builder: (_, buffer, _) {
        final target = controller.config.fpsTarget;
        final warming = buffer.length < _warmupFrameCount;
        final fps = buffer.throughputFps
            .clamp(0.0, target.toDouble())
            .toStringAsFixed(0);
        // A container, or the label lands on the overlay's full-screen node.
        return Semantics(
          container: true,
          label: warming ? 'Frame rate pending' : '$fps frames per second',
          excludeSemantics: true,
          child: Text(
            warming ? '— fps' : '$fps fps',
            style: TextStyle(
              color: theme.textTertiary,
              fontSize: theme.fontBase,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        );
      },
    );
  }
}

/// How much of the run label the header has room for.
enum _RunLabelSize {
  /// "Profile · VM".
  full,

  /// "Profile".
  short,

  /// The dot alone.
  dot,
}

/// The header's run label: how the app was built and whether Sleuth has
/// its VM service link, with a dot in the severity text colours.
class _RunLabel extends StatelessWidget {
  const _RunLabel({
    required this.mode,
    required this.vmConnected,
    required this.size,
  });

  /// "Debug" or "Profile".
  final String mode;
  final bool vmConnected;
  final _RunLabelSize size;

  static TextStyle textStyle(SleuthThemeData theme) => TextStyle(
    color: theme.textSecondary,
    fontSize: theme.fontXs,
    fontWeight: FontWeight.w600,
  );

  /// The full label's text.
  static String text(String mode, bool vmConnected) =>
      '$mode · ${vmConnected ? 'VM' : 'no VM'}';

  /// Width the pill adds around its text: padding, border, dot and gap.
  static double chromeWidth(SleuthThemeData theme) =>
      2 * theme.spacingMd + 2 + _dot + theme.spacingXs;

  static const double _dot = 7;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Semantics(
      label: '$mode run, ${vmConnected ? 'VM connected' : 'no VM link'}',
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: theme.cardDivider),
          borderRadius: BorderRadius.circular(theme.radiusXxl),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: theme.spacingMd,
            vertical: theme.spacingXxs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Filled with the VM, a ring without it, so the state does
              // not rest on colour once the text is shortened.
              DecoratedBox(
                decoration: vmConnected
                    ? BoxDecoration(
                        color: theme.severityGraphicColor(IssueSeverity.ok),
                        shape: BoxShape.circle,
                      )
                    : BoxDecoration(
                        border: Border.all(
                          color: theme.severityGraphicColor(
                            IssueSeverity.warning,
                          ),
                          width: 1.5,
                        ),
                        shape: BoxShape.circle,
                      ),
                child: const SizedBox(width: _dot, height: _dot),
              ),
              if (size != _RunLabelSize.dot) ...[
                SizedBox(width: theme.spacingXs),
                Text(
                  size == _RunLabelSize.short ? mode : text(mode, vmConnected),
                  style: textStyle(theme),
                  maxLines: 1,
                  softWrap: false,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// "Showing X of Y" above the list while a severity is turned off, with
/// Show all, which turns every severity back on.
class _ShowingRow extends StatelessWidget {
  const _ShowingRow({
    required this.shown,
    required this.total,
    required this.onShowAll,
  });

  final int shown;
  final int total;
  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(left: theme.spacingLg, right: theme.spacingXs),
      child: Row(
        children: [
          Expanded(
            // Read out when a chip changes the count.
            child: Semantics(
              liveRegion: true,
              child: Text(
                'Showing $shown of $total',
                style: TextStyle(
                  color: theme.textSecondary,
                  fontSize: theme.fontMd,
                ),
              ),
            ),
          ),
          Semantics(
            button: true,
            label: 'Show all',
            onTap: onShowAll,
            container: true,
            excludeSemantics: true,
            child: GestureDetector(
              onTap: onShowAll,
              behavior: HitTestBehavior.opaque,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: theme.spacingSm),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      'Show all',
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
          ),
        ],
      ),
    );
  }
}

// ─── Debug Mode Banner ──────────────────────────────────────────────────

/// A severity chip in the status row: the count and its word, which
/// toggles the severity filter. On, it is filled and shows the filled
/// severity icon; off, it is outlined in [SleuthThemeData.textQuaternary]
/// with the outlined icon, so the state does not rest on colour alone. The
/// hit box is at least 48 x 48.
class _SeverityChip extends StatelessWidget {
  const _SeverityChip({
    super.key,
    required this.severity,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final IssueSeverity severity;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final accent = theme.severityColor(severity);
    final tinted = theme.severityTextColor(severity);
    final name = switch (severity) {
      IssueSeverity.critical => 'critical',
      IssueSeverity.warning => 'warning',
      IssueSeverity.ok => 'ok',
    };
    final icon = switch ((severity, selected)) {
      (IssueSeverity.critical, true) => Icons.error,
      (IssueSeverity.critical, false) => Icons.error_outline,
      (IssueSeverity.warning, true) => Icons.warning,
      (IssueSeverity.warning, false) => Icons.warning_amber,
      (IssueSeverity.ok, true) => Icons.check_circle,
      (IssueSeverity.ok, false) => Icons.check_circle_outline,
    };
    final foreground = selected
        ? theme.badgeTextOn(accent, tinted: tinted)
        : theme.textTertiary;
    // The outline and icon carry the hue (red, orange, green); the count
    // keeps the darker text shade.
    final graphic = selected
        ? theme.severityGraphicColor(severity)
        : theme.textTertiary;
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
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Center(
            widthFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 30),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: selected ? theme.badgeFill(accent) : null,
                  borderRadius: BorderRadius.circular(theme.radiusFull),
                  border: Border.all(
                    color: selected ? graphic : theme.textQuaternary,
                    width: 1.5,
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.only(
                    left: theme.spacingSm,
                    right: theme.spacingMd,
                    top: theme.spacingXs,
                    bottom: theme.spacingXs,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 14, color: graphic),
                      SizedBox(width: theme.spacingXs),
                      Text(
                        '$count $name',
                        style: TextStyle(
                          color: foreground,
                          fontSize: theme.fontLg,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
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
