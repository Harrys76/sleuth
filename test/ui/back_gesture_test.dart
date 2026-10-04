import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/hidden_issues_page.dart';
import 'package:sleuth/src/ui/issue_encyclopedia_page.dart';
import 'package:sleuth/src/ui/sleuth_overlay.dart';

import '../helpers/overlay_harness.dart';

WidgetsBindingObserver _observer(WidgetTester tester) =>
    tester.state(find.byType(SleuthOverlay)) as WidgetsBindingObserver;

PredictiveBackEvent _backEvent() => PredictiveBackEvent.fromMap(const {
  'touchOffset': [0.0, 300.0],
  'progress': 0.0,
  'swipeEdge': 0,
});

/// Sends a predictive-back [method] through the binding's
/// `flutter/backgesture` channel, as the Android embedder does.
Future<void> _platformBackGesture(WidgetTester tester, String method) async {
  final message = const StandardMethodCodec().encodeMethodCall(
    MethodCall(
      method,
      method == 'startBackGesture' || method == 'updateBackGestureProgress'
          ? const {
              'touchOffset': [0.0, 300.0],
              'progress': 0.0,
              'swipeEdge': 0,
            }
          : null,
    ),
  );
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.backGesture.name,
    message,
    (_) {},
  );
  await tester.pumpAndSettle();
}

Future<void> _openEncyclopedia(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Encyclopedia'));
  await tester.pumpAndSettle();
  expect(find.byType(IssueEncyclopediaPage), findsOneWidget);
}

/// Two-route app: home, then a pushed detail route.
Widget _twoRouteApp() => MaterialApp(
  home: Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  const Scaffold(body: Center(child: Text('app detail'))),
            ),
          ),
          child: const Text('app home'),
        ),
      ),
    ),
  ),
);

