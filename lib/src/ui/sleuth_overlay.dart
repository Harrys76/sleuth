import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show PredictiveBackEvent, SystemNavigator;

import '../../sleuth.dart' show Sleuth;
import '../controller/sleuth_controller.dart';
import '../utils/overlay_ownership.dart';
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
/// - While a full-screen page or the Hidden list is open, the app can
///   hold no focus: keys, text input and traversal stay on the page, and
///   the app's focused node gets focus back when the last one closes. The
///   floating card alone leaves the app's focus alone.
///
/// Back handling runs through [WidgetsBindingObserver.didPopRoute]: the
/// overlay registers its observer before the app's `WidgetsApp`, so it is
/// asked first. An observer the app registers before `runApp` is asked
/// before the overlay. On Android the overlay also claims predictive back
/// gestures while a layer is open and requests
/// [SystemNavigator.setFrameworkHandlesBack] after each layer change and
/// after each app navigation while a layer is open; on
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

  /// True while a full-screen page or the Hidden list is open; the app's
  /// semantics are dropped so a screen reader stays on the page.
  final ValueNotifier<bool> _fullScreenLayerOpen = ValueNotifier(false);

  /// Key of the [ExcludeFocus] around the app; it keeps the app's subtree
  /// in place and tells app focus from overlay focus.
  final GlobalKey _appFocusKey = GlobalKey(debugLabel: 'Sleuth app focus');

  /// Whether the app's focus is excluded: [_fullScreenLayerOpen], applied
  /// after the frame that reported the change (the card reports from its
  /// own build).
  bool _appFocusExcluded = false;

  /// The app's primary focus when the exclusion began, restored when it
  /// ends.
  FocusNode? _appFocusBeforeLayer;
  bool _focusSyncScheduled = false;

  @override
  void initState() {
    super.initState();
    if (!kReleaseMode) {
      OverlayOwnership.register(context as Element, _appFocusKey);
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
  /// every layer change, once per frame, and after app navigation while
  /// a layer is open ([_watchAppNavigation]). Never cleared from here.
  void _onLayersChanged() {
    final Object? host = _cardKey.currentState;
    _fullScreenLayerOpen.value =
        _layerOpen && host is OverlayLayerHost && host.openLayerDepth > 0;
    _scheduleFocusSync();
    _requestFrameworkBack();
    _watchAppNavigation();
  }

  // ── App focus while a full-screen layer is open ─────────────────────

  /// Applies [_fullScreenLayerOpen] to the app's focus after the frame:
  /// layer changes are reported from the card's build, where the app's
  /// [ExcludeFocus] cannot be rebuilt.
  void _scheduleFocusSync() {
    if (_focusSyncScheduled) return;
    _focusSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusSyncScheduled = false;
      _syncAppFocus();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Excludes the app's focus when a layer opened, remembering the app's
  /// focused node; when the last layer closed, lets the app take focus
  /// again and, after that rebuild, gives the node its focus back. The
  /// card focuses the page itself.
  void _syncAppFocus() {
    if (!mounted) return;
    final exclude = _fullScreenLayerOpen.value;
    if (exclude == _appFocusExcluded) return;
    if (exclude) {
      // Without app focus now, a node still waiting for its restore (a
      // layer reopened right after closing) is kept.
      final focus = FocusManager.instance.primaryFocus;
      if (focus != null && _isAppFocus(focus)) _appFocusBeforeLayer = focus;
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAppFocus());
    }
    setState(() => _appFocusExcluded = exclude);
  }

  /// Gives the node focused before the layer opened its focus back, when
  /// it is still in the tree and focusable and the app has not taken
  /// focus itself.
  void _restoreAppFocus() {
    // Excluded again: the node waits for the next close.
    if (!mounted || _appFocusExcluded) return;
    final node = _appFocusBeforeLayer;
    _appFocusBeforeLayer = null;
    if (node == null) return;
    final nodeContext = node.context;
    if (nodeContext == null ||
        !nodeContext.mounted ||
        node.parent == null ||
        !node.canRequestFocus) {
      return;
    }
    final current = FocusManager.instance.primaryFocus;
    if (current != null && _isAppFocus(current)) return;
    // A scope (a route with nothing focused inside) gets focus itself,
    // not a child it focused earlier.
    if (node is FocusScopeNode) {
      node.requestScopeFocus();
    } else {
      node.requestFocus();
    }
  }

  /// Whether [node] belongs to the app below the overlay.
  bool _isAppFocus(FocusNode node) {
    final appElement = _appFocusKey.currentContext;
    final nodeContext = node.context;
    if (appElement == null || nodeContext == null || !nodeContext.mounted) {
      return false;
    }
    var inApp = false;
    nodeContext.visitAncestorElements((ancestor) {
      inApp = identical(ancestor, appElement);
      return !inApp;
    });
    return inApp;
  }

  void _requestFrameworkBack() {
    if (!_handlesAndroidBack || _backRequestScheduled) return;
    _backRequestScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _backRequestScheduled = false;
      if (mounted && _layerOpen) _sendFrameworkHandlesBack();
    });
  }

  bool get _handlesAndroidBack =>
      !kReleaseMode && defaultTargetPlatform == TargetPlatform.android;

  void _sendFrameworkHandlesBack() {
    try {
      SystemNavigator.setFrameworkHandlesBack(true).catchError((Object _) {});
    } catch (_) {
      // Best effort: the platform may not support the call.
    }
  }

  // ── App navigation while a layer is open ────────────────────────────

  /// The app's navigators, null until found after the layer opens, and
  /// their [_navigationState] as of the last frame.
  List<NavigatorState>? _appNavigators;
  List<int> _appNavigation = const [];
  bool _watchingNavigation = false;

  /// While a layer is open, checks after every frame whether an app
  /// navigator's history changed. A change means the app navigated and
  /// its navigation notification has set the flag from the app's own
  /// navigators, false at its root route, which would send the next back
  /// gesture to the system with the dashboard still open. A pop notifies
  /// twice, when it starts and when the route is removed after its exit
  /// animation. The check runs in a microtask, after every post-frame
  /// callback of the frame, so the request lands after the app's. Only a
  /// change sends a request.
  void _watchAppNavigation() {
    if (!_handlesAndroidBack || _watchingNavigation || !_layerOpen) return;
    _watchingNavigation = true;
    _appNavigators = null;
    // Layer changes are reported from the card's build; the tree is
    // walked after the frame.
    WidgetsBinding.instance.addPostFrameCallback(_onFrameWhileOpen);
  }

  void _onFrameWhileOpen(Duration _) {
    if (!mounted || !_layerOpen) {
      _watchingNavigation = false;
      _appNavigators = null;
      _appNavigation = const [];
      return;
    }
    // Registered for the next frame; does not schedule one.
    WidgetsBinding.instance.addPostFrameCallback(_onFrameWhileOpen);
    scheduleMicrotask(() {
      if (!mounted || !_layerOpen) return;
      if (_appNavigators == null) {
        _findAppNavigators();
        return;
      }
      if (listEquals(_navigationState(), _appNavigation)) return;
      _findAppNavigators();
      _sendFrameworkHandlesBack();
    });
  }

  /// Per app navigator: whether it can pop, and how many entries its
  /// overlay holds (a route adds its entries when pushed and removes them
  /// once it is gone). Navigators that left the tree read -1.
  List<int> _navigationState() => [
    for (final navigator in _appNavigators ?? const <NavigatorState>[])
      if (!navigator.mounted) ...[
        -1,
        -1,
      ] else ...[
        navigator.canPop() ? 1 : 0,
        _overlayEntryCount(navigator),
      ],
  ];

  static int _overlayEntryCount(NavigatorState navigator) {
    var count = 0;
    // Overlay > theater > one element per entry.
    navigator.overlay?.context.visitChildElements(
      (theater) => theater.visitChildElements((_) => count++),
    );
    return count;
  }

  /// Collects the navigators below the app child (the overlay's own
  /// subtree has none) and records whether each can pop.
  void _findAppNavigators() {
    final found = <NavigatorState>[];
    void visit(Element element) {
      if (element is StatefulElement && element.state is NavigatorState) {
        found.add(element.state as NavigatorState);
      }
      element.visitChildElements(visit);
    }

    context.visitChildElements(visit);
    _appNavigators = found;
    _appNavigation = _navigationState();
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
    // High contrast picks the high-contrast presets. Reduced motion is
    // read when each animation starts, and running ones settle through
    // motion.dart.
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
              // Always present, so excluding focus never remounts the app.
              child: ExcludeFocus(
                key: _appFocusKey,
                excluding: _appFocusExcluded,
                child: widget.child,
              ),
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
                // Above the overlay's Localizations, whose semantics node
                // would stop a BlockSemantics placed inside the card.
                child: _AppSemanticsBlocker(
                  blocking: _fullScreenLayerOpen,
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
    OverlayOwnership.unregister(context as Element, _appFocusKey);
    _fullScreenLayerOpen.dispose();
    widget.controller.themeOverride.removeListener(_onThemeChanged);
    widget.controller.overlayUiState.removeListener(_onUiStateChanged);
    WidgetsBinding.instance.removeObserver(this);
    Sleuth.notifyControllerDisposed(widget.controller);
    widget.controller.dispose();
    super.dispose();
  }
}

