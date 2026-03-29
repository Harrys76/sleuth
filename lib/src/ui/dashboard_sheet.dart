import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/watchdog_controller.dart';
import '../models/performance_issue.dart';
import '../models/frame_stats.dart';
import '../models/frame_verdict.dart';
import '../models/widget_highlight.dart';
import 'issue_card.dart';
import 'frame_chart.dart';

/// Bottom sheet dashboard with 3 tabs: Live, Issues, Guide.
/// Supports drag-to-expand: drag up for full screen, drag down to collapse.
class DashboardSheet extends StatefulWidget {
  const DashboardSheet({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final WatchdogController controller;
  final VoidCallback onClose;

  @override
  State<DashboardSheet> createState() => _DashboardSheetState();
}

class _DashboardSheetState extends State<DashboardSheet>
    with TickerProviderStateMixin {
  late final TabController _tabController;
  late final AnimationController _heightController;
  Animation<double>? _heightAnimation;

  /// 0.0 = collapsed (min height), 1.0 = full screen
  double _sheetFraction = 0.0;

  /// Track which issues are expanded by stableId, so state persists across
  /// scan cycles that update dynamic values in the title.
  final Set<String> _expandedIssueIds = {};

  /// The stable ID of the issue whose checkbox was last checked.
  /// Uses [PerformanceIssue.stableId] (falls back to title) so the
  /// selection survives across scan cycles that update dynamic values.
  String? _selectedIssueId;

  bool _exportFeedbackVisible = false;

  /// Stable IDs of issues currently flashing due to a jank-banner tap.
  /// Cleared automatically after 2 seconds.
  Set<String> _jankFlashIds = {};

  /// Shown when a highlight checkbox is checked but the widget isn't in the tree.
  bool _highlightNotFoundVisible = false;

  /// Interaction context filter for the Issues tab. Null = show all.
  InteractionContext? _interactionFilter;

  /// Cached jank-correlated issue keys from verdict, updated via listener.
  Set<String> _cachedJankKeys = const {};
  int _cachedJankMatchCount = 0;

  /// Cancellable timers for UI feedback (replacing Future.delayed).
  Timer? _exportFeedbackTimer;
  Timer? _jankFlashTimer;
  Timer? _highlightNotFoundTimer;

  static const double _maxCollapsedHeight = 400;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _heightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _heightController.addListener(() {
      final anim = _heightAnimation;
      if (anim != null) {
        setState(() {
          _sheetFraction = anim.value;
        });
      }
    });
    widget.controller.verdictNotifier.addListener(_onVerdictChanged);
    widget.controller.issuesNotifier.addListener(_onVerdictChanged);
    _onVerdictChanged(); // Compute initial cached state
  }

  @override
  void dispose() {
    widget.controller.verdictNotifier.removeListener(_onVerdictChanged);
    widget.controller.issuesNotifier.removeListener(_onVerdictChanged);
    _exportFeedbackTimer?.cancel();
    _jankFlashTimer?.cancel();
    _highlightNotFoundTimer?.cancel();
    _tabController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  void _onVerdictChanged() {
    final newKeys = _matchingIssueKeys(widget.controller.verdictNotifier.value);
    if (!setEquals(newKeys, _cachedJankKeys)) {
      setState(() {
        _cachedJankKeys = newKeys;
        _cachedJankMatchCount = newKeys.length;
      });
    }
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final screenHeight = MediaQuery.of(context).size.height;
    final expandableHeight = screenHeight - _collapsedHeight(context);
    if (expandableHeight <= 0) return;
    final delta = -details.primaryDelta! / expandableHeight;
    setState(() {
      _sheetFraction = (_sheetFraction + delta).clamp(0.0, 1.0);
    });
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final bool expand;
    if (velocity.abs() > 300) {
      expand = velocity < 0; // swipe up = expand
    } else {
      expand = _sheetFraction > 0.5;
    }
    _snapTo(expand ? 1.0 : 0.0);
  }

  void _snapTo(double target) {
    _heightController.value = _sheetFraction;
    _heightAnimation = Tween<double>(
      begin: _sheetFraction,
      end: target,
    ).animate(CurvedAnimation(
      parent: _heightController,
      curve: Curves.easeOutCubic,
    ));
    _heightController.forward(from: 0);
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

  void _onJankBannerTap() {
    final verdict = widget.controller.verdictNotifier.value;
    final keys = _matchingIssueKeys(verdict);
    if (keys.isEmpty) return;

    setState(() => _jankFlashIds = keys);
    _tabController.animateTo(1); // Switch to Issues tab

    _jankFlashTimer?.cancel();
    _jankFlashTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _jankFlashIds = {});
    });
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF3B82F6).withValues(alpha: 0.2)
              : Colors.transparent,
          border: Border.all(
            color: selected ? const Color(0xFF3B82F6) : const Color(0xFF4B5563),
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? const Color(0xFF3B82F6) : const Color(0xFF9CA3AF),
            fontSize: 10,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  double _collapsedHeight(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    return _maxCollapsedHeight.clamp(0.0, screenHeight * 0.65);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final topPadding = MediaQuery.of(context).padding.top;
    final maxHeight = screenHeight - topPadding;
    final collapsed = _collapsedHeight(context);
    final currentHeight =
        collapsed + (_sheetFraction * (maxHeight - collapsed));
    final isExpanded = _sheetFraction > 0.1;

    return Container(
      height: currentHeight,
      margin: EdgeInsets.only(
        left: isExpanded ? 0 : 8,
        right: isExpanded ? 0 : 8,
        bottom: isExpanded ? 0 : 8,
      ),
      child: Material(
        elevation: 16,
        borderRadius: BorderRadius.circular(isExpanded ? 0 : 16),
        color: const Color(0xFF1F2937),
        child: Column(
          children: [
            // Drag handle + header (entire area is draggable)
            GestureDetector(
              onVerticalDragUpdate: _onDragUpdate,
              onVerticalDragEnd: _onDragEnd,
              behavior: HitTestBehavior.opaque,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: const Color(0xFF4B5563),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 4),
                  _buildHeader(),
                ],
              ),
            ),

            // Debug mode warning
            if (kDebugMode) _buildDebugWarning(),

            // Heavy instrumentation warning
            if (kDebugMode && widget.controller.isDeepInstrumentationActive)
              _buildInstrumentationWarning(),

            // Export feedback banner
            if (_exportFeedbackVisible)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF065F46),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.check_circle,
                        color: Color(0xFF6EE7B7), size: 14),
                    SizedBox(width: 8),
                    Text(
                      'Snapshot copied to clipboard',
                      style: TextStyle(color: Color(0xFF6EE7B7), fontSize: 11),
                    ),
                  ],
                ),
              ),

            // Tab bar
            TabBar(
              controller: _tabController,
              indicatorColor: const Color(0xFF3B82F6),
              labelColor: Colors.white,
              unselectedLabelColor: const Color(0xFF9CA3AF),
              tabs: const [
                Tab(text: 'Live'),
                Tab(text: 'Issues'),
                Tab(text: 'Guide'),
              ],
            ),

            // Tab content — expands to fill available space
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildLiveTab(),
                  _buildIssuesTab(),
                  _buildGuideTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
      child: Row(
        children: [
          const Text('🐕', style: TextStyle(fontSize: 20)),
          const SizedBox(width: 8),
          const Text(
            'Widget Watchdog',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const Spacer(),
          // Mode indicator
          ValueListenableBuilder<bool>(
            valueListenable: widget.controller.vmConnectedNotifier,
            builder: (_, connected, __) => Tooltip(
              message: connected
                  ? 'VM Timeline connected — full phase breakdown'
                  : 'Frame timing + structural analysis — accurate in profile mode',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: connected
                      ? const Color(0xFF065F46)
                      : const Color(0xFF1E3A5F),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  connected ? 'VM+' : 'FRAME',
                  style: TextStyle(
                    color: connected
                        ? const Color(0xFF6EE7B7)
                        : const Color(0xFF93C5FD),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
          // Debug callbacks badge
          if (kDebugMode && widget.controller.isDebugCallbacksActive)
            Container(
              margin: const EdgeInsets.only(left: 4),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF5B21B6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text(
                'DBG',
                style: TextStyle(
                  color: Color(0xFFC4B5FD),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          // Export button
          IconButton(
            onPressed: _exportToClipboard,
            icon:
                const Icon(Icons.ios_share, color: Color(0xFF9CA3AF), size: 20),
            tooltip: 'Export session snapshot',
          ),
          // Highlight overlay toggle
          ValueListenableBuilder<bool>(
            valueListenable: widget.controller.highlightEnabledNotifier,
            builder: (_, enabled, __) => IconButton(
              onPressed: () {
                final newValue = !enabled;
                widget.controller.highlightEnabledNotifier.value = newValue;
                if (!newValue) {
                  widget.controller.clearSelectedHighlight();
                }
              },
              icon: Icon(
                enabled ? Icons.layers : Icons.layers_outlined,
                color:
                    enabled ? const Color(0xFF3B82F6) : const Color(0xFF9CA3AF),
                size: 20,
              ),
              tooltip: enabled ? 'Hide highlights' : 'Show highlights',
            ),
          ),
          IconButton(
            onPressed: widget.onClose,
            icon: const Icon(Icons.close, color: Color(0xFF9CA3AF), size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildDebugWarning() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF92400E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Text('⚠️', style: TextStyle(fontSize: 14)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Debug mode — data inaccurate.\nRun: flutter run --profile',
              style: TextStyle(color: Color(0xFFFCD34D), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstrumentationWarning() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF5B21B6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Text('🔬', style: TextStyle(fontSize: 14)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Instrumentation active — rebuild/paint counts useful for '
              'attribution. Timings not representative of real performance.',
              style: TextStyle(color: Color(0xFFDDD6FE), fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveTab() {
    return ValueListenableBuilder<FrameStatsBuffer>(
      valueListenable: widget.controller.frameStatsNotifier,
      builder: (_, buffer, __) => Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // FPS display
            Row(
              children: [
                Text(
                  buffer.averageFps.toStringAsFixed(0),
                  style: TextStyle(
                    color: buffer.averageFps >= 55
                        ? const Color(0xFF10B981)
                        : buffer.averageFps >= 30
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFFEF4444),
                    fontSize: 36,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(width: 4),
                const Text(
                  'FPS',
                  style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 14),
                ),
                const Spacer(),
                Text(
                  'Jank: ${buffer.jankCount}/${buffer.length}',
                  style: const TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Frame chart
            Expanded(child: FrameChart(buffer: buffer)),

            // Jank banner — links to Issues tab
            if (_cachedJankMatchCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: GestureDetector(
                  onTap: _onJankBannerTap,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7F1D1D),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: Color(0xFFFCA5A5), size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$_cachedJankMatchCount issue${_cachedJankMatchCount == 1 ? '' : 's'}'
                            ' may be causing jank',
                            style: const TextStyle(
                                color: Color(0xFFFCA5A5), fontSize: 11),
                          ),
                        ),
                        const Text(
                          'View Issues \u203A',
                          style: TextStyle(
                            color: Color(0xFFFCA5A5),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // Latest verdict
            const SizedBox(height: 8),
            ValueListenableBuilder<FrameVerdict?>(
              valueListenable: widget.controller.verdictNotifier,
              builder: (_, verdict, __) {
                if (verdict == null) {
                  return const Text(
                    'Waiting for frames...',
                    style: TextStyle(color: Color(0xFF6B7280), fontSize: 11),
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      verdict.reason,
                      style: const TextStyle(
                        color: Color(0xFFD1D5DB),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (verdict.topFunctions != null &&
                        verdict.topFunctions!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      for (final f in verdict.topFunctions!.take(3))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            f.chainDisplay != null
                                ? '${f.chainDisplay}: ${f.percentage.toStringAsFixed(0)}%'
                                    '${f.inclusivePercentage != null ? ' (${f.inclusivePercentage!.toStringAsFixed(0)}% incl)' : ''}'
                                : '${f.displayName} (${f.percentage.toStringAsFixed(0)}%)',
                            style: const TextStyle(
                              color: Color(0xFF93C5FD),
                              fontSize: 10,
                              fontFamily: 'monospace',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIssuesTab() {
    return ValueListenableBuilder<List<PerformanceIssue>>(
      valueListenable: widget.controller.issuesNotifier,
      builder: (_, issues, __) {
        if (issues.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('✅', style: TextStyle(fontSize: 32)),
                SizedBox(height: 8),
                Text(
                  'No issues detected',
                  style: TextStyle(color: Color(0xFF10B981), fontSize: 14),
                ),
              ],
            ),
          );
        }

        // Prune stale state that no longer exists in the issue list
        final currentKeys = {for (final i in issues) i.stableId ?? i.title};
        _expandedIssueIds.retainWhere(currentKeys.contains);
        if (_selectedIssueId != null &&
            !currentKeys.contains(_selectedIssueId)) {
          _selectedIssueId = null;
        }

        final filteredIssues = _interactionFilter == null
            ? issues
            : issues
                .where((i) => _interactionFilter == InteractionContext.idle
                    ? (i.interactionContext == null ||
                        i.interactionContext == InteractionContext.idle)
                    : i.interactionContext == _interactionFilter)
                .toList();

        return Column(
          children: [
            _IssuesSummaryBar(issues: filteredIssues),
            // Interaction context filter row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip(
                        'All (${issues.length})',
                        _interactionFilter == null,
                        () => setState(() => _interactionFilter = null)),
                    const SizedBox(width: 6),
                    _filterChip(
                        'Idle (${issues.where((i) => i.interactionContext == null || i.interactionContext == InteractionContext.idle).length})',
                        _interactionFilter == InteractionContext.idle,
                        () => setState(() =>
                            _interactionFilter = InteractionContext.idle)),
                    const SizedBox(width: 6),
                    _filterChip(
                        'Scrolling (${issues.where((i) => i.interactionContext == InteractionContext.scrolling).length})',
                        _interactionFilter == InteractionContext.scrolling,
                        () => setState(() =>
                            _interactionFilter = InteractionContext.scrolling)),
                    const SizedBox(width: 6),
                    _filterChip(
                        'Navigating (${issues.where((i) => i.interactionContext == InteractionContext.navigating).length})',
                        _interactionFilter == InteractionContext.navigating,
                        () => setState(() => _interactionFilter =
                            InteractionContext.navigating)),
                  ],
                ),
              ),
            ),
            // Highlight not-found feedback banner
            if (_highlightNotFoundVisible)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF78350F),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.visibility_off,
                        color: Color(0xFFFCD34D), size: 14),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Widget not currently visible. Navigate to the screen where this issue occurs.',
                        style:
                            TextStyle(color: Color(0xFFFCD34D), fontSize: 11),
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: filteredIssues.isEmpty
                  ? const Center(
                      child: Text(
                        'No issues match the selected filter',
                        style:
                            TextStyle(color: Color(0xFF6B7280), fontSize: 12),
                      ),
                    )
                  : ValueListenableBuilder<WidgetHighlight?>(
                      valueListenable:
                          widget.controller.selectedHighlightNotifier,
                      builder: (_, selectedHighlight, __) => ListView.builder(
                        padding: const EdgeInsets.all(8),
                        itemCount: filteredIssues.length,
                        itemBuilder: (_, index) {
                          final issue = filteredIssues[index];
                          final locatable = _isLocatableIssue(issue);
                          final issueKey = issue.stableId ?? issue.title;
                          final isHighlighted = selectedHighlight != null &&
                              locatable &&
                              _selectedIssueId == issueKey;
                          return IssueCard(
                            key: ValueKey(issueKey),
                            issue: issue,
                            deepInstrumentationActive:
                                widget.controller.isDeepInstrumentationActive,
                            initiallyExpanded:
                                _expandedIssueIds.contains(issueKey),
                            onExpandedChanged: (expanded) {
                              if (expanded) {
                                _expandedIssueIds.add(issueKey);
                              } else {
                                _expandedIssueIds.remove(issueKey);
                              }
                            },
                            locatable: locatable,
                            highlighted: isHighlighted,
                            onHighlightChanged: locatable
                                ? (checked) {
                                    if (checked) {
                                      setState(
                                          () => _selectedIssueId = issueKey);
                                      widget.controller.highlightEnabledNotifier
                                          .value = true;
                                      final found = widget.controller
                                          .selectHighlightForIssue(issue);
                                      if (!found) {
                                        widget.controller
                                            .pendingIssueSelection = issue;
                                        setState(() =>
                                            _highlightNotFoundVisible = true);
                                        _highlightNotFoundTimer?.cancel();
                                        _highlightNotFoundTimer = Timer(
                                            const Duration(seconds: 3), () {
                                          if (mounted) {
                                            setState(() =>
                                                _highlightNotFoundVisible =
                                                    false);
                                          }
                                        });
                                      }
                                    } else {
                                      setState(() => _selectedIssueId = null);
                                      widget.controller
                                          .clearSelectedHighlight();
                                    }
                                  }
                                : null,
                            jankCorrelated: _cachedJankKeys.contains(issueKey),
                            jankFlash: _jankFlashIds.contains(issueKey),
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

  /// Whether an issue can be visually located on screen.
  /// Only structural detectors that produce widget highlights are locatable.
  static bool _isLocatableIssue(PerformanceIssue issue) {
    return switch (issue.category) {
      IssueCategory.layout => true, // IntrinsicHeight/Width
      IssueCategory.build =>
        // Non-lazy list, GlobalKey, KeepAlive — but not setState/rebuild/mediaQuery
        issue.widgetName != null,
      IssueCategory.paint => true, // CustomPainter
      IssueCategory.memory =>
        // Image, KeepAlive — but not memory leak
        issue.widgetName != null,
      IssueCategory.raster => false, // GPU pressure (timeline-only)
      IssueCategory.channel => false, // Platform channel (timeline-only)
      IssueCategory.font => false, // Font loading (timeline-only)
      IssueCategory.network => false, // HTTP timing (no widget tree equivalent)
    };
  }

  Widget _buildGuideTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '\u{1F415} Performance Detective Guide',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          const _GuideStep(
            step: '1',
            title: 'Run in Profile Mode',
            detail: 'flutter run --profile \u2014 for accurate data',
          ),
          const _GuideStep(
            step: '2',
            title: 'Navigate Your App',
            detail: 'Use as normal. Watchdog monitors every frame.',
          ),
          const _GuideStep(
            step: '3',
            title: 'Check the Live Tab',
            detail: 'Watch for red bars \u2014 those are janky frames.',
          ),
          const _GuideStep(
            step: '4',
            title: 'Review Issues',
            detail: 'Each issue has a severity, confidence, and fix hint.',
          ),
          const _GuideStep(
            step: '5',
            title: 'Apply Fixes',
            detail: 'Follow the fix hints. Hot reload to see improvement.',
          ),

          // Color Legend section
          const SizedBox(height: 16),
          const Divider(color: Color(0xFF374151)),
          const SizedBox(height: 12),
          const Text(
            'Color Legend',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Severity',
            style: TextStyle(
              color: Color(0xFF9CA3AF),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          const _LegendRow(
              icon: '\u{1F534}', label: 'Critical \u2014 immediate attention'),
          const _LegendRow(
              icon: '\u{1F7E1}', label: 'Warning \u2014 should investigate'),
          const _LegendRow(icon: '\u{1F7E2}', label: 'OK \u2014 informational'),

          const SizedBox(height: 8),
          const Text(
            'Confidence Badges',
            style: TextStyle(
              color: Color(0xFF9CA3AF),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          _badgeLegendRow(
              'CONFIRMED', const Color(0xFF10B981), 'Directly observed'),
          _badgeLegendRow('LIKELY', const Color(0xFFF59E0B),
              'Runtime + structural evidence'),
          _badgeLegendRow(
              'POSSIBLE', const Color(0xFF6B7280), 'Structural pattern only'),

          const SizedBox(height: 8),
          const Text(
            'Source Accent (left bar)',
            style: TextStyle(
              color: Color(0xFF9CA3AF),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          _colorBarLegendRow(const Color(0xFF10B981), 'VM timeline event'),
          _colorBarLegendRow(const Color(0xFF8B5CF6), 'Debug callback'),
          _colorBarLegendRow(const Color(0xFF6B7280), 'Structural scan'),

          const SizedBox(height: 8),
          const Text(
            'Category Badges',
            style: TextStyle(
              color: Color(0xFF9CA3AF),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              _categoryLegendChip('BUILD', const Color(0xFF3B82F6)),
              _categoryLegendChip('LAYOUT', const Color(0xFFF59E0B)),
              _categoryLegendChip('PAINT', const Color(0xFF10B981)),
              _categoryLegendChip('RASTER', const Color(0xFFEF4444)),
              _categoryLegendChip('MEMORY', const Color(0xFF8B5CF6)),
              _categoryLegendChip('CHANNEL', const Color(0xFF06B6D4)),
              _categoryLegendChip('FONT', const Color(0xFF6B7280)),
              _categoryLegendChip('NETWORK', const Color(0xFFF97316)),
            ],
          ),

          const SizedBox(height: 8),
          const Text(
            'Effort Badges',
            style: TextStyle(
              color: Color(0xFF9CA3AF),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          _badgeLegendRow(
              'QUICK FIX', const Color(0xFF10B981), 'Simple change'),
          _badgeLegendRow(
              'MEDIUM FIX', const Color(0xFFF59E0B), 'Some refactoring'),
          _badgeLegendRow(
              'INVOLVED FIX', const Color(0xFFEF4444), 'Architecture change'),
        ],
      ),
    );
  }

  Widget _badgeLegendRow(String label, Color color, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 8,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            description,
            style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _colorBarLegendRow(Color color, String description) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            description,
            style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _categoryLegendChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _IssuesSummaryBar extends StatelessWidget {
  const _IssuesSummaryBar({required this.issues});

  final List<PerformanceIssue> issues;

  @override
  Widget build(BuildContext context) {
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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Color(0xFF374151), width: 1),
        ),
      ),
      child: Row(
        children: [
          if (critical > 0) ...[
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Color(0xFFEF4444),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              '$critical',
              style: const TextStyle(
                color: Color(0xFFEF4444),
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (warning > 0) ...[
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Color(0xFFF59E0B),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              '$warning',
              style: const TextStyle(
                color: Color(0xFFF59E0B),
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (ok > 0) ...[
            Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(
                color: Color(0xFF10B981),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              '$ok',
              style: const TextStyle(
                color: Color(0xFF10B981),
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(width: 8),
          ],
          const Spacer(),
          if (confirmed > 0) ...[
            Text(
              '$confirmed confirmed',
              style: const TextStyle(
                color: Color(0xFF9CA3AF),
                fontSize: 10,
              ),
            ),
            if (heuristic > 0)
              const Text(
                ' · ',
                style: TextStyle(color: Color(0xFF6B7280), fontSize: 10),
              ),
          ],
          if (heuristic > 0)
            Text(
              '$heuristic heuristic',
              style: const TextStyle(
                color: Color(0xFF9CA3AF),
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }
}

class _GuideStep extends StatelessWidget {
  const _GuideStep({
    required this.step,
    required this.title,
    required this.detail,
  });

  final String step;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: const BoxDecoration(
              color: Color(0xFF3B82F6),
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(
              step,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  detail,
                  style: const TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendRow extends StatelessWidget {
  const _LegendRow({required this.icon, required this.label});

  final String icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 10)),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
          ),
        ],
      ),
    );
  }
}
