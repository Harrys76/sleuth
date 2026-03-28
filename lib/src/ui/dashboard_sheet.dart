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

  static const double _collapsedHeight = 400;

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
  }

  @override
  void dispose() {
    _tabController.dispose();
    _heightController.dispose();
    super.dispose();
  }

  void _onDragUpdate(DragUpdateDetails details) {
    final screenHeight = MediaQuery.of(context).size.height;
    final expandableHeight = screenHeight - _collapsedHeight;
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

  void _exportToClipboard() {
    final json = widget.controller.exportSnapshotJson();
    Clipboard.setData(ClipboardData(text: json));
    setState(() => _exportFeedbackVisible = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _exportFeedbackVisible = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final topPadding = MediaQuery.of(context).padding.top;
    final maxHeight = screenHeight - topPadding;
    final currentHeight =
        _collapsedHeight + (_sheetFraction * (maxHeight - _collapsedHeight));
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
                return Text(
                  verdict.reason,
                  style: const TextStyle(
                    color: Color(0xFFD1D5DB),
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
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

        return Column(
          children: [
            _IssuesSummaryBar(issues: issues),
            Expanded(
              child: ValueListenableBuilder<WidgetHighlight?>(
                valueListenable: widget.controller.selectedHighlightNotifier,
                builder: (_, selectedHighlight, __) => ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: issues.length,
                  itemBuilder: (_, index) {
                    final issue = issues[index];
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
                      initiallyExpanded: _expandedIssueIds.contains(issueKey),
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
                                setState(() => _selectedIssueId = issueKey);
                                widget.controller.highlightEnabledNotifier
                                    .value = true;
                                final found = widget.controller
                                    .selectHighlightForIssue(issue);
                                if (!found) {
                                  widget.controller.pendingIssueSelection =
                                      issue;
                                }
                              } else {
                                setState(() => _selectedIssueId = null);
                                widget.controller.clearSelectedHighlight();
                              }
                            }
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
    };
  }

  Widget _buildGuideTab() {
    return const SingleChildScrollView(
      padding: EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '🐕 Performance Detective Guide',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 12),
          _GuideStep(
            step: '1',
            title: 'Run in Profile Mode',
            detail: 'flutter run --profile — for accurate data',
          ),
          _GuideStep(
            step: '2',
            title: 'Navigate Your App',
            detail: 'Use as normal. Watchdog monitors every frame.',
          ),
          _GuideStep(
            step: '3',
            title: 'Check the Live Tab',
            detail: 'Watch for red bars — those are janky frames.',
          ),
          _GuideStep(
            step: '4',
            title: 'Review Issues',
            detail: 'Each issue has a severity, confidence, and fix hint.',
          ),
          _GuideStep(
            step: '5',
            title: 'Apply Fixes',
            detail: 'Follow the fix hints. Hot reload to see improvement.',
          ),
        ],
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