/// Drops the semantics of everything painted before it (the app) while
/// [blocking] is true. The flag is read at the render level, so the card
/// can report a page opening from its own build.
class _AppSemanticsBlocker extends SingleChildRenderObjectWidget {
  const _AppSemanticsBlocker({required this.blocking, super.child});

  final ValueListenable<bool> blocking;

  @override
  _RenderAppSemanticsBlocker createRenderObject(BuildContext context) =>
      _RenderAppSemanticsBlocker(blocking);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAppSemanticsBlocker renderObject,
  ) {
    renderObject.blocking = blocking;
  }
}

class _RenderAppSemanticsBlocker extends RenderProxyBox {
  _RenderAppSemanticsBlocker(this._blocking);

  ValueListenable<bool> _blocking;
  set blocking(ValueListenable<bool> value) {
    if (identical(value, _blocking)) return;
    if (attached) {
      _blocking.removeListener(markNeedsSemanticsUpdate);
      value.addListener(markNeedsSemanticsUpdate);
    }
    _blocking = value;
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _blocking.addListener(markNeedsSemanticsUpdate);
  }

  @override
  void detach() {
    _blocking.removeListener(markNeedsSemanticsUpdate);
    super.detach();
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.isBlockingSemanticsOfPreviouslyPaintedNodes = _blocking.value;
  }
}