void main() {
  group('System back with the overlay', () {
    testWidgets('closed overlay: back is not handled by the overlay', (
      tester,
    ) async {
      final controller = await pumpOverlay(tester);
      expect(await _observer(tester).didPopRoute(), isFalse);
      expect(controller.overlayUiState.dashboardOpen, isFalse);
      expect(find.text('app'), findsOneWidget);
    });

    testWidgets('open dashboard: back closes it', (tester) async {
      final controller = await pumpOverlay(tester);
      await openDashboard(tester, controller);
      expect(find.byType(FloatingIssuesCard), findsOneWidget);

      expect(await systemBack(tester), isTrue);
      expect(controller.overlayUiState.dashboardOpen, isFalse);
      expect(find.byType(FloatingIssuesCard), findsNothing);
    });

    testWidgets('encyclopedia open: back closes only the encyclopedia', (
      tester,
    ) async {
      final controller = await pumpOverlay(tester);
      await openDashboard(tester, controller);
      await _openEncyclopedia(tester);

      expect(await systemBack(tester), isTrue);
      expect(find.byType(IssueEncyclopediaPage), findsNothing);
      expect(controller.overlayUiState.dashboardOpen, isTrue);
    });

    testWidgets('Hidden list open: back closes only the list', (tester) async {
      final controller = await pumpOverlay(tester);
      controller.overlayUiState.hide('some_issue');
      await openDashboard(tester, controller);
      await tester.tap(find.text('1 hidden'));
      await tester.pumpAndSettle();
      expect(find.byType(HiddenIssuesPage), findsOneWidget);

      expect(await systemBack(tester), isTrue);
      expect(find.byType(HiddenIssuesPage), findsNothing);
      expect(controller.overlayUiState.dashboardOpen, isTrue);
    });

    testWidgets('focused text field: back unfocuses first; three backs close '
        'everything and leave the app route', (tester) async {
      final controller = await pumpOverlay(tester);
      await openDashboard(tester, controller);
      await _openEncyclopedia(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(FocusManager.instance.primaryFocus?.hasPrimaryFocus, isTrue);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);

      expect(await systemBack(tester), isTrue);
      expect(field.focusNode!.hasFocus, isFalse);
      expect(find.byType(IssueEncyclopediaPage), findsOneWidget);

      expect(await systemBack(tester), isTrue);
      expect(find.byType(IssueEncyclopediaPage), findsNothing);

      expect(await systemBack(tester), isTrue);
      expect(controller.overlayUiState.dashboardOpen, isFalse);
      expect(find.text('app'), findsOneWidget);

      expect(await _observer(tester).didPopRoute(), isFalse);
    });

    testWidgets('app route under an open overlay page stays put', (
      tester,
    ) async {
      final controller = await pumpOverlay(tester, app: _twoRouteApp());
      await tester.tap(find.text('app home'));
      await tester.pumpAndSettle();
      expect(find.text('app detail'), findsOneWidget);

      await openDashboard(tester, controller);
      await _openEncyclopedia(tester);
      expect(await systemBack(tester), isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(IssueEncyclopediaPage), findsNothing);

      // The overlay is closed by the next back; the one after reaches the
      // app's Navigator.
      expect(await systemBack(tester), isTrue);
      await tester.pumpAndSettle();
      expect(controller.overlayUiState.dashboardOpen, isFalse);
      expect(find.text('app detail'), findsOneWidget);

      await systemBack(tester);
      await tester.pumpAndSettle();
      expect(find.text('app detail'), findsNothing);
      expect(find.text('app home'), findsOneWidget);
    });

    testWidgets('predictive back is claimed only while a layer is open', (
      tester,
    ) async {
      final controller = await pumpOverlay(tester);
      final observer = _observer(tester);
      expect(observer.handleStartBackGesture(_backEvent()), isFalse);

      await openDashboard(tester, controller);
      await _openEncyclopedia(tester);
      expect(observer.handleStartBackGesture(_backEvent()), isTrue);
      observer.handleUpdateBackGestureProgress(_backEvent());

      // Cancel keeps everything open.
      observer.handleCancelBackGesture();
      await tester.pumpAndSettle();
      expect(find.byType(IssueEncyclopediaPage), findsOneWidget);

      // Commit closes the innermost layer.
      expect(observer.handleStartBackGesture(_backEvent()), isTrue);
      observer.handleCommitBackGesture();
      await tester.pumpAndSettle();
      expect(find.byType(IssueEncyclopediaPage), findsNothing);
      expect(controller.overlayUiState.dashboardOpen, isTrue);
    });

    testWidgets('predictive back through the binding closes the innermost '
        'layer', (tester) async {
      final controller = await pumpOverlay(tester);
      await openDashboard(tester, controller);
      await _openEncyclopedia(tester);

      await _platformBackGesture(tester, 'startBackGesture');
      await _platformBackGesture(tester, 'updateBackGestureProgress');
      await _platformBackGesture(tester, 'commitBackGesture');
      expect(find.byType(IssueEncyclopediaPage), findsNothing);
      expect(controller.overlayUiState.dashboardOpen, isTrue);

      await _platformBackGesture(tester, 'startBackGesture');
      await _platformBackGesture(tester, 'commitBackGesture');
      expect(controller.overlayUiState.dashboardOpen, isFalse);
      expect(find.text('app'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a gesture committed after the dashboard closed does '
        'nothing', (tester) async {
      final controller = await pumpOverlay(tester, app: _twoRouteApp());
      await tester.tap(find.text('app home'));
      await tester.pumpAndSettle();
      await openDashboard(tester, controller);

      await _platformBackGesture(tester, 'startBackGesture');
      controller.overlayUiState.dashboardOpen = false;
      await tester.pumpAndSettle();
      final observer = _observer(tester);
      observer.handleCommitBackGesture();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(controller.overlayUiState.dashboardOpen, isFalse);
      // The overlay took no action; the app route is still there.
      expect(find.text('app detail'), findsOneWidget);
    });

    testWidgets('a gesture committed after the overlay left the tree does '
        'not throw', (tester) async {
      final controller = await pumpOverlay(tester);
      await openDashboard(tester, controller);
      final observer = _observer(tester);
      expect(
        observer.handleStartBackGesture(
          PredictiveBackEvent.fromMap(const {
            'touchOffset': [0.0, 300.0],
            'progress': 0.0,
            'swipeEdge': 0,
          }),
        ),
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
      observer.handleCommitBackGesture();
      expect(await observer.didPopRoute(), isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Android: framework back handling requested while a layer '
        'is open', (tester) async {
      final requests = <Object?>[];
      final controller = await pumpOverlay(tester);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
            requests.add(call.arguments);
          }
          return null;
        },
      );

      await openDashboard(tester, controller);
      expect(requests, contains(true));

      requests.clear();
      await _openEncyclopedia(tester);
      expect(requests, contains(true));

      // Closing everything never asks for false from the overlay.
      requests.clear();
      await systemBack(tester);
      await systemBack(tester);
      expect(requests.where((r) => r == false), isEmpty);
    });

    testWidgets('state survives close and reopen', (tester) async {
      final controller = await pumpOverlay(tester);
      await openDashboard(tester, controller);
      // Drag the card by its title bar.
      await tester.drag(find.text('Sleuth'), const Offset(-120, -60));
      await tester.pumpAndSettle();
      final moved = controller.overlayUiState.cardOffset;
      expect(moved, isNotNull);

      await systemBack(tester);
      await openDashboard(tester, controller);
      expect(controller.overlayUiState.cardOffset, moved);
      final cardTopLeft = tester.getTopLeft(find.text('Sleuth'));
      await systemBack(tester);
      await openDashboard(tester, controller);
      expect(tester.getTopLeft(find.text('Sleuth')), cardTopLeft);
    });
  });
}
