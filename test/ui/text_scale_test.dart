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

  group('card geometry at 1.3x', () {
    Future<SleuthController> pumpView(
      WidgetTester tester,
      Size size, {
      double keyboard = 0,
      Offset offset = const Offset(40, 0),
      double? height,
      CardWindowState windowState = CardWindowState.normal,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.reset);
      final controller = await pumpOverlay(
        tester,
        textScale: 1.3,
        config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
      );
      controller.overlayUiState.setCardGeometry(
        offset: offset,
        width: 300,
        height: height,
        windowState: windowState,
      );
      controller.issuesNotifier.value = mixedOverlayIssues();
      await openDashboard(tester, controller);
      return controller;
    }

    double cardHeight(WidgetTester tester) => tester
        .getSize(
          find.byWidgetPredicate((w) => w is Material && w.elevation == 8),
        )
        .height;

    testWidgets('a landscape phone keeps the footer and grip on screen', (
      tester,
    ) async {
      await pumpView(tester, const Size(640, 360));
      expect(tester.takeException(), isNull);
      expect(cardHeight(tester), lessThanOrEqualTo(340));
      expect(
        tester.getRect(find.bySemanticsLabel('Guide')).bottom,
        lessThanOrEqualTo(360),
      );
      expect(
        tester.getRect(find.bySemanticsLabel('Resize card')).bottom,
        lessThanOrEqualTo(360),
      );
    });

    testWidgets('a maximized card stays above a 260 px keyboard', (
      tester,
    ) async {
      await pumpView(
        tester,
        const Size(360, 647),
        keyboard: 260,
        windowState: CardWindowState.maximized,
      );
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(find.bySemanticsLabel('Guide')).bottom,
        lessThanOrEqualTo(647 - 260),
      );
    });

    testWidgets('a maximized card keeps header, summary bar and footer', (
      tester,
    ) async {
      await pumpView(
        tester,
        const Size(360, 400),
        keyboard: 260,
        windowState: CardWindowState.maximized,
      );
      expect(tester.takeException(), isNull);
      // Header 48 + footer 49 + the summary bar's 48 px hit height.
      expect(cardHeight(tester), 48 + 49 + 48);
    });

    testWidgets('resizing stores the unscaled minimum', (tester) async {
      final handle = tester.ensureSemantics();
      final controller = await pumpView(
        tester,
        const Size(400, 800),
        height: 400,
      );
      final resize = find.bySemanticsLabel('Resize card');
      // Shown at the scaled floor of 390.
      expect(cardHeight(tester), 400);
      await performCustomAction(tester, resize, 'Shorter');
      expect(controller.overlayUiState.cardHeight, 352);
      expect(cardHeight(tester), 390);
      await performCustomAction(tester, resize, 'Shorter');
      expect(controller.overlayUiState.cardHeight, 304);
      await performCustomAction(tester, resize, 'Shorter');
      expect(controller.overlayUiState.cardHeight, 300);
      expect(cardHeight(tester), 390);
      // Growing starts from the shown height.
      await performCustomAction(tester, resize, 'Taller');
      expect(controller.overlayUiState.cardHeight, 390 + 48);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });

    testWidgets('a maximized card offers no resize actions', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpView(
        tester,
        const Size(400, 800),
        windowState: CardWindowState.maximized,
      );
      final data = tester
          .getSemantics(find.bySemanticsLabel('Resize card'))
          .getSemanticsData();
      expect(data.customSemanticsActionIds ?? const <int>[], isEmpty);
      handle.dispose();
    });

    testWidgets('the issue count stays at the right edge of the status row', (
      tester,
    ) async {
      await _pumpSmall(tester, 1.3);
      final count = find.text('${mixedOverlayIssues().length} issues');
      final card = tester.getRect(
        find.byWidgetPredicate((w) => w is Material && w.elevation == 8),
      );
      // The count does not fit beside the FPS group and the mode badge.
      expect(
        tester.getTopLeft(count).dy,
        greaterThan(tester.getBottomLeft(find.text('FRAME')).dy),
      );
      // Status row padding is 12.
      expect(tester.getRect(count).right, closeTo(card.right - 12, 0.5));
      expect(tester.takeException(), isNull);
    });
  });
}
