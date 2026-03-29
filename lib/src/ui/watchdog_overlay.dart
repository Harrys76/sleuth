import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../widget_watchdog.dart' show WidgetWatchdog;
import '../controller/watchdog_controller.dart';
import 'trigger_button.dart';
import 'floating_issues_card.dart';
import 'highlight_overlay.dart';

/// The main overlay widget wrapping the app.
///
/// - Completely hidden in release mode via [kReleaseMode] guard.
/// - Isolated with [RepaintBoundary] to never trigger app repaints.
/// - Shows a draggable trigger button and expandable dashboard.
class WatchdogOverlay extends StatefulWidget {
  const WatchdogOverlay({
    super.key,
    required this.child,
    required this.controller,
  });

  final Widget child;
  final WatchdogController controller;

  @override
  State<WatchdogOverlay> createState() => _WatchdogOverlayState();
}

class _WatchdogOverlayState extends State<WatchdogOverlay> {
  bool _dashboardOpen = false;

  @override
  void initState() {
    super.initState();
    if (!kReleaseMode) {
      widget.controller.initialize().then((_) {
        if (mounted) {
          widget.controller.startTreeScanning(context);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // No-op in release mode
    if (kReleaseMode) return widget.child;

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [
          // The actual app — scoped listener captures only app scroll,
          // not dashboard/overlay scroll. Also updates interaction state.
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              widget.controller.refreshHighlights();
              widget.controller.onScrollActivity(notification);
              return false;
            },
            child: widget.child,
          ),

          // Widget highlight borders (when enabled)
          RepaintBoundary(
            child: HighlightOverlay(
              highlights: widget.controller.highlightsNotifier,
              selectedHighlight: widget.controller.selectedHighlightNotifier,
            ),
          ),

          // Overlay — isolated to prevent app repaints
          if (_dashboardOpen)
            RepaintBoundary(
              child: Localizations(
                locale: const Locale('en', 'US'),
                delegates: const [
                  DefaultMaterialLocalizations.delegate,
                  DefaultWidgetsLocalizations.delegate,
                ],
                child: FloatingIssuesCard(
                  controller: widget.controller,
                  onClose: () => setState(() => _dashboardOpen = false),
                ),
              ),
            )
          else
            Align(
              alignment: Alignment.topLeft,
              child: RepaintBoundary(
                child: Localizations(
                  locale: const Locale('en', 'US'),
                  delegates: const [
                    DefaultMaterialLocalizations.delegate,
                    DefaultWidgetsLocalizations.delegate,
                  ],
                  child: TriggerButton(
                    issuesNotifier: widget.controller.issuesNotifier,
                    vmConnectedNotifier: widget.controller.vmConnectedNotifier,
                    frameStatsNotifier: widget.controller.frameStatsNotifier,
                    isDebugMode: widget.controller.isDebugMode,
                    onTap: () => setState(() => _dashboardOpen = true),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetWatchdog.notifyControllerDisposed(widget.controller);
    widget.controller.dispose();
    super.dispose();
  }
}
