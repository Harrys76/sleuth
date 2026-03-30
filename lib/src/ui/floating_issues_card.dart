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
import 'guide_page.dart';

/// Draggable floating card showing FPS, issue count, and ranked issues list.
///
/// Replaces the old DashboardSheet. Uses [Positioned] within an internal
/// [Stack] for drag positioning. Wrapped in a [RepaintBoundary] by the
/// parent overlay to isolate repaints from the app.
/// Returns a color for the given FPS value relative to [target]:
/// green (≥ 83% of target), amber (≥ 50% of target), red (< 50%).
///
/// At 60 fps target: green ≥ 50, amber ≥ 30 (same as original thresholds).
/// At 120 fps target: green ≥ 100, amber ≥ 60.
Color fpsColor(double fps, {int target = 60}) {
  if (fps >= target * 0.83) return const Color(0xFF10B981);
  if (fps >= target * 0.50) return const Color(0xFFF59E0B);
  return const Color(0xFFEF4444);
}

class FloatingIssuesCard extends StatefulWidget {
  const FloatingIssuesCard({
    super.key,
    required this.controller,
    required this.onClose,
  });

  final WatchdogController controller;
  final VoidCallback onClose;

  @override
  State<FloatingIssuesCard> createState() => _FloatingIssuesCardState();
}

class _FloatingIssuesCardState extends State<FloatingIssuesCard> {
  /// Drag offset — applied via inner [Positioned], null until first build.
  Offset? _cardOffset;

  /// Single expanded issue (was a Set in old dashboard).
  String? _expandedIssueId;

  /// Stable ID of the issue whose highlight checkbox is checked.
  String? _selectedIssueId;

  bool _exportFeedbackVisible = false;
  bool _highlightNotFoundVisible = false;
  bool _showGuide = false;

  /// Cached jank-correlated issue keys from verdict, updated via listener.
  Set<String> _cachedJankKeys = const {};

  Timer? _exportFeedbackTimer;
  Timer? _highlightNotFoundTimer;

  double _cardWidth = _defaultCardWidth;
  static const double _defaultCardWidth = 300;
  static const double _minCardWidth = 220;
  static const double _minCardHeight = 250;

  /// User-set card height. Null = default (55% of screen).
  double? _cardHeight;

  @override
  void initState() {
    super.initState();
    widget.controller.verdictNotifier.addListener(_onVerdictChanged);
    widget.controller.issuesNotifier.addListener(_onVerdictChanged);
    widget.controller.issuesNotifier.addListener(_pruneStaleState);
    _onVerdictChanged();
  }

  @override
  void dispose() {
    widget.controller.verdictNotifier.removeListener(_onVerdictChanged);
    widget.controller.issuesNotifier.removeListener(_onVerdictChanged);
    widget.controller.issuesNotifier.removeListener(_pruneStaleState);
    _exportFeedbackTimer?.cancel();
    _highlightNotFoundTimer?.cancel();
    super.dispose();
  }

  void _onVerdictChanged() {
    final newKeys = _matchingIssueKeys(widget.controller.verdictNotifier.value);
    if (!setEquals(newKeys, _cachedJankKeys)) {
      setState(() => _cachedJankKeys = newKeys);
    }
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
    };
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final screenSize = mq.size;
    final topPadding = mq.padding.top;
    final defaultCardHeight = screenSize.height * 0.55;
    final maxAllowedHeight = screenSize.height - topPadding - 20;
    final cardHeight = (_cardHeight ?? defaultCardHeight)
        .clamp(_minCardHeight, maxAllowedHeight);

    // Effective width clamped to screen — computed, not mutated during build.
    final maxCardWidth = screenSize.width;
    final effectiveWidth = _cardWidth.clamp(_minCardWidth, maxCardWidth);

    // Initialize position to right side on first build.
    // 5px right margin = handle visual (5px overflow) flush with screen edge.
    _cardOffset ??= Offset(
      screenSize.width - effectiveWidth - 5,
      screenSize.height * 0.30,
    );

