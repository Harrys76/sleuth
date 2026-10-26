import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/issue_card.dart';
import 'package:sleuth/src/ui/more_menu.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';
import 'package:sleuth/src/ui/sleuth_overlay.dart';

/// Pumps [SleuthOverlay] around [app] (a one-route [MaterialApp] by
/// default) with a test-initialised controller. The overlay owns and
/// disposes the controller.
///
/// Answers every [SystemChannels.platform] call with null, so a back that
/// reaches `SystemNavigator.pop` or `setFrameworkHandlesBack` does not
/// throw.
///
/// [textScale], [accessibilityFeatures] and [platformBrightness] set the
/// test platform dispatcher's values (cleared on tear-down); [themeMode]
/// is set on the controller's overlay state before the first pump.
/// [host] wraps the overlay, standing in for widgets a host app places
/// above it.
Future<SleuthController> pumpOverlay(
  WidgetTester tester, {
  SleuthConfig? config,
  Widget? app,
  Widget Function(Widget overlay)? host,
  double? textScale,
  FakeAccessibilityFeatures? accessibilityFeatures,
  Brightness? platformBrightness,
  SleuthThemeMode? themeMode,
}) async {
  final dispatcher = tester.platformDispatcher;
  if (textScale != null) {
    dispatcher.textScaleFactorTestValue = textScale;
    addTearDown(dispatcher.clearTextScaleFactorTestValue);
  }
  if (accessibilityFeatures != null) {
    dispatcher.accessibilityFeaturesTestValue = accessibilityFeatures;
    addTearDown(dispatcher.clearAccessibilityFeaturesTestValue);
  }
  if (platformBrightness != null) {
    dispatcher.platformBrightnessTestValue = platformBrightness;
    addTearDown(dispatcher.clearPlatformBrightnessTestValue);
  }
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  final controller = SleuthController(config: config)
    ..initializeDetectorsForTest()
    ..markInitializedForTest();
  if (themeMode != null) controller.overlayUiState.themeMode = themeMode;
  final overlay = SleuthOverlay(
    controller: controller,
    child:
        app ??
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('app'))),
        ),
  );
  await tester.pumpWidget(host == null ? overlay : host(overlay));
  await tester.pump();
  return controller;
}

/// Opens the dashboard through the controller-owned state.
Future<void> openDashboard(
  WidgetTester tester,
  SleuthController controller,
) async {
  controller.overlayUiState.dashboardOpen = true;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Opens the card's More menu and lets its fade finish.
Future<void> openMoreMenu(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_horiz));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

/// The More menu's row labelled [label].
Finder moreMenuRow(String label) => find.descendant(
  of: find.byType(SleuthMoreMenu),
  matching: find.text(label),
);

/// Opens the More menu and taps its [label] row, then lets the page that
/// opens settle.
Future<void> openFromMoreMenu(WidgetTester tester, String label) async {
  await openMoreMenu(tester);
  // The panel scrolls when the card is short.
  await tester.ensureVisible(moreMenuRow(label));
  await tester.pump();
  await tester.tap(moreMenuRow(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Sends a system back (Android back button / `didPopRoute`) and pumps.
Future<bool> systemBack(WidgetTester tester) async {
  final handled = await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return handled;
}

/// Issues covering every card variant: critical with a widget, a long
/// title, a downstream effect and a highlight checkbox; a confirmed
/// warning; an OK; and the collapsed effect.
List<PerformanceIssue> mixedOverlayIssues() => const [
  PerformanceIssue(
    severity: IssueSeverity.critical,
    category: IssueCategory.layout,
    confidence: IssueConfidence.likely,
    confidenceReason: 'Intrinsic layout under a scrolling list',
    title:
        'Nested intrinsic layout in ProductTile measured twice per frame '
        'while the catalogue scrolls',
    detail:
        'IntrinsicHeight > Row > IntrinsicWidth runs a dry layout of every '
        'child before the real one.',
    fixHint: 'Give the row a fixed height or use a Table.',
    stableId: 'layout_bottleneck',
    widgetName: 'ProductTile',
    ancestorChain: 'CatalogPage > ListView > ProductTile',
    downstreamIds: ['jank_detected'],
    routeName: '/catalog',
    observationSource: ObservationSource.structural,
  ),
  PerformanceIssue(
    severity: IssueSeverity.warning,
    category: IssueCategory.raster,
    confidence: IssueConfidence.confirmed,
    title: 'Jank: 12% of frames over budget',
    detail: 'Frames over the 16.7 ms budget.',
    fixHint: 'Profile the slow frames.',
    stableId: 'jank_detected',
    rootCauseIds: ['layout_bottleneck'],
    observationSource: ObservationSource.frameTiming,
  ),
  PerformanceIssue(
    severity: IssueSeverity.warning,
    category: IssueCategory.build,
    confidence: IssueConfidence.confirmed,
    title: 'Rebuild activity in PriceTag',
    detail: 'PriceTag rebuilt on every frame.',
    fixHint: 'Move the ticker below PriceTag.',
    stableId: 'rebuild_activity',
    widgetName: 'PriceTag',
    observationSource: ObservationSource.vmTimeline,
  ),
  PerformanceIssue(
    severity: IssueSeverity.ok,
    category: IssueCategory.network,
    confidence: IssueConfidence.possible,
    title: 'Slow request to /api/catalog',
    detail: 'One request took 1.2 s.',
    fixHint: 'Cache the catalogue.',
    stableId: 'slow_request',
  ),
];

/// Runs the custom semantics action [label] on the node [finder] finds.
/// Needs semantics enabled (`tester.ensureSemantics()`).
Future<void> performCustomAction(
  WidgetTester tester,
  Finder finder,
  String label,
) async {
  final node = tester.getSemantics(finder);
  final owner = tester.binding.renderViews.first.owner!.semanticsOwner!;
  owner.performAction(
    node.id,
    SemanticsAction.customAction,
    CustomSemanticsAction.getIdentifier(CustomSemanticsAction(label: label)),
  );
  await tester.pump();
}

/// The expanded issue cards. The pin is no longer drawn; an expanded
/// card's semantics carry the hint "Pinned while expanded".
Finder expandedIssueCards() => find.descendant(
  of: find.byType(IssueCard),
  matching: find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.expanded == true &&
        (w.properties.hint?.contains('Pinned while expanded') ?? false),
  ),
);

/// The crosshair of the card titled [title], or every crosshair.
Finder crosshair([String? title]) => title == null
    ? find.byIcon(Icons.my_location)
    : find.descendant(
        of: find.ancestor(
          of: find.text(title),
          matching: find.byType(IssueCard),
        ),
        matching: find.byIcon(Icons.my_location),
      );

/// Whether the crosshair [finder] finds is on: its widget is outlined.
bool crosshairOn(WidgetTester tester, Finder finder) =>
    tester
        .widget<Semantics>(
          find
              .ancestor(
                of: finder,
                matching: find.byWidgetPredicate(
                  (w) =>
                      w is Semantics &&
                      (w.properties.label?.endsWith(' on screen') ?? false),
                ),
              )
              .first,
        )
        .properties
        .toggled ??
    false;
