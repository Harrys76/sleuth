import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show PredictiveBackEvent, SystemNavigator;

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
/// - System back closes the innermost open overlay layer (focused text
///   field, full-screen page, Hidden list, then the dashboard) before the
///   app sees it; with nothing open, back goes to the app untouched.
///
/// Back handling runs through [WidgetsBindingObserver.didPopRoute]: the
/// overlay registers its observer before the app's `WidgetsApp`, so it is
/// asked first. An observer the app registers before `runApp` is asked
/// before the overlay. On Android the overlay also claims predictive back
/// gestures while a layer is open and requests
/// [SystemNavigator.setFrameworkHandlesBack] after each layer change; on
/// Flutter versions that offer a predictive swipe to every observer, an
/// app route that can pop may pop together with the overlay layer.
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
  double _lastBottomInset = 0;

  /// Key of the card's State, which implements [OverlayLayerHost].
  final GlobalKey _cardKey = GlobalKey();

  /// [OverlayUiState.dashboardOpen] seen by the last rebuild.
  bool _dashboardOpen = false;

  bool _backRequestScheduled = false;

  @override
  void initState() {
    super.initState();
    if (!kReleaseMode) {
      WidgetsBinding.instance.addObserver(this);
      widget.controller.themeOverride.addListener(_onThemeChanged);
      _dashboardOpen = widget.controller.overlayUiState.dashboardOpen;
      widget.controller.overlayUiState.addListener(_onUiStateChanged);
      widget.controller.initialize().then((_) {
        if (mounted) {
          _attachDisplayRefreshRate();
          widget.controller.startTreeScanning(context);
        }
      });
    }
  }

  void _onThemeChanged() {
    if (mounted) setState(() {});
  }

  void _onUiStateChanged() {
    if (!mounted) return;
    final open = widget.controller.overlayUiState.dashboardOpen;
    if (open == _dashboardOpen) return;
    setState(() => _dashboardOpen = open);
    _onLayersChanged();
  }

  bool get _layerOpen => widget.controller.config.showOverlay && _dashboardOpen;

  /// Closes the innermost open layer. Returns false when the dashboard is
  /// closed, so the app handles the back.
  bool _closeInnermostLayer() {
    if (!_layerOpen) return false;
    final Object? host = _cardKey.currentState;
    if (host is OverlayLayerHost && host.closeInnermostLayer()) return true;
    widget.controller.overlayUiState.dashboardOpen = false;
    return true;
  }

  /// After an overlay layer opens or closes, asks Android to route back
  /// to the framework while a layer is open. `WidgetsApp` resets the flag
  /// on its own navigation notifications, so the request is repeated on
  /// every layer change, once per frame. Never cleared from here.
  void _onLayersChanged() {
    if (kReleaseMode ||
        _backRequestScheduled ||
        defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    _backRequestScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _backRequestScheduled = false;
      if (!mounted || !_layerOpen) return;
      try {
        SystemNavigator.setFrameworkHandlesBack(true).catchError((Object _) {});
      } catch (_) {
        // Best effort: the platform may not support the call.
      }
    });
  }

  @override
  Future<bool> didPopRoute() async {
    if (kReleaseMode) return false;
    return _closeInnermostLayer();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) =>
      !kReleaseMode && _layerOpen;

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {}

  @override
  void handleCommitBackGesture() {
    _closeInnermostLayer();
  }

  @override
  void handleCancelBackGesture() {}

  void _attachDisplayRefreshRate() {
    final view = View.maybeOf(context);
    if (view == null) return;
    widget.controller.attachDisplayRefreshRate(view.display.refreshRate);
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    _attachDisplayRefreshRate();
    final view = View.of(context);
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
    final theme =
        themeOverride ??
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
                widget.controller.refreshHighlightRects();
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
            if (_layerOpen)
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
                            key: _cardKey,
                            controller: widget.controller,
                            onClose: () =>
                                widget.controller.overlayUiState.dashboardOpen =
                                    false,
                            onLayersChanged: _onLayersChanged,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else if (widget.controller.config.showOverlay)
              Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                  child: Localizations(
                    locale: const Locale('en', 'US'),
                    delegates: const [
                      DefaultMaterialLocalizations.delegate,
                      DefaultWidgetsLocalizations.delegate,
                    ],
                    // Painted once the persisted state has loaded, so the
                    // button never jumps from its default spot.
                    child: ValueListenableBuilder<bool>(
                      valueListenable: widget.controller.uiStateReady,
                      builder: (_, ready, _) => !ready
                          ? const SizedBox.shrink()
                          : TriggerButton(
                              issuesNotifier: widget.controller.issuesNotifier,
                              vmConnectedNotifier:
                                  widget.controller.vmConnectedNotifier,
                              frameStatsNotifier:
                                  widget.controller.frameStatsNotifier,
                              isDebugMode: widget.controller.isDebugMode,
                              fpsTarget: widget.controller.config.fpsTarget,
                              uiState: widget.controller.overlayUiState,
                              initialAlignment: widget
                                  .controller
                                  .config
                                  .triggerButtonAlignment,
                              initialOffset:
                                  widget.controller.config.triggerButtonOffset,
                              onTap: () =>
                                  widget
                                          .controller
                                          .overlayUiState
                                          .dashboardOpen =
                                      true,
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
    widget.controller.overlayUiState.removeListener(_onUiStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    Sleuth.notifyControllerDisposed(widget.controller);
    widget.controller.dispose();
    super.dispose();
  }
}
