import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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
import '../utils/issue_explanation_builder.dart';
import 'sleuth_theme.dart';

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
    this.isDebugMode = kDebugMode,
  });

  final SleuthController controller;
  final VoidCallback onClose;

  /// Whether we are in debug mode. Defaults to [kDebugMode].
  /// Exposed as a param so tests can override it.
  @visibleForTesting
  final bool isDebugMode;

  @override
  State<FloatingIssuesCard> createState() => _FloatingIssuesCardState();
}

enum _CardWindowState { normal, minimized, maximized }

class _FloatingIssuesCardState extends State<FloatingIssuesCard> {
  /// Drag offset — applied via inner [Positioned], null until first build.
  Offset? _cardOffset;

  /// Single expanded issue (was a Set in old dashboard).
  String? _expandedIssueId;

  /// Stable ID of the issue whose highlight checkbox is checked.
  String? _selectedIssueId;

  bool _exportFeedbackVisible = false;
  bool _highlightNotFoundVisible = false;
  // ignore: prefer_final_fields
  bool _rebuildSessionGoneVisible = false;
  // ignore: prefer_final_fields
  bool _rebuildPauseDiscardedVisible = false;
  bool _debugBannerDismissed = false;
  bool _showGuide = false;
  bool _showDetail = false;
  bool _showStartupDetail = false;
  // ignore: prefer_final_fields
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

  Timer? _exportFeedbackTimer;
  Timer? _highlightNotFoundTimer;
  Timer? _rebuildSessionGoneTimer;
  Timer? _rebuildPauseDiscardedTimer;

  double _cardWidth = _defaultCardWidth;
  static const double _defaultCardWidth = 300;
  static const double _minCardWidth = 220;
  static const double _minCardHeight = 250;

  // ─── Window state (M2) ─────────────────────────────────────────────
  // ignore: prefer_final_fields
  _CardWindowState _windowState = _CardWindowState.normal;

  /// Stored when transitioning away from normal so restore is exact.
  /// Drag while minimized does NOT update these — restore always returns
  /// to the position the card was in when minimize/maximize was tapped.
  Offset? _preTransitionOffset;
  double? _preTransitionWidth;
  double? _preTransitionHeight;

  /// User-set card height. Null = default (55% of screen).
  double? _cardHeight;

