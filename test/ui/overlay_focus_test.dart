import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/hidden_issues_page.dart';
import 'package:sleuth/src/ui/issue_card.dart';
import 'package:sleuth/src/ui/issue_encyclopedia_page.dart';
import 'package:sleuth/src/ui/more_menu.dart';

import '../helpers/overlay_harness.dart';

/// App under the overlay: a text field and a button with their own focus
/// nodes, at the top left, clear of the card.
class _HostApp {
  final field = FocusNode(debugLabel: 'app field');
  final button = FocusNode(debugLabel: 'app button');
  int pressed = 0;

  Widget build() => MaterialApp(
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(focusNode: field),
              ElevatedButton(
                focusNode: button,
                onPressed: () => pressed++,
                child: const Text('app button'),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  void dispose() {
    field.dispose();
    button.dispose();
  }
}

Future<(_HostApp, SleuthController)> _pumpHostApp(
  WidgetTester tester, {
  SleuthConfig? config,
}) async {
  final app = _HostApp();
  addTearDown(app.dispose);
  final controller = await pumpOverlay(
    tester,
    app: app.build(),
    config: config,
  );
  return (app, controller);
}

Future<void> _openGuide(WidgetTester tester) async {
  await openFromMoreMenu(tester, 'Guide');
  await tester.pumpAndSettle();
  expect(find.text('Sleuth Guide'), findsOneWidget);
}

/// Whether the primary focus sits inside the overlay's card or its pages.
bool _focusInOverlay() {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  return context.findAncestorWidgetOfExactType<FloatingIssuesCard>() != null;
}

/// Node ids of the focus semantics events sent to the platform.
List<int> _recordScreenReaderFocus(WidgetTester tester) {
  final ids = <int>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockDecodedMessageHandler<Object?>(
    SystemChannels.accessibility,
    (message) async {
      if (message case {'type': 'focus', 'nodeId': final int id}) ids.add(id);
      return null;
    },
  );
  addTearDown(
    () => messenger.setMockDecodedMessageHandler<Object?>(
      SystemChannels.accessibility,
      null,
    ),
  );
  return ids;
}

PerformanceIssue _rebuildIssue(int i) => PerformanceIssue(
  severity: IssueSeverity.warning,
  category: IssueCategory.build,
  confidence: IssueConfidence.confirmed,
  title: 'Rebuilds in Widget$i',
  detail: 'Widget$i rebuilt on every frame.',
  fixHint: 'Move the ticker below Widget$i.',
  stableId: 'rebuild_activity',
  widgetName: 'Widget$i',
);

void main() {
  const config = SleuthConfig(treeScanInterval: Duration(hours: 1));

  group('App focus while a page is open', () {
    testWidgets('a page takes focus and the text input from an app text '
        'field, and closing it gives them back', (tester) async {
      final (app, controller) = await _pumpHostApp(tester, config: config);
      app.field.requestFocus();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);

      await openDashboard(tester, controller);
      await _openGuide(tester);
      expect(app.field.hasFocus, isFalse);
      expect(_focusInOverlay(), isTrue);
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);

      // The app cannot take focus back while the page is open.
      app.field.requestFocus();
      await tester.pump();
      expect(app.field.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);

      expect(await systemBack(tester), isTrue);
      expect(find.text('Sleuth Guide'), findsNothing);
      expect(app.field.hasPrimaryFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
    });

    testWidgets('Tab does not move focus into the app', (tester) async {
      final (app, controller) = await _pumpHostApp(tester, config: config);
      app.field.requestFocus();
      await tester.pump();
      await openDashboard(tester, controller);
      await _openGuide(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(app.field.hasFocus, isFalse);
      expect(app.button.hasFocus, isFalse);
      expect(_focusInOverlay(), isTrue);
    });

    testWidgets('Enter and Space do not press a focused app button; the '
        'button has focus again after the page closes', (tester) async {
      final (app, controller) = await _pumpHostApp(tester, config: config);
      app.button.requestFocus();
      await tester.pump();
      await openDashboard(tester, controller);
      await _openGuide(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(app.pressed, 0);

      await systemBack(tester);
      expect(app.button.hasPrimaryFocus, isTrue);
    });

    testWidgets('the Hidden list takes focus from the app too', (tester) async {
      final (app, controller) = await _pumpHostApp(tester, config: config);
      controller.overlayUiState.hide('some_issue');
      app.field.requestFocus();
      await tester.pump();
      await openDashboard(tester, controller);
      await openFromMoreMenu(tester, 'Hidden issues');
      await tester.pumpAndSettle();
      expect(find.byType(HiddenIssuesPage), findsOneWidget);
      expect(app.field.hasFocus, isFalse);
      expect(_focusInOverlay(), isTrue);

      await systemBack(tester);
      expect(app.field.hasPrimaryFocus, isTrue);
    });

    testWidgets('the floating card alone leaves the app its focus', (
      tester,
    ) async {
      final (app, controller) = await _pumpHostApp(tester, config: config);
      controller.issuesNotifier.value = mixedOverlayIssues();
      app.field.requestFocus();
      await tester.pump();

      await openDashboard(tester, controller);
      await tester.tap(find.bySemanticsLabel('Minimize'));
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Restore'));
      await tester.pump();
      expect(app.field.hasPrimaryFocus, isTrue);
      expect(tester.testTextInput.hasAnyClients, isTrue);
    });

    testWidgets('Escape closes the page even though an app text field had '
        'focus before it opened', (tester) async {
      final (app, controller) = await _pumpHostApp(tester, config: config);
      app.field.requestFocus();
      await tester.pump();
      await openDashboard(tester, controller);
      await _openGuide(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Sleuth Guide'), findsNothing);
      expect(controller.overlayUiState.dashboardOpen, isTrue);
      expect(app.field.hasPrimaryFocus, isTrue);
    });

    testWidgets('closing the dashboard from a page gives the app its focus '
        'back', (tester) async {
      final (app, controller) = await _pumpHostApp(tester, config: config);
      app.field.requestFocus();
      await tester.pump();
      await openDashboard(tester, controller);
      await _openGuide(tester);

      controller.overlayUiState.dashboardOpen = false;
      await tester.pumpAndSettle();
      expect(find.byType(FloatingIssuesCard), findsNothing);
      expect(app.field.hasPrimaryFocus, isTrue);
    });

    testWidgets('the More menu takes focus from the app, and closing the '
        'dashboard gives it back', (tester) async {
      final (app, controller) = await _pumpHostApp(tester, config: config);
      app.field.requestFocus();
      await tester.pump();
      await openDashboard(tester, controller);
      await openMoreMenu(tester);
      expect(app.field.hasFocus, isFalse);
      expect(_focusInOverlay(), isTrue);

      // Closing the menu leaves focus on More.
      await systemBack(tester);
      expect(_focusInOverlay(), isTrue);

      controller.overlayUiState.dashboardOpen = false;
      await tester.pumpAndSettle();
      expect(app.field.hasPrimaryFocus, isTrue);
    });

    testWidgets('above the app\'s MaterialApp, Tab moves through the menu '
        'and Enter opens a row', (tester) async {
      final (app, controller) = await _pumpHostApp(tester, config: config);
      await openDashboard(tester, controller);
      await openMoreMenu(tester);
      bool focused(String row) =>
          Focus.of(tester.element(moreMenuRow(row))).hasPrimaryFocus;
      // Startup and Rebuild stats are disabled; Encyclopedia comes first.
      expect(focused('Encyclopedia'), isTrue);

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.tab), isTrue);
      await tester.pump();
      expect(focused('Guide'), isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(focused('Encyclopedia'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('Sleuth Guide'), findsOneWidget);
      expect(app.pressed, 0);
    });

    testWidgets('Space in an overlay text field is left to the field', (
      tester,
    ) async {
      final (_, controller) = await _pumpHostApp(tester, config: config);
      await openDashboard(tester, controller);
      await openFromMoreMenu(tester, 'Encyclopedia');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(IssueEncyclopediaPage),
          matching: find.byType(EditableText),
        ),
      );
      await tester.pump();
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.space), isFalse);
      expect(find.byType(IssueEncyclopediaPage), findsOneWidget);
    });

    testWidgets('each menu opening records the app node focused then', (
      tester,
    ) async {
      final (app, controller) = await _pumpHostApp(tester, config: config);
      app.button.requestFocus();
      await tester.pump();
      await openDashboard(tester, controller);
      await openMoreMenu(tester);

      // A tap on the app's field closes the menu and focuses the field.
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(find.byType(SleuthMoreMenu), findsNothing);
      expect(app.field.hasPrimaryFocus, isTrue);

      await openMoreMenu(tester);
      expect(app.field.hasFocus, isFalse);
      controller.overlayUiState.dashboardOpen = false;
      await tester.pumpAndSettle();
      expect(app.field.hasPrimaryFocus, isTrue);
      expect(app.button.hasFocus, isFalse);
    });

    testWidgets('with the menu open, Escape closes the menu even when an '
        'app text field had focus, then the card', (tester) async {
      final (app, controller) = await _pumpHostApp(tester, config: config);
      app.field.requestFocus();
      await tester.pump();
      await openDashboard(tester, controller);
      await openMoreMenu(tester);
      expect(find.byType(SleuthMoreMenu), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(SleuthMoreMenu), findsNothing);
      expect(controller.overlayUiState.dashboardOpen, isTrue);

      // Focus is on More now, not in the app's field, so Escape closes the
      // card.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.overlayUiState.dashboardOpen, isFalse);
      expect(app.field.hasPrimaryFocus, isTrue);
    });
  });

