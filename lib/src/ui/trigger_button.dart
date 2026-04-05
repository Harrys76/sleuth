import 'package:flutter/material.dart';

import '../models/frame_stats.dart';
import '../models/performance_issue.dart';
import 'sleuth_theme.dart';

/// Draggable 🐕 trigger button with issue count badge and live FPS number.
///
/// - Green: no issues / FPS ≥ 83% of target
/// - Amber: warnings only / FPS 50–83% of target
/// - Red: critical issues / FPS < 50% of target
/// - ⚠️ badge: debug mode
class TriggerButton extends StatefulWidget {
  const TriggerButton({
    super.key,
    required this.issuesNotifier,
    required this.vmConnectedNotifier,
    required this.frameStatsNotifier,
    required this.isDebugMode,
    required this.onTap,
    this.fpsTarget = 60,
  });

  final ValueNotifier<List<PerformanceIssue>> issuesNotifier;
  final ValueNotifier<bool> vmConnectedNotifier;
  final ValueNotifier<FrameStatsBuffer> frameStatsNotifier;
  final bool isDebugMode;
  final VoidCallback onTap;
  final int fpsTarget;

  @override
  State<TriggerButton> createState() => _TriggerButtonState();
}

class _TriggerButtonState extends State<TriggerButton> {
  Offset? _position;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _position ??= Offset(
          (constraints.maxWidth - 72).clamp(0, constraints.maxWidth - 56),
          (constraints.maxHeight * 0.4).clamp(0, constraints.maxHeight - 78),
        );
        final theme = SleuthTheme.of(context);
        return GestureDetector(
          onPanUpdate: (details) {
            setState(() {
              final newPos = _position! + details.delta;
              _position = Offset(
                newPos.dx.clamp(0, constraints.maxWidth - 56),
                newPos.dy.clamp(0, constraints.maxHeight - 78),
              );
            });
          },
          onTap: widget.onTap,
          child: Container(
            margin: EdgeInsets.only(left: _position!.dx, top: _position!.dy),
            width: 56,
            height: 78,
            child: ValueListenableBuilder<List<PerformanceIssue>>(
              valueListenable: widget.issuesNotifier,
              builder: (context, issues, _) {
                final hasCritical =
                    issues.any((i) => i.severity == IssueSeverity.critical);
                final hasWarning =
                    issues.any((i) => i.severity == IssueSeverity.warning);

                Color bgColor;
                if (hasCritical) {
                  bgColor = theme.severityCritical;
                } else if (hasWarning) {
                  bgColor = theme.severityWarning;
                } else {
                  bgColor = theme.severityOk;
                }

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Circle button
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: bgColor,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: bgColor.withValues(alpha: 0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          const Text('🐕', style: TextStyle(fontSize: 24)),
                          if (issues.isNotEmpty && !widget.isDebugMode)
                            Positioned(
                              top: 2,
                              right: 2,
                              child: Container(
                                padding: EdgeInsets.all(theme.spacingXs),
                                decoration: BoxDecoration(
                                  color: theme.triggerBadgeBg,
                                  shape: BoxShape.circle,
                                ),
                                child: Text(
                                  '${issues.length}',
                                  style: TextStyle(
                                    color: theme.textPrimary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          if (widget.isDebugMode)
                            Positioned(
                              top: 0,
                              right: 0,
                              child: Container(
                                padding: EdgeInsets.all(theme.spacingXxs),
                                decoration: BoxDecoration(
                                  color: theme.severityWarning,
                                  shape: BoxShape.circle,
                                ),
                                child: const Text('⚠️',
                                    style: TextStyle(fontSize: 10)),
                              ),
                            ),
                        ],
                      ),
                    ),
                    // FPS number below the circle
                    SizedBox(height: theme.spacingXxs),
                    ValueListenableBuilder<FrameStatsBuffer>(
                      valueListenable: widget.frameStatsNotifier,
                      builder: (_, buffer, __) {
                        final fps = buffer.averageFps
                            .clamp(0.0, widget.fpsTarget.toDouble());
                        return Text(
                          fps.toStringAsFixed(0),
                          style: TextStyle(
                            color:
                                theme.fpsColor(fps, target: widget.fpsTarget),
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            shadows: [
                              Shadow(
                                color: theme.shadow,
                                blurRadius: 4,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}