  // Cached for gesture handlers (set each build).
  double _cachedTopPadding = 0;
  double _cachedEffectiveWidth = 0;
  double _cachedKeyboardHeight = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.verdictNotifier.addListener(_onVerdictChanged);
    widget.controller.issuesNotifier.addListener(_onIssuesChanged);
    _onVerdictChanged();
  }

  @override
  void dispose() {
    widget.controller.verdictNotifier.removeListener(_onVerdictChanged);
    widget.controller.issuesNotifier.removeListener(_onIssuesChanged);
    _exportFeedbackTimer?.cancel();
    _highlightNotFoundTimer?.cancel();
    _rebuildSessionGoneTimer?.cancel();
    _rebuildPauseDiscardedTimer?.cancel();
    _preTransitionOffset = null;
    _preTransitionWidth = null;
    _preTransitionHeight = null;
    super.dispose();
  }

  // ─── Window controls (M2) ──────────────────────────────────────────

  void _minimize() {
    if (_windowState == _CardWindowState.minimized) return;
    setState(() {
      _preTransitionOffset ??= _cardOffset;
      _preTransitionWidth ??= _cardWidth;
      _preTransitionHeight ??= _cardHeight;
      _windowState = _CardWindowState.minimized;
      _cardHeight = 54; // Title bar (44) + vertical padding (6+4).
    });
  }

  void _maximize(BuildContext context) {
    if (_windowState == _CardWindowState.maximized) return;
    final size = MediaQuery.sizeOf(context);
    final topPadding = MediaQuery.paddingOf(context).top;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    setState(() {
      _preTransitionOffset ??= _cardOffset;
      _preTransitionWidth ??= _cardWidth;
      _preTransitionHeight ??= _cardHeight;
      _windowState = _CardWindowState.maximized;
      _cardOffset = Offset(16, topPadding + 16);
      _cardWidth = size.width - 32;
      _cardHeight = size.height - topPadding - 32 - keyboard;
    });
  }

  void _restore() {
    setState(() {
      if (_preTransitionOffset != null) _cardOffset = _preTransitionOffset;
      if (_preTransitionWidth != null) _cardWidth = _preTransitionWidth!;
      _cardHeight = _preTransitionHeight; // nullable — default height
      _preTransitionOffset = null;
      _preTransitionWidth = null;
      _preTransitionHeight = null;
      _windowState = _CardWindowState.normal;
    });
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
  void _onIssuesChanged() {
    _pruneStaleState();
    _onVerdictChanged();
  }

  /// Clears expanded/selected state when the referenced issue is no longer present.
  void _pruneStaleState() {
    final issues = widget.controller.issuesNotifier.value;
    final currentKeys = {for (final i in issues) i.stableId ?? i.title};
    var changed = false;
    if (_expandedIssueId != null && !currentKeys.contains(_expandedIssueId)) {
      _expandedIssueId = null;
      changed = true;
    }
    if (_selectedIssueId != null && !currentKeys.contains(_selectedIssueId)) {
      _selectedIssueId = null;
      changed = true;
    }
    if (_showAiChat &&
        _chatIssueStableId != null &&
        !currentKeys.contains(_chatIssueStableId)) {
      _chatIssueStableId = null;
      _showAiChat = false;
      changed = true;
    }
    _chatHistories.removeWhere((key, _) => !currentKeys.contains(key));
    if (changed) setState(() {});
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
    } catch (_) {
      return;
    }
    if (!mounted) return;
    setState(() => _exportFeedbackVisible = true);
    _exportFeedbackTimer?.cancel();
    _exportFeedbackTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _exportFeedbackVisible = false);
    });
  }

  void _onHighlightChanged(
      bool checked, String issueKey, PerformanceIssue issue) {
    if (checked) {
      setState(() => _selectedIssueId = issueKey);
      widget.controller.highlightEnabledNotifier.value = true;
      final found = widget.controller.selectHighlightForIssue(issue);
      if (!found) {
        widget.controller.pendingIssueSelection = issue;
        setState(() => _highlightNotFoundVisible = true);
        _highlightNotFoundTimer?.cancel();
        _highlightNotFoundTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() => _highlightNotFoundVisible = false);
          }
        });
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
    final topPadding = MediaQuery.paddingOf(context).top;
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    final maxAllowedHeight = screenSize.height - topPadding - 20;
    final isMinimized = _windowState == _CardWindowState.minimized;

    // When maximized, dynamically track keyboard so the card shrinks.
    if (_windowState == _CardWindowState.maximized) {
      _cardHeight = screenSize.height - topPadding - 32 - keyboardHeight;
    }

    final cardHeight = (_cardHeight ?? screenSize.height * 0.55)
        .clamp(isMinimized ? 54.0 : _minCardHeight, maxAllowedHeight);
    final effectiveWidth = _cardWidth.clamp(_minCardWidth, screenSize.width);
    _cachedTopPadding = topPadding;
    _cachedEffectiveWidth = effectiveWidth;
    _cachedKeyboardHeight = keyboardHeight;
    final theme = SleuthTheme.of(context);

    _cardOffset ??= Offset(
      screenSize.width - effectiveWidth - 5,
      screenSize.height * 0.30,
    );

    final clamped =
        _clampOffset(screenSize, topPadding, effectiveWidth, keyboardHeight);

    return Stack(
      children: [
        if (!_showGuide &&
            !_showDetail &&
            !_showAiChat &&
            !_showStartupDetail &&
            !_showRebuildStats)
          Positioned(
            left: clamped.dx,
            top: clamped.dy,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _buildCardBody(effectiveWidth, cardHeight, theme, screenSize),
                if (!isMinimized)
                  _buildResizeHandle(
                      screenSize, clamped, cardHeight, maxAllowedHeight, theme),
              ],
            ),
          ),
        if (_showGuide)
          Positioned.fill(
            child: GuidePage(
              onClose: () => setState(() => _showGuide = false),
            ),
          ),
        if (_showDetail)
          Positioned.fill(
            child: IssueEncyclopediaPage(
              onClose: () => setState(() {
                _showDetail = false;
                _detailStableId = null;
                _detailContextIssue = null;
              }),
              scrollToStableId: _detailStableId,
              contextIssue: _detailContextIssue,
            ),
          ),
        if (_showAiChat)
          Positioned.fill(
            child: AiChatPage(
              issue: _findIssueByStableId(_chatIssueStableId!),
              allIssues: widget.controller.issuesNotifier.value,
              adapter: widget.controller.config.aiChat!,
              history: _chatHistories[_chatIssueStableId!] ?? const [],
              onHistoryChanged: (msgs) =>
                  _chatHistories[_chatIssueStableId!] = msgs,
              onClose: () => setState(() {
                _showAiChat = false;
                _chatIssueStableId = null;
              }),
            ),
          ),
        if (_showStartupDetail)
          Positioned.fill(
            child: StartupMetricsPage(
              onClose: () => setState(() => _showStartupDetail = false),
            ),
          ),
        if (_showRebuildStats && _rebuildStatsSnapshot != null)
          Positioned.fill(
            child: RebuildStatsPage(
              routeDisplayName: _rebuildStatsRouteName,
              countsByType: _rebuildStatsSnapshot!,
              onClose: () => setState(() {
                _showRebuildStats = false;
                _rebuildStatsSnapshot = null;
                _rebuildStatsRouteName = null;
              }),
            ),
          ),
        // Transient "Session no longer active" snackbar — rendered as a
        // bottom-aligned overlay so it sits above the card without pushing
        // layout around. Mirrors the _exportFeedback / _highlightNotFound
        // feedback pattern.
        if (_rebuildSessionGoneVisible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 24 + keyboardHeight,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.severityWarning.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(theme.radiusLg),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: theme.spacingLg,
                    vertical: theme.spacingSm,
                  ),
                  child: Text(
                    'Session no longer active',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: theme.fontSm,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
        // H2: when the rebuild stats panel is paused and the active route
        // session changes, the panel auto-resumes and discards its frozen
        // snapshot. Without a user-facing signal this is silent state
        // loss — the user comes back from a tab swap to find their pause
        // gone with no explanation. This snackbar mirrors the "Session
        // no longer active" pattern with a dedicated message.
        if (_rebuildPauseDiscardedVisible)
          Positioned(
            left: 0,
            right: 0,
            bottom: 24 + keyboardHeight,
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.severityWarning.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(theme.radiusLg),
                ),
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: theme.spacingLg,
                    vertical: theme.spacingSm,
                  ),
                  child: Text(
                    'Pause cleared — route changed',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: theme.fontSm,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Triggered by [_RebuildStatsBanner] when its frozen snapshot is
  /// discarded by an automatic resume on route change. Surfaces a 2s
  /// transient notice so the user knows their pause was cleared and isn't
  /// surprised by suddenly-live counts.
  void _onRebuildPauseDiscarded() {
    if (!mounted) return;
    setState(() => _rebuildPauseDiscardedVisible = true);
    _rebuildPauseDiscardedTimer?.cancel();
    _rebuildPauseDiscardedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _rebuildPauseDiscardedVisible = false);
    });
  }

  /// Called when the user taps `See all M →` in the expanded
  /// [_RebuildStatsBanner] panel. When the panel is paused, [overrideCounts]
  /// carries the panel's frozen snapshot and the drilldown opens against
  /// THAT map (panel and drilldown agree on what the user is reading).
  /// Otherwise reads the active [RouteSession] live and snapshots
  /// [RouteSession.rebuildCountsByType] at tap time.
  ///
  /// If the session was cleared between the panel rendering and the tap
  /// (pathological: route change mid-gesture), shows a transient
  /// "Session no longer active" snackbar instead of pushing.
  void _onSeeAllRebuildsTap([Map<String, int>? overrideCounts]) {
    final session = widget.controller.activeRouteSession;
    // Choose the source of truth for the drilldown snapshot:
    //   * paused panel → frozen counts (what the user is currently reading)
    //   * live panel   → fresh read of the session map
    // If both are missing/empty, we have nothing to drill into.
    final source = overrideCounts ?? session?.rebuildCountsByType;
    if (source == null || source.isEmpty) {
      setState(() => _rebuildSessionGoneVisible = true);
      _rebuildSessionGoneTimer?.cancel();
      _rebuildSessionGoneTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _rebuildSessionGoneVisible = false);
      });
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

  Offset _clampOffset(Size screenSize, double topPadding, double effectiveWidth,
      [double keyboardHeight = 0]) {
    final rightReserve =
        (screenSize.width - effectiveWidth - 5).clamp(0.0, screenSize.width);
    return Offset(
      _cardOffset!.dx.clamp(0.0, rightReserve),
      _cardOffset!.dy
          .clamp(topPadding, screenSize.height - 100 - keyboardHeight),
    );
  }

  Widget _buildCardBody(double effectiveWidth, double cardHeight,
      SleuthThemeData theme, Size screenSize) {
    final isMinimized = _windowState == _CardWindowState.minimized;
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
            _buildHeader(screenSize, effectiveWidth, theme),
            if (!isMinimized) ...[
              _StatusRow(controller: widget.controller),
              Divider(color: theme.border, height: 1),
              _WarningBanners(
                exportFeedbackVisible: _exportFeedbackVisible,
                highlightNotFoundVisible: _highlightNotFoundVisible,
                isDeepInstrumentationActive:
                    widget.controller.isDeepInstrumentationActive,
              ),
              if (widget.isDebugMode &&
                  widget.controller.config.showDebugModeBanner &&
                  !_debugBannerDismissed)
                _DebugModeBanner(
                  onDismiss: () => setState(() => _debugBannerDismissed = true),
                ),
              if (Sleuth.startupMetrics != null)
                _StartupMetricsBanner(
                  onTap: () => setState(() => _showStartupDetail = true),
                ),
              // Always-on inline rebuild-stats panel. Renders whenever the
              // active RouteSession has any rebuild counts attributed (any
              // source — debugCallback in debug mode or flutterTimeline in
              // profile mode). v0.15.2: this is the sole rebuild-stats UI
              // surface — the previous `rebuild_hotspot_summary` rollup
              // IssueCard was removed because the inline panel covers both
              // discoverability (low-volume routes can still inspect) and
              // signal (top-3 + live tween makes hot widgets obvious),
              // without colliding with the issue-list ranker or producing
              // KDD-5 inflation false positives in the warning stream.
              _RebuildStatsBanner(
                controller: widget.controller,
                onTap: _onSeeAllRebuildsTap,
                onPauseDiscarded: _onRebuildPauseDiscarded,
              ),
              Flexible(child: RepaintBoundary(child: _buildIssuesList())),
              _CardFooter(
                controller: widget.controller,
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

  Widget _buildResizeHandle(Size screenSize, Offset clamped, double cardHeight,
      double maxAllowedHeight, SleuthThemeData theme) {
    return Positioned(
      right: 0,
      bottom: 0,
      width: 32,
      height: 32,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeDownRight,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanUpdate: (details) {
            setState(() {
              _cardWidth = (_cardWidth + details.delta.dx)
                  .clamp(_minCardWidth, screenSize.width - clamped.dx);
              _cardHeight = (cardHeight + details.delta.dy)
                  .clamp(_minCardHeight, maxAllowedHeight);
            });
          },
          child: CustomPaint(
            painter: _CornerGripPainter(gripColor: theme.gripDots),
          ),
        ),
      ),
    );
  }

  // ─── Header ──────────────────────────────────────────────────────────

  Widget _buildHeader(
      Size screenSize, double effectiveWidth, SleuthThemeData theme) {
    final isMinimized = _windowState == _CardWindowState.minimized;
    final isNormal = _windowState == _CardWindowState.normal;
    // Only show window controls when the card is wide enough to avoid overflow.
    final showWindowControls = effectiveWidth >= 280 || !isNormal;
    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          _cardOffset = (_cardOffset ?? Offset.zero) + details.delta;
          _cardOffset = _clampOffset(screenSize, _cachedTopPadding,
              _cachedEffectiveWidth, _cachedKeyboardHeight);
        });
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            10, theme.spacingSm, theme.spacingXs, theme.spacingXs),
        child: Row(
          children: [
            Icon(Icons.pets, size: 14, color: theme.textPrimary),
            SizedBox(width: theme.spacingXs),
            Expanded(
              child: Text(
                'Sleuth',
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: theme.fontBase,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Issue count badge (visible when minimized so user sees at a glance)
            if (isMinimized)
              ValueListenableBuilder<List<PerformanceIssue>>(
                valueListenable: widget.controller.issuesNotifier,
                builder: (_, issues, __) => issues.isEmpty
                    ? const SizedBox.shrink()
                    : DecoratedBox(
                        decoration: BoxDecoration(
                          color: theme.severityWarning.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(theme.radiusLg),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          child: Text(
                            '${issues.length}',
                            style: TextStyle(
                              color: theme.severityWarning,
                              fontSize: theme.fontXs,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
              ),
            // VM+ / FRAME badge (hidden when minimized to save space)
            if (!isMinimized)
              ValueListenableBuilder<bool>(
                valueListenable: widget.controller.vmConnectedNotifier,
                builder: (_, connected, __) => Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: connected ? theme.badgeVmBg : theme.badgeFrameBg,
                    borderRadius: BorderRadius.circular(theme.radiusLg),
                  ),
                  child: Text(
                    connected ? 'VM+' : 'FRAME',
                    style: TextStyle(
                      color:
                          connected ? theme.badgeVmText : theme.badgeFrameText,
                      fontSize: theme.fontXxs,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            // DBG badge (hidden when minimized)
            if (!isMinimized &&
                kDebugMode &&
                widget.controller.isDebugCallbacksActive)
              Container(
                margin: const EdgeInsets.only(left: 3),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.badgeDbgBg,
                  borderRadius: BorderRadius.circular(theme.radiusLg),
                ),
                child: Text(
                  'DBG',
                  style: TextStyle(
                    color: theme.badgeDbgText,
                    fontSize: theme.fontXxs,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            // Highlight overlay toggle (hidden when minimized)
            if (!isMinimized)
              ValueListenableBuilder<bool>(
                valueListenable: widget.controller.highlightEnabledNotifier,
                builder: (_, enabled, __) => _compactHeaderButton(
                  icon: enabled ? Icons.layers : Icons.layers_outlined,
                  color: enabled ? theme.checkboxActive : theme.textTertiary,
                  onTap: () {
                    final newValue = !enabled;
                    widget.controller.highlightEnabledNotifier.value = newValue;
                    if (!newValue) {
                      widget.controller.clearSelectedHighlight();
                    }
                  },
                  tooltip: enabled ? 'Hide overlay' : 'Show overlay',
                ),
              ),
            // Theme toggle (hidden when minimized, extra-compact to fit
            // alongside DBG badge without overflowing the header Row)
            if (!isMinimized)
              Semantics(
                label: 'Toggle theme',
                button: true,
                child: GestureDetector(
                  onTap: () {
                    final isDark = theme.textPrimary == const Color(0xFFFFFFFF);
                    widget.controller.updateTheme(
                      isDark
                          ? const SleuthThemeData.light()
                          : const SleuthThemeData(),
                    );
                  },
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 20,
                    height: 44,
                    child: Center(
                      child: Icon(
                        theme.textPrimary == const Color(0xFFFFFFFF)
                            ? Icons.light_mode
                            : Icons.dark_mode,
                        color: theme.textTertiary,
                        size: 12,
                      ),
                    ),
                  ),
                ),
              ),
            // Window controls — compact 28px to save header space.
            // Hidden at narrow widths (<280px) to prevent Row overflow.
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
              tooltip: 'Close',
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerIconButton({
    required IconData icon,
    required VoidCallback onTap,
    required Color color,
    String? tooltip,
  }) {
    // GestureDetector instead of IconButton to avoid tooltip OverlayPortal
    // crash — the sleuth overlay sits outside the app's Navigator/Overlay,
    // so OverlayPortal can't find a _RenderTheaterMarker ancestor.
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 36,
        height: 44,
        child: Center(child: Icon(icon, color: color, size: 16)),
      ),
    );
  }

  Widget _compactHeaderButton({
    required IconData icon,
    required VoidCallback onTap,
    required Color color,
    String? tooltip,
  }) {
    return Semantics(
      label: tooltip,
      button: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: 24,
          height: 44,
          child: Center(child: Icon(icon, color: color, size: 12)),
        ),
      ),
    );
  }

  // ─── Issues List ─────────────────────────────────────────────────────

  Widget _buildIssuesList() {
    return ValueListenableBuilder<List<PerformanceIssue>>(
      valueListenable: widget.controller.issuesNotifier,
      builder: (context, issues, __) {
        final theme = SleuthTheme.of(context);
        if (issues.isEmpty) {
          return Center(
            child: Text(
              '✅ No issues detected',
              style: TextStyle(color: theme.severityOk, fontSize: theme.fontMd),
            ),
          );
        }

        // Filter: show only root + standalone issues. Downstream issues
        // (rootCauseId != null) are collapsed under their root card.
        // Exception: if the root was suppressed (not in list), show the
        // downstream as standalone.
        final allIds = {
          for (final i in issues) i.stableId ?? i.title,
        };
        var visibleIssues = issues
            .where(
                (i) => i.rootCauseId == null || !allIds.contains(i.rootCauseId))
            .toList();

        return Column(
          children: [
            _IssuesSummaryBar(issues: visibleIssues),
            Expanded(
              child: ValueListenableBuilder<WidgetHighlight?>(
                valueListenable: widget.controller.selectedHighlightNotifier,
                builder: (_, selectedHighlight, __) => ListView.builder(
                  padding: EdgeInsets.all(theme.spacingSm),
                  itemCount: visibleIssues.length,
                  // Keyed-reorder remount fix: without a
                  // `findChildIndexCallback`, `SliverChildBuilderDelegate`
                  // cannot locate a keyed child whose index has shifted
                  // between builds, so Flutter destroys the Element and
                  // builds a fresh one — which resets `_IssueCardState`
                  // (loses expansion, scroll, and all local UI state).
                  // This hits any issue whose rank position moves, e.g.
                  // when `_applyDurationEscalation` flips an issue from
                  // warning→critical at 30 cycles. Cards are already
                  // `ValueKey`-stamped with `stableId`; this callback
                  // just tells the sliver where each key landed.
                  findChildIndexCallback: (Key key) {
                    if (key is! ValueKey<String>) return null;
                    final target = key.value;
                    for (var i = 0; i < visibleIssues.length; i++) {
                      final issue = visibleIssues[i];
                      if ((issue.stableId ?? issue.title) == target) {
                        return i;
                      }
                    }
                    return null;
                  },
                  itemBuilder: (_, index) {
                    final issue = visibleIssues[index];
                    final locatable = _isLocatableIssue(issue);
                    final issueKey = issue.stableId ?? issue.title;
                    final isHighlighted = selectedHighlight != null &&
                        locatable &&
                        _selectedIssueId == issueKey;

                    // Look up downstream issue objects for root issues.
                    List<PerformanceIssue>? downstream;
                    if (issue.downstreamIds != null &&
                        issue.downstreamIds!.isNotEmpty) {
                      downstream = <PerformanceIssue>[];
                      for (final downId in issue.downstreamIds!) {
                        for (final candidate in issues) {
                          if ((candidate.stableId ?? candidate.title) ==
                              downId) {
                            downstream.add(candidate);
                            break;
                          }
                        }
                      }
                    }

                    return IssueCard(
                      key: ValueKey(issueKey),
                      issue: issue,
                      recurrenceTrend: widget.controller
                          .recurrenceTrends[issue.stableId ?? issue.title],
                      deepInstrumentationActive:
                          widget.controller.isDeepInstrumentationActive,
                      initiallyExpanded: _expandedIssueId == issueKey,
                      onExpandedChanged: (expanded) {
                        _expandedIssueId = expanded ? issueKey : null;
                      },
                      locatable: locatable,
                      highlighted: isHighlighted,
                      onHighlightChanged: locatable
                          ? (checked) =>
                              _onHighlightChanged(checked, issueKey, issue)
                          : null,
                      jankCorrelated: _cachedJankKeys.contains(issueKey),
                      jankFlash: false,
                      downstreamIssues: downstream,
                      onLearnMore:
                          IssueExplanationBuilder.explain(issue.stableId) !=
                                  null
                              ? () => setState(() {
                                    _detailStableId = issue.stableId;
                                    _detailContextIssue = issue;
                                    _showDetail = true;
                                  })
                              : null,
                      onAskAi: widget.controller.config.aiChat != null
                          ? () => setState(() {
                                _chatIssueStableId =
                                    issue.stableId ?? issue.title;
                                _showAiChat = true;
                              })
                          : null,
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─── Status Row ─────────────────────────────────────────────────────────

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.controller});

  final SleuthController controller;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: theme.spacingLg, vertical: theme.spacingXs),
      child: Row(
        children: [
          // FPS number (color-coded)
          ValueListenableBuilder<FrameStatsBuffer>(
            valueListenable: controller.frameStatsNotifier,
            builder: (_, buffer, __) {
              final target = controller.config.fpsTarget;
              final fps = buffer.averageFps.clamp(0.0, target.toDouble());
              final color = theme.fpsColor(fps, target: target);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    fps.toStringAsFixed(0),
                    style: TextStyle(
                      color: color,
                      fontSize: theme.fontXxl,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(width: theme.spacingXxs),
                  Text(
                    'FPS',
                    style: TextStyle(
                        color: theme.textTertiary, fontSize: theme.fontSm),
                  ),
                ],
              );
            },
          ),
          const Spacer(),
          // Issue count + severity dot
          ValueListenableBuilder<List<PerformanceIssue>>(
            valueListenable: controller.issuesNotifier,
            builder: (_, issues, __) {
              if (issues.isEmpty) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle, color: theme.severityOk, size: 14),
                    SizedBox(width: theme.spacingXs),
                    Text(
                      '0 issues',
                      style: TextStyle(
                          color: theme.severityOk, fontSize: theme.fontMd),
                    ),
                  ],
                );
              }
              final hasCritical =
                  issues.any((i) => i.severity == IssueSeverity.critical);
              final severityColor =
                  hasCritical ? theme.severityCritical : theme.severityWarning;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: severityColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: theme.spacingXs),
                  Text(
                    '${issues.length} issue${issues.length == 1 ? '' : 's'}',
                    style:
                        TextStyle(color: severityColor, fontSize: theme.fontMd),
                  ),
                ],
              );
            },
          ),
        ],
      ),
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
      decoration: BoxDecoration(
        color: theme.bannerWarningBg,
      ),
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
              ),
            ),
            SizedBox(width: theme.spacingXs),
            Semantics(
              label: 'Dismiss debug mode banner',
              button: true,
              child: GestureDetector(
                onTap: onDismiss,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 36,
                  height: 36,
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
  const _WarningBanners({
    required this.exportFeedbackVisible,
    required this.highlightNotFoundVisible,
    required this.isDeepInstrumentationActive,
  });

  final bool exportFeedbackVisible;
  final bool highlightNotFoundVisible;
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
            padding:
                EdgeInsets.symmetric(horizontal: 10, vertical: theme.spacingSm),
            decoration: BoxDecoration(
              color: theme.bannerDebugBg,
              borderRadius: BorderRadius.circular(theme.radiusLg),
            ),
            child: Row(
              children: [
                Text('⚠️', style: TextStyle(fontSize: theme.fontBase)),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    'Debug mode — data inaccurate.\nRun: flutter run --profile',
                    style: TextStyle(
                        color: theme.bannerDebugText, fontSize: theme.fontSm),
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
            padding:
                EdgeInsets.symmetric(horizontal: 10, vertical: theme.spacingSm),
            decoration: BoxDecoration(
              color: theme.bannerInstrumentationBg,
              borderRadius: BorderRadius.circular(theme.radiusLg),
            ),
            child: Row(
              children: [
                Text('🔬', style: TextStyle(fontSize: theme.fontBase)),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    'Instrumentation active — rebuild/paint counts useful for '
                    'attribution. Timings not representative of real performance.',
                    style: TextStyle(
                        color: theme.bannerInstrumentationText,
                        fontSize: theme.fontSm),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (exportFeedbackVisible)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: theme.bannerSuccessBg,
              borderRadius: BorderRadius.circular(theme.radiusLg),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle,
                    color: theme.bannerSuccessText, size: 12),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    'Snapshot copied to clipboard',
                    style: TextStyle(
                        color: theme.bannerSuccessText, fontSize: theme.fontSm),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        if (highlightNotFoundVisible)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: theme.bannerWarningBg,
              borderRadius: BorderRadius.circular(theme.radiusLg),
            ),
            child: Row(
              children: [
                Icon(Icons.visibility_off,
                    color: theme.bannerWarningText, size: 12),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    'Widget not currently visible. Navigate to the screen where this issue occurs.',
                    style: TextStyle(
                        color: theme.bannerWarningText, fontSize: theme.fontSm),
                    maxLines: 2,
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

class _CardFooter extends StatelessWidget {
  const _CardFooter({
    required this.controller,
    required this.onExport,
    required this.onEncyclopedia,
    required this.onGuide,
  });

  final SleuthController controller;
  final VoidCallback onExport;
  final VoidCallback onEncyclopedia;
  final VoidCallback onGuide;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(
          horizontal: theme.spacingMd, vertical: theme.spacingXs),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.border, width: 1),
        ),
      ),
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
                width: 32,
                height: 32,
                child: Center(
                  child: Icon(Icons.menu_book_outlined,
                      color: theme.textTertiary, size: 16),
                ),
              ),
            ),
          ),
          SizedBox(width: theme.spacingXs),
          Semantics(
            label: 'Export',
            button: true,
            child: GestureDetector(
              onTap: onExport,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 32,
                height: 32,
                child: Center(
                  child: Icon(Icons.ios_share,
                      color: theme.textTertiary, size: 16),
                ),
              ),
            ),
          ),
          SizedBox(width: theme.spacingXs),
          Semantics(
            label: 'Guide',
            button: true,
            child: GestureDetector(
              onTap: onGuide,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 32,
                height: 32,
                child: Center(
                  child: Icon(Icons.help_outline,
                      color: theme.textTertiary, size: 16),
                ),
              ),
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: controller.suppressedCountNotifier,
            builder: (_, count, __) {
              if (count == 0) return const SizedBox.shrink();
              return Padding(
                padding: EdgeInsets.only(left: theme.spacingMd),
                child: Text(
                  '$count suppressed',
                  style: TextStyle(
                    color: theme.textQuaternary,
                    fontSize: theme.fontSm,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

// ─── Issues Summary Bar ──────────────────────────────────────────────────

class _IssuesSummaryBar extends StatelessWidget {
  const _IssuesSummaryBar({required this.issues});

  final List<PerformanceIssue> issues;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    var critical = 0;
    var warning = 0;
    var ok = 0;
    var confirmed = 0;
    var heuristic = 0;

    for (final issue in issues) {
      switch (issue.severity) {
        case IssueSeverity.critical:
          critical++;
        case IssueSeverity.warning:
          warning++;
        case IssueSeverity.ok:
          ok++;
      }
      if (issue.confidence == IssueConfidence.confirmed) {
        confirmed++;
      } else {
        heuristic++;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.border, width: 1),
        ),
      ),
      child: Row(
        children: [
          if (critical > 0) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: theme.severityCritical,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              '$critical',
              style: TextStyle(
                color: theme.severityCritical,
                fontSize: theme.fontSm,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(width: theme.spacingMd),
          ],
          if (warning > 0) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: theme.severityWarning,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              '$warning',
              style: TextStyle(
                color: theme.severityWarning,
                fontSize: theme.fontSm,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(width: theme.spacingMd),
          ],
          if (ok > 0) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: theme.severityOk,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              '$ok',
              style: TextStyle(
                color: theme.severityOk,
                fontSize: theme.fontSm,
                fontWeight: FontWeight.bold,
              ),
            ),
            SizedBox(width: theme.spacingMd),
          ],
          Expanded(
            child: Text(
              [
                if (confirmed > 0) '$confirmed confirmed',
                if (heuristic > 0) '$heuristic heuristic',
              ].join(' · '),
              style: TextStyle(
                color: theme.textTertiary,
                fontSize: theme.fontSm,
              ),
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
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
            child: Row(
              children: [
                Icon(Icons.rocket_launch_outlined, size: 12, color: color),
                SizedBox(width: theme.spacingXs),
                Expanded(
                  child: Text(
                    parts.join(' \u00B7 '),
                    style: TextStyle(color: color, fontSize: theme.fontSm),
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
    );
  }
}

/// Always-on entry point to the per-route rebuild data. Renders an inline
/// banner whenever the active [RouteSession] has any rebuild attribution,
/// regardless of whether any detector has emitted a warning. This is the
/// sole data-discovery surface for rebuild stats since v0.15.2 — the
/// previous `rebuild_hotspot_summary` rollup IssueCard was removed because
/// (a) the panel covers both the data and the signal, (b) an always-pinned
/// IssueCard collided with the ranker and severity-escalation pipeline,
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
/// **Reactivity:** rebuilds whenever the scan loop produces fresh issues
/// (`issuesNotifier`, which fires after every `_scanTreeInner` — the
/// natural pulse for rebuild-attribution updates) or when the active
/// route session itself changes (`routeHistoryNotifier`, which fires on
/// route push/pop and tab switches). The panel reads
/// `controller.activeRouteSession` at build time, so the union of these
/// two notifiers is sufficient — no extra per-frame work.
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
      widget.controller.issuesNotifier,
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
    widget.controller.routeHistoryNotifier
        .removeListener(_onRouteSessionChanged);
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
    return ListenableBuilder(
      // F3/P3: hoisted merge — see field declaration. Allocating
      // `Listenable.merge(...)` inline here would re-create the wrapper
      // on every build and detach/re-attach both source listeners.
      listenable: _mergedListenable,
      builder: (context, _) {
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
        final counts =
            _paused && _frozenCounts != null ? _frozenCounts! : liveCounts;
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
      // H1: the header is the EASIEST control to hit because the row
      // spans the full panel width — even at its natural ~24dp height
      // the tap surface is roughly 280dp × 24dp, so any reasonable
      // touch lands. We rely on that horizontal generosity rather than
      // forcing a 48dp vertical box (which doubled the panel height
      // and overflowed the cramped overlay budget on small screens).
      // `HitTestBehavior.opaque` makes every pixel of the row hittable.
      child: GestureDetector(
        onTap: _toggleExpanded,
        behavior: HitTestBehavior.opaque,
        child: Row(
          children: [
            Icon(Icons.repeat, size: 12, color: color),
            SizedBox(width: theme.spacingXs),
            Expanded(
              child: Text(
                summary,
                style: TextStyle(color: color, fontSize: theme.fontSm),
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
                color: color.withValues(alpha: 0.5),
                semanticLabel: 'paused',
              ),
            ],
            if (_expanded) ...[
              Semantics(
                label: _paused
                    ? 'Resume live rebuild updates'
                    : 'Pause live rebuild updates',
                button: true,
                // H1: enlarge the pause hit area without ballooning
                // header height. 28dp is ~30% bigger than the natural
                // ~22dp icon footprint and still fits the tightly-
                // budgeted debug overlay. Material's full 48dp ideal
                // would push the panel past the cramped 330dp test
                // budget (and past 446dp on small phones), so this is
                // a deliberate compromise documented in v0.15.2 H1.
                // `HitTestBehavior.opaque` is critical: without it
                // the OUTER header GestureDetector would intercept
                // the tap when the finger lands on the padding rather
                // than on the icon glyph itself, toggling expansion
                // instead of pause/resume.
                child: SizedBox(
                  width: 28,
                  height: 28,
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
              color: color.withValues(alpha: 0.7),
            ),
          ],
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
                    color: color.withValues(alpha: 0.7),
                    fontSize: theme.fontXs,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  typeName,
                  style: TextStyle(
                    color: color,
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
                duration: const Duration(milliseconds: 200),
                builder: (context, value, _) => Text(
                  '\u00d7$value',
                  style: TextStyle(
                    color: color,
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
              color: color.withValues(alpha: 0.7),
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
            // H1: enlarge the see-all hit area without breaking the
            // overlay's tight vertical budget. 24dp is ~70% larger than
            // the natural text-only height (~14dp) and is reliably
            // hittable on a real device, while still respecting the
            // inline-debug-panel context. Material's full 48dp ideal
            // would overflow the panel on small screens — see H1
            // compromise note in `_buildHeaderRow`. `HitTestBehavior
            // .opaque` makes the whole padded box receive taps even
            // where the text doesn't cover it.
            child: SizedBox(
              height: 24,
              child: GestureDetector(
                onTap: () {
                  // C1: pass the panel's frozen snapshot through to the
                  // drilldown when paused, so the drilldown opens against
                  // the same data the user is reading on the panel.
                  widget.onTap(_paused ? _frozenCounts : null);
                },
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: theme.spacingXs,
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: Text(
                      'See all $widgetCount \u2192',
                      style: TextStyle(
                        color: color,
                        fontSize: theme.fontXs,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor: color,
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
