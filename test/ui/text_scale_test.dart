import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/ai_chat_adapter.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';

import '../helpers/overlay_harness.dart';

const _adapter = AiChatAdapter(sendMessage: _reply);

Stream<String> _reply(AiChatRequest request) => Stream.value('ok');

/// Overlay on a 320 x 568 view with a 220 px card and the mixed issue set.
Future<SleuthController> _pumpSmall(
  WidgetTester tester,
  double scale, {
  CardWindowState windowState = CardWindowState.normal,
}) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = await pumpOverlay(
    tester,
    textScale: scale,
    // No scan replaces the fixture issues during the test.
    config: const SleuthConfig(
      aiChat: _adapter,
      treeScanInterval: Duration(hours: 1),
    ),
  );
  // The tallest card the view allows, so the expanded issues have room.
  controller.overlayUiState.setCardGeometry(
    offset: const Offset(100, 0),
    width: 220,
    height: 548,
    windowState: windowState,
  );
  controller.issuesNotifier.value = mixedOverlayIssues();
  await openDashboard(tester, controller);
  return controller;
}

/// Pumps and fails on any exception, including RenderFlex overflow
/// reports.
Future<void> _settle(WidgetTester tester, String step) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  expect(tester.takeException(), isNull, reason: step);
}

/// Scrolls [finder] into view, building it first when the issue list has
/// not built it yet.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.dragUntilVisible(
      finder,
      find.byType(ListView),
      const Offset(0, -30),
    );
  }
  await tester.ensureVisible(finder.first);
  await tester.pump();
}

Future<void> _tapFinder(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder.first);
}

Future<void> _tapLabel(WidgetTester tester, String label) =>
    _tapFinder(tester, find.bySemanticsLabel(label));

void main() {
  for (final scale in [1.3, 2.0]) {
    group('at ${scale}x on a 220 px card', () {
      testWidgets('card, expanded issues and every page lay out', (
        tester,
      ) async {
        final controller = await _pumpSmall(tester, scale);
        expect(tester.takeException(), isNull, reason: 'open');

        // Expand each card on its own (the list builds lazily), with its
        // "About this detection" section open.
        final issues = mixedOverlayIssues();
        for (final issue in issues) {
          if (issue.rootCauseIds != null) continue;
          controller.issuesNotifier.value = [
            issue,
            ...issues.where(
              (i) => i.rootCauseIds?.contains(issue.stableId) ?? false,
            ),
          ];
          await _settle(tester, 'show ${issue.stableId}');
          await tester.tap(find.text(issue.title));
          await _settle(tester, 'expand ${issue.stableId}');
          await _tapFinder(tester, find.text('About this detection'));
          await _settle(tester, 'about ${issue.stableId}');
        }
        controller.issuesNotifier.value = [issues.first];
        await _settle(tester, 'root only');
        await tester.tap(find.text(issues.first.title));
        await _settle(tester, 'expand root');

        // FPS explainer.
        await _tapLabel(tester, 'Show FPS explainer');
        await _settle(tester, 'FPS explainer');

        // Learn more -> encyclopedia, Ask AI -> chat.
        await _tapFinder(tester, find.text('Learn more about this issue'));
        await _settle(tester, 'encyclopedia from learn more');
        expect(find.text('Issue Encyclopedia'), findsOneWidget);
        await systemBack(tester);
        await _settle(tester, 'back from encyclopedia');

        await _tapFinder(tester, find.text('Ask AI about this issue'));
        await _settle(tester, 'AI chat');
        await tester.tap(find.text('Ask AI').first);
        await _settle(tester, 'AI chat tapped');
        await systemBack(tester);
        await _settle(tester, 'back from AI chat');

        // Footer pages.
        for (final label in ['Encyclopedia', 'Guide']) {
          await _tapLabel(tester, label);
          await _settle(tester, label);
          await systemBack(tester);
          await _settle(tester, 'back from $label');
        }

        // Hide one, then the Hidden list.
        controller.overlayUiState.hide('slow_request');
        await _settle(tester, 'hidden');
        await _tapLabel(tester, '1 hidden. Show hidden issues');
        await _settle(tester, 'hidden page');
        await systemBack(tester);
        await _settle(tester, 'back from hidden page');
      });

      testWidgets('minimized and maximized cards lay out', (tester) async {
        await _pumpSmall(tester, scale, windowState: CardWindowState.minimized);
        expect(tester.takeException(), isNull, reason: 'minimized');
        await _tapLabel(tester, 'Restore');
        await _settle(tester, 'restored');
        await _tapLabel(tester, 'Close Sleuth');
        await _settle(tester, 'closed');
      });
    });
  }

  testWidgets('the app keeps a 3.0x text scale', (tester) async {
    final controller = await _pumpSmall(tester, 3);
    final app = MediaQuery.textScalerOf(tester.element(find.text('app')));
    expect(app.scale(10), 30);
    final card = MediaQuery.textScalerOf(
      tester.element(find.byType(FloatingIssuesCard)),
    );
    expect(card.scale(10), 20);
    expect(tester.takeException(), isNull);
    expect(controller.overlayUiState.dashboardOpen, isTrue);
  });
}
