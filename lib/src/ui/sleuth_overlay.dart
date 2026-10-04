import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show PredictiveBackEvent, SystemNavigator;

import '../../sleuth.dart' show Sleuth;
import '../controller/sleuth_controller.dart';
import 'trigger_button.dart';
import 'floating_issues_card.dart';
import 'highlight_overlay.dart';
import 'overlay_ui_state.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

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
///
/// Text in the overlay follows the system text scale between 0.8x and
/// 2.0x; the app below keeps the unclamped scale. The theme resolves in
/// this order: the header toggle's light or dark
/// [OverlayUiState.themeMode], `Sleuth.updateTheme`, `SleuthConfig.theme`,
/// then the platform brightness, with the high-contrast presets when the
/// platform asks for high contrast.
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

  /// [OverlayUiState.themeMode] seen by the last rebuild.
  SleuthThemeMode _themeMode = SleuthThemeMode.system;

  bool _backRequestScheduled = false;

  @override
  void initState() {
    super.initState();
    if (!kReleaseMode) {
      WidgetsBinding.instance.addObserver(this);
      widget.controller.themeOverride.addListener(_onThemeChanged);
      _dashboardOpen = widget.controller.overlayUiState.dashboardOpen;
      _themeMode = widget.controller.overlayUiState.themeMode;
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
    final ui = widget.controller.overlayUiState;
    final open = ui.dashboardOpen;
    final mode = ui.themeMode;
    if (open == _dashboardOpen && mode == _themeMode) return;
    final layersChanged = open != _dashboardOpen;
    setState(() {
      _dashboardOpen = open;
      _themeMode = mode;
    });
    if (layersChanged) _onLayersChanged();
  }

  bool get _layerOpen => widget.controller.config.showOverlay && _dashboardOpen;

  /// Closes the innermost open layer. Returns false when the dashboard is
  /// closed or the overlay is gone (a gesture that outlived it), so the
  /// app handles the back.
  bool _closeInnermostLayer() {
    if (!mounted || !_layerOpen) return false;
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
      !kReleaseMode && mounted && _layerOpen;

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
    // Re-resolve the theme; [_resolveTheme] decides whether brightness
    // matters.
    if (mounted) setState(() {});
  }

  @override
  void didChangeAccessibilityFeatures() {
    // High contrast picks the high-contrast presets.
    if (mounted) setState(() {});
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

    final theme = _resolveTheme(context);

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
                child: _clampTextScale(
                  context,
                  Localizations(
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
                                  widget
                                          .controller
                                          .overlayUiState
                                          .dashboardOpen =
                                      false,
                              onLayersChanged: _onLayersChanged,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
            else if (widget.controller.config.showOverlay)
              Align(
                alignment: Alignment.topLeft,
                child: RepaintBoundary(
                  child: _clampTextScale(
                    context,
                    Localizations(
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
                                issuesNotifier:
                                    widget.controller.issuesNotifier,
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
                                initialOffset: widget
                                    .controller
                                    .config
                                    .triggerButtonOffset,
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
              ),
          ],
        ),
      ),
    );
  }

  /// Clamps the overlay's text scale to `0.8..2.0`. Only overlay branches
  /// are wrapped; the app keeps the system scale.
  static Widget _clampTextScale(BuildContext context, Widget child) =>
      SleuthTextScaleClamp(
        minScaleFactor: kOverlayMinTextScale,
        maxScaleFactor: kOverlayMaxTextScale,
        child: child,
      );

  /// The toggle's light or dark mode, then the `Sleuth.updateTheme`
  /// override, then `SleuthConfig.theme`, then the platform brightness.
  /// High contrast picks the high-contrast preset of the chosen
  /// brightness for the toggle and auto cases. Returns const presets (or
  /// the instances the app passed), so the [SleuthTheme] identity only
  /// changes when the choice does.
  SleuthThemeData _resolveTheme(BuildContext context) {
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    switch (widget.controller.overlayUiState.themeMode) {
      case SleuthThemeMode.light:
        return highContrast
            ? const SleuthThemeData.highContrastLight()
            : const SleuthThemeData.light();
      case SleuthThemeMode.dark:
        return highContrast
            ? const SleuthThemeData.highContrastDark()
            : const SleuthThemeData();
      case SleuthThemeMode.system:
        break;
    }
    final override = widget.controller.themeOverride.value;
    if (override != null) return override;
    final configured = widget.controller.config.theme;
    if (configured != null) return configured;
    final light =
        MediaQuery.maybePlatformBrightnessOf(context) == Brightness.light;
    if (highContrast) {
      return light
          ? const SleuthThemeData.highContrastLight()
          : const SleuthThemeData.highContrastDark();
    }
    return light ? const SleuthThemeData.light() : const SleuthThemeData();
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
