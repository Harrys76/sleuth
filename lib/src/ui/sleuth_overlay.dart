import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../sleuth.dart' show Sleuth;
import '../controller/sleuth_controller.dart';
import 'trigger_button.dart';
import 'floating_issues_card.dart';
import 'highlight_overlay.dart';
import 'sleuth_theme.dart';

/// The main overlay widget wrapping the app.
///
/// - Completely hidden in release mode via [kReleaseMode] guard.
/// - Isolated with [RepaintBoundary] to never trigger app repaints.
/// - Shows a draggable trigger button and expandable dashboard.
class SleuthOverlay extends StatefulWidget {
  const SleuthOverlay({
    super.key,
    required this.child,
    required this.controller,
  });

  final Widget child;
  final SleuthController controller;

  @override
  State<SleuthOverlay> createState() => _SleuthOverlayState();
}

class _SleuthOverlayState extends State<SleuthOverlay>
    with WidgetsBindingObserver {
  bool _dashboardOpen = false;
  double _lastBottomInset = 0;

  @override
  void initState() {
    super.initState();
    if (!kReleaseMode) {
      WidgetsBinding.instance.addObserver(this);
      widget.controller.themeOverride.addListener(_onThemeChanged);
      widget.controller.initialize().then((_) {
        if (mounted) {
          widget.controller.startTreeScanning(context);
        }
      });
    }
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeMetrics() {
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final bottomInset = view.viewInsets.bottom / view.devicePixelRatio;
    if (bottomInset > 0 && _lastBottomInset == 0) {
      widget.controller.onKeyboardVisibilityChanged(visible: true);
    } else if (bottomInset == 0 && _lastBottomInset > 0) {
      widget.controller.onKeyboardVisibilityChanged(visible: false);
    }
    _lastBottomInset = bottomInset;
  }

  @override
  void didChangePlatformBrightness() {
    // Re-resolve auto-detect when system brightness changes.
    // Skip when an explicit override or config theme is set — the user
    // already chose a theme and system changes shouldn't override it.
    if (widget.controller.config.theme == null &&
        widget.controller.themeOverride.value == null) {
      setState(() {});
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.onAppLifecycleChanged(state);
  }

  @override
  void reassemble() {
    super.reassemble();
    widget.controller.notifyReassemble();
  }

  @override
  Widget build(BuildContext context) {
    // No-op in release mode
    if (kReleaseMode) return widget.child;

    final themeOverride = widget.controller.themeOverride.value;
    final theme = themeOverride ??
        widget.controller.config.theme ??
        _resolveTheme(context);

    return Directionality(
      textDirection: TextDirection.ltr,
      child: SleuthTheme(
        data: theme,
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

            // Overlay — isolated to prevent app repaints.
            //
            // [DefaultTextEditingShortcuts] is required because Sleuth mounts
            // its overlay outside any [WidgetsApp]/[MaterialApp], so the
            // default key→intent bindings (backspace → DeleteCharacterIntent,
            // arrow keys, Ctrl+A/C/V/X, Home/End, etc.) would otherwise be
            // absent from the ancestor chain. Without it, any [TextField] in
            // the dashboard (encyclopedia search, AI chat input) silently
            // ignores hardware-keyboard control keys — typing still works
            // because printable characters are inserted by EditableText
            // directly, but backspace and friends do nothing. This is the
            // root cause behind the Android-emulator "can't delete with
            // backspace" bug. See
            // packages/flutter/lib/src/widgets/default_text_editing_shortcuts.dart.
            if (_dashboardOpen)
              RepaintBoundary(
                child: Localizations(
                  locale: const Locale('en', 'US'),
                  delegates: const [
                    DefaultMaterialLocalizations.delegate,
                    DefaultWidgetsLocalizations.delegate,
                  ],
                  child: DefaultTextEditingShortcuts(
                    child: Overlay(
                      initialEntries: [
                        OverlayEntry(
                          builder: (_) => FloatingIssuesCard(
                            controller: widget.controller,
                            onClose: () =>
                                setState(() => _dashboardOpen = false),
                          ),
                        ),
                      ],
                    ),
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
                      vmConnectedNotifier:
                          widget.controller.vmConnectedNotifier,
                      frameStatsNotifier: widget.controller.frameStatsNotifier,
                      isDebugMode: widget.controller.isDebugMode,
                      fpsTarget: widget.controller.config.fpsTarget,
                      initialAlignment:
                          widget.controller.config.triggerButtonAlignment,
                      initialOffset:
                          widget.controller.config.triggerButtonOffset,
                      onTap: () => setState(() => _dashboardOpen = true),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  SleuthThemeData _resolveTheme(BuildContext context) {
    final mqData = MediaQuery.maybeOf(context);
    if (mqData == null) return const SleuthThemeData();
    return mqData.platformBrightness == Brightness.light
        ? const SleuthThemeData.light()
        : const SleuthThemeData();
  }

  @override
  void dispose() {
    widget.controller.themeOverride.removeListener(_onThemeChanged);
    WidgetsBinding.instance.removeObserver(this);
    Sleuth.notifyControllerDisposed(widget.controller);
    widget.controller.dispose();
    super.dispose();
  }
}
