import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../controller/sleuth_controller.dart';
import '../models/performance_issue.dart';
import '../models/frame_stats.dart';
import '../models/frame_verdict.dart';
import '../models/widget_highlight.dart';
import 'issue_card.dart';
import 'ai_chat_page.dart';
import 'issue_encyclopedia_page.dart';
import 'guide_page.dart';
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
  });

  final SleuthController controller;
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
  bool _showDetail = false;
  String? _detailStableId;
  bool _showAiChat = false;
  String? _chatIssueStableId;
  final Map<String, List<AiChatMessage>> _chatHistories = {};

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
    super.dispose();
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
    };
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final topPadding = MediaQuery.paddingOf(context).top;
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    final maxAllowedHeight = screenSize.height - topPadding - 20;
    final cardHeight = (_cardHeight ?? screenSize.height * 0.55)
        .clamp(_minCardHeight, maxAllowedHeight);
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
        if (!_showGuide && !_showDetail && !_showAiChat)
          Positioned(
            left: clamped.dx,
            top: clamped.dy,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                _buildCardBody(effectiveWidth, cardHeight, theme, screenSize),
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
              }),
              scrollToStableId: _detailStableId,
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
      ],
    );
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
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: effectiveWidth,
        maxHeight: cardHeight,
      ),
      child: Material(
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        color: theme.cardBackground,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(screenSize, theme),
            _StatusRow(controller: widget.controller),
            Divider(color: theme.border, height: 1),
            _WarningBanners(
              exportFeedbackVisible: _exportFeedbackVisible,
              highlightNotFoundVisible: _highlightNotFoundVisible,
              isDeepInstrumentationActive:
                  widget.controller.isDeepInstrumentationActive,
            ),
            Flexible(child: RepaintBoundary(child: _buildIssuesList())),
            _CardFooter(
              controller: widget.controller,
              onExport: _exportToClipboard,
              onEncyclopedia: () => setState(() {
                _detailStableId = null;
                _showDetail = true;
              }),
            ),
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

  Widget _buildHeader(Size screenSize, SleuthThemeData theme) {
    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          _cardOffset = (_cardOffset ?? Offset.zero) + details.delta;
          _cardOffset = _clampOffset(screenSize, _cachedTopPadding,
              _cachedEffectiveWidth, _cachedKeyboardHeight);
        });
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
        padding: EdgeInsets.fromLTRB(
            10, theme.spacingSm, theme.spacingXs, theme.spacingXs),
        child: Row(
          children: [
            const Text('🐕', style: TextStyle(fontSize: 14)),
            SizedBox(width: theme.spacingXs),
            Expanded(
              child: Text(
                'Sleuth',
                style: TextStyle(
                  color: theme.textPrimary,
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
                  color: connected ? theme.badgeVmBg : theme.badgeFrameBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  connected ? 'VM+' : 'FRAME',
                  style: TextStyle(
                    color: connected ? theme.badgeVmText : theme.badgeFrameText,
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
                  color: theme.badgeDbgBg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'DBG',
                  style: TextStyle(
                    color: theme.badgeDbgText,
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            // Guide button
            _headerIconButton(
              icon: Icons.help_outline,
              color: theme.textTertiary,
              onTap: () => setState(() => _showGuide = true),
              tooltip: 'Guide',
            ),
            // Highlight overlay toggle
            ValueListenableBuilder<bool>(
              valueListenable: widget.controller.highlightEnabledNotifier,
              builder: (_, enabled, __) => _headerIconButton(
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
        width: 44,
        height: 44,
        child: Center(child: Icon(icon, color: color, size: 16)),
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
              style: TextStyle(color: theme.severityOk, fontSize: 11),
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
        final visibleIssues = issues
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
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  SizedBox(width: theme.spacingXxs),
                  Text(
                    'FPS',
                    style: TextStyle(color: theme.textTertiary, fontSize: 10),
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
                      style: TextStyle(color: theme.severityOk, fontSize: 11),
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
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Text('⚠️', style: TextStyle(fontSize: 12)),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    'Debug mode — data inaccurate.\nRun: flutter run --profile',
                    style:
                        TextStyle(color: theme.bannerDebugText, fontSize: 10),
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
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Text('🔬', style: TextStyle(fontSize: 12)),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    'Instrumentation active — rebuild/paint counts useful for '
                    'attribution. Timings not representative of real performance.',
                    style: TextStyle(
                        color: theme.bannerInstrumentationText, fontSize: 10),
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
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.check_circle,
                    color: theme.bannerSuccessText, size: 12),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    'Snapshot copied to clipboard',
                    style:
                        TextStyle(color: theme.bannerSuccessText, fontSize: 10),
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
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.visibility_off,
                    color: theme.bannerWarningText, size: 12),
                SizedBox(width: theme.spacingSm),
                Expanded(
                  child: Text(
                    'Widget not currently visible. Navigate to the screen where this issue occurs.',
                    style:
                        TextStyle(color: theme.bannerWarningText, fontSize: 10),
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
  });

  final SleuthController controller;
  final VoidCallback onExport;
  final VoidCallback onEncyclopedia;

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
          GestureDetector(
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
          SizedBox(width: theme.spacingXs),
          GestureDetector(
            onTap: onExport,
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              width: 32,
              height: 32,
              child: Center(
                child:
                    Icon(Icons.ios_share, color: theme.textTertiary, size: 16),
              ),
            ),
          ),
          SizedBox(width: theme.spacingXs),
          Text(
            'Export JSON',
            style: TextStyle(color: theme.textTertiary, fontSize: 10),
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
                    fontSize: 10,
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
                fontSize: 10,
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
                fontSize: 10,
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
                fontSize: 10,
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