    // Clamp to screen bounds — reserve 5px so resize handle visual stays on screen.
    // At full width the handle clips (nothing wider to resize to).
    final rightReserve =
        (screenSize.width - effectiveWidth - 5).clamp(0.0, screenSize.width);
    final clamped = Offset(
      _cardOffset!.dx.clamp(0.0, rightReserve),
      _cardOffset!.dy.clamp(topPadding, screenSize.height - 100),
    );

    return Stack(
      children: [
        if (!_showGuide)
          Positioned(
            left: clamped.dx,
            top: clamped.dy,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // The card itself
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: effectiveWidth,
                    maxHeight: cardHeight,
                  ),
                  child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(16),
                    color: const Color(0xF51E1E2E),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildHeader(screenSize),
                        _buildStatusRow(),
                        const Divider(color: Color(0xFF374151), height: 1),

                        // Warning banners
                        if (kDebugMode) _buildDebugWarning(),
                        if (kDebugMode &&
                            widget.controller.isDeepInstrumentationActive)
                          _buildInstrumentationWarning(),
                        if (_exportFeedbackVisible)
                          _buildExportFeedbackBanner(),
                        if (_highlightNotFoundVisible)
                          _buildHighlightNotFoundBanner(),

                        // Issues list — boundary isolates repaints
                        Flexible(
                            child: RepaintBoundary(child: _buildIssuesList())),

                        // Footer
                        _buildFooter(),
                      ],
                    ),
                  ),
                ),
                // Bottom-right corner resize handle — follows card radius
                Positioned(
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
                          _cardWidth = (_cardWidth + details.delta.dx).clamp(
                              _minCardWidth, screenSize.width - clamped.dx);
                          _cardHeight = (cardHeight + details.delta.dy)
                              .clamp(_minCardHeight, maxAllowedHeight);
                        });
                      },
                      child: CustomPaint(
                        painter: const _CornerGripPainter(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (_showGuide)
          Positioned.fill(
            child: GuidePage(
              onClose: () => setState(() => _showGuide = false),
            ),
          ),
      ],
    );
  }

  // ─── Header ──────────────────────────────────────────────────────────

  Widget _buildHeader(Size screenSize) {
    return GestureDetector(
      onPanUpdate: (details) {
        setState(
            () => _cardOffset = (_cardOffset ?? Offset.zero) + details.delta);
      },
      onDoubleTap: () {
        setState(() {
          final fullWidth = screenSize.width;
          if (_cardWidth >= fullWidth - 1) {
            // Restore to default
            _cardWidth = _defaultCardWidth;
          } else {
            // Maximize — edge to edge
            _cardWidth = fullWidth;
            _cardOffset = Offset(0, _cardOffset?.dy ?? screenSize.height * 0.3);
          }
        });
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
        child: Row(
          children: [
            const Text('🐕', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 4),
            const Expanded(
              child: Text(
                'Watchdog',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // VM+ / FRAME badge
            ValueListenableBuilder<bool>(
              valueListenable: widget.controller.vmConnectedNotifier,
              builder: (_, connected, __) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: connected
                      ? const Color(0xFF065F46)
                      : const Color(0xFF1E3A5F),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  connected ? 'VM+' : 'FRAME',
                  style: TextStyle(
                    color: connected
                        ? const Color(0xFF6EE7B7)
                        : const Color(0xFF93C5FD),
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            // DBG badge
            if (kDebugMode && widget.controller.isDebugCallbacksActive)
              Container(
                margin: const EdgeInsets.only(left: 3),
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF5B21B6),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'DBG',
                  style: TextStyle(
                    color: Color(0xFFC4B5FD),
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            // Guide button
            _headerIconButton(
              icon: Icons.help_outline,
              onTap: () => setState(() => _showGuide = true),
            ),
            // Highlight overlay toggle
            ValueListenableBuilder<bool>(
              valueListenable: widget.controller.highlightEnabledNotifier,
              builder: (_, enabled, __) => _headerIconButton(
                icon: enabled ? Icons.layers : Icons.layers_outlined,
                color:
                    enabled ? const Color(0xFF3B82F6) : const Color(0xFF9CA3AF),
                onTap: () {
                  final newValue = !enabled;
                  widget.controller.highlightEnabledNotifier.value = newValue;
                  if (!newValue) {
                    widget.controller.clearSelectedHighlight();
                  }
                },
              ),
            ),
            // Close button
            _headerIconButton(
              icon: Icons.close,
              onTap: widget.onClose,
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerIconButton({
    required IconData icon,
    required VoidCallback onTap,
    Color color = const Color(0xFF9CA3AF),
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, color: color, size: 16),
      ),
    );
  }

  // ─── Status Row ──────────────────────────────────────────────────────

  Widget _buildStatusRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          // FPS number (color-coded)
          ValueListenableBuilder<FrameStatsBuffer>(
            valueListenable: widget.controller.frameStatsNotifier,
            builder: (_, buffer, __) {
              final target = widget.controller.config.fpsTarget;
              final fps = buffer.averageFps.clamp(0.0, target.toDouble());
              final color = fpsColor(fps, target: target);
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    fps.toStringAsFixed(0),
                    style: TextStyle(
                      color: color,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 2),
                  const Text(
                    'FPS',
                    style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
                  ),
                ],
              );
            },
          ),
          const Spacer(),
          // Issue count + severity dot
          ValueListenableBuilder<List<PerformanceIssue>>(
            valueListenable: widget.controller.issuesNotifier,
            builder: (_, issues, __) {
              if (issues.isEmpty) {
                return const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle,
                        color: Color(0xFF10B981), size: 14),
                    SizedBox(width: 4),
                    Text(
                      '0 issues',
                      style: TextStyle(color: Color(0xFF10B981), fontSize: 11),
                    ),
                  ],
                );
              }
              final hasCritical =
                  issues.any((i) => i.severity == IssueSeverity.critical);
              final severityColor = hasCritical
                  ? const Color(0xFFEF4444)
                  : const Color(0xFFF59E0B);
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
                  const SizedBox(width: 4),
                  Text(
                    '${issues.length} issue${issues.length == 1 ? '' : 's'}',
                    style: TextStyle(color: severityColor, fontSize: 11),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  // ─── Warning Banners ─────────────────────────────────────────────────

  Widget _buildDebugWarning() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF92400E),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Text('⚠️', style: TextStyle(fontSize: 12)),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Debug mode — data inaccurate.\nRun: flutter run --profile',
              style: TextStyle(color: Color(0xFFFCD34D), fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstrumentationWarning() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF5B21B6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Text('🔬', style: TextStyle(fontSize: 12)),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Instrumentation active — rebuild/paint counts useful for '
              'attribution. Timings not representative of real performance.',
              style: TextStyle(color: Color(0xFFDDD6FE), fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExportFeedbackBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF065F46),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Icon(Icons.check_circle, color: Color(0xFF6EE7B7), size: 12),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Snapshot copied to clipboard',
              style: TextStyle(color: Color(0xFF6EE7B7), fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHighlightNotFoundBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF78350F),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Row(
        children: [
          Icon(Icons.visibility_off, color: Color(0xFFFCD34D), size: 12),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              'Widget not currently visible. Navigate to the screen where this issue occurs.',
              style: TextStyle(color: Color(0xFFFCD34D), fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }

  // ─── Issues List ─────────────────────────────────────────────────────

  Widget _buildIssuesList() {
    return ValueListenableBuilder<List<PerformanceIssue>>(
      valueListenable: widget.controller.issuesNotifier,
      builder: (_, issues, __) {
        if (issues.isEmpty) {
          return const Center(
            child: Text(
              '✅ No issues detected',
              style: TextStyle(color: Color(0xFF10B981), fontSize: 11),
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
                  padding: const EdgeInsets.all(6),
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

  // ─── Footer ──────────────────────────────────────────────────────────

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFF374151), width: 1),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            onPressed: _exportToClipboard,
            icon:
                const Icon(Icons.ios_share, color: Color(0xFF9CA3AF), size: 16),
            tooltip: 'Export session snapshot',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          const Text(
            'Export JSON',
            style: TextStyle(color: Color(0xFF9CA3AF), fontSize: 10),
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
          Expanded(
            child: Text(
              [
                if (confirmed > 0) '$confirmed confirmed',
                if (heuristic > 0) '$heuristic heuristic',
              ].join(' · '),
              style: const TextStyle(
                color: Color(0xFF9CA3AF),
                fontSize: 10,
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
  const _CornerGripPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF9CA3AF)
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
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