  group('Screen reader focus and list position', () {
    testWidgets('opening the More menu moves screen reader focus to the '
        'panel', (tester) async {
      final focusEvents = _recordScreenReaderFocus(tester);
      final controller = await pumpOverlay(tester, config: config);
      await openDashboard(tester, controller);
      focusEvents.clear();
      await openMoreMenu(tester);
      final panel = tester.getSemantics(
        find.descendant(
          of: find.byType(SleuthMoreMenu),
          matching: find.bySemanticsLabel('More'),
        ),
      );
      expect(focusEvents, [panel.id]);
    });

    testWidgets('Show all moves screen reader focus to the first chip', (
      tester,
    ) async {
      final focusEvents = _recordScreenReaderFocus(tester);
      final controller = await pumpOverlay(tester, config: config);
      controller.issuesNotifier.value = [
        _rebuildIssue(0),
        PerformanceIssue(
          severity: IssueSeverity.critical,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title: 'Critical one',
          detail: 'Detail',
          fixHint: 'Fix',
          stableId: 'critical_one',
        ),
      ];
      await openDashboard(tester, controller);
      final critical = find.bySemanticsLabel('1 critical, on');
      await tester.ensureVisible(critical);
      await tester.pump();
      await tester.tap(critical);
      await tester.pump();
      expect(find.text('Showing 1 of 2'), findsOneWidget);

      focusEvents.clear();
      await tester.tap(find.text('Show all'));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Showing'), findsNothing);
      final first = tester.getSemantics(
        find.bySemanticsLabel('1 critical, on'),
      );
      expect(focusEvents, [first.id]);
    });

    testWidgets('opening the dashboard moves screen reader focus to the '
        'card header', (tester) async {
      final focusEvents = _recordScreenReaderFocus(tester);
      final controller = await pumpOverlay(tester, config: config);
      await openDashboard(tester, controller);
      final header = tester.getSemantics(find.bySemanticsLabel('Sleuth'));
      expect(focusEvents, [header.id]);
    });

    testWidgets('closing Learn more keeps the list offset and moves screen '
        'reader focus back to the card that opened it', (tester) async {
      final focusEvents = _recordScreenReaderFocus(tester);
      final controller = await pumpOverlay(tester, config: config);
      controller.issuesNotifier.value = [
        for (var i = 0; i < 12; i++) _rebuildIssue(i),
      ];
      await openDashboard(tester, controller);

      final list = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      ScrollPosition position() => tester.state<ScrollableState>(list).position;
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(position().pixels, greaterThan(0));

      // The lowest card fully inside the list.
      final listRect = tester.getRect(find.byType(ListView));
      final shown = [
        for (var i = 0; i < 12; i++)
          if (find.text('Rebuilds in Widget$i').evaluate().isNotEmpty &&
              listRect.contains(
                tester.getBottomLeft(find.text('Rebuilds in Widget$i')),
              ))
            i,
      ];
      final title = 'Rebuilds in Widget${shown.last}';
      await tester.tap(find.text(title));
      await tester.pump();
      final learnMore = find.bySemanticsLabel('Learn more');
      await tester.ensureVisible(learnMore);
      await tester.pumpAndSettle();
      final offset = position().pixels;
      expect(offset, greaterThan(0));

      await tester.tap(learnMore);
      await tester.pumpAndSettle();
      expect(find.byType(IssueEncyclopediaPage), findsOneWidget);
      focusEvents.clear();

      await systemBack(tester);
      expect(find.byType(IssueEncyclopediaPage), findsNothing);
      expect(position().pixels, offset);
      final card = tester.getSemantics(
        find.ancestor(of: find.text(title), matching: find.byType(IssueCard)),
      );
      expect(card.label, title);
      expect(focusEvents, [card.id]);
    });

    testWidgets('closing a page opened from the More menu moves screen '
        'reader focus to More', (tester) async {
      final focusEvents = _recordScreenReaderFocus(tester);
      final controller = await pumpOverlay(tester, config: config);
      await openDashboard(tester, controller);
      await _openGuide(tester);
      focusEvents.clear();

      await systemBack(tester);
      final more = tester.getSemantics(find.bySemanticsLabel('More'));
      expect(focusEvents, [more.id]);
    });
  });
}
