import 'dart:async';

import 'package:flutter/foundation.dart' show precisionErrorTolerance;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/ai_chat_adapter.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';

import '../helpers/overlay_harness.dart';

/// 48 x 48 for every tappable node, except the compact card-header
/// controls, which are 36 x 48: five 48 px wide controls plus the title do
/// not fit the narrowest card.
class SleuthTapTargetGuideline extends MinimumTapTargetGuideline {
  const SleuthTapTargetGuideline()
    : super(
        size: const Size(48, 48),
        link: 'https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum',
      );

  /// Labels of the 36 x 48 header controls.
  static const compactHeaderLabels = {
    'Show overlay',
    'Hide overlay',
    'Toggle theme',
    'Minimize',
    'Maximize',
    'Restore',
  };

  static const Size compactSize = Size(36, 48);

  @override
  bool shouldSkipNode(SemanticsNode node) =>
      super.shouldSkipNode(node) ||
      compactHeaderLabels.contains(node.getSemanticsData().label);

  @override
  FutureOr<Evaluation> evaluate(WidgetTester tester) async {
    var result = await super.evaluate(tester);
    for (final view in tester.binding.renderViews) {
      final root = view.owner!.semanticsOwner!.rootSemanticsNode!;
      result += _checkCompact(view, root);
    }
    return result;
  }

  Evaluation _checkCompact(RenderView view, SemanticsNode node) {
    var result = const Evaluation.pass();
    node.visitChildren((child) {
      result += _checkCompact(view, child);
      return true;
    });
    final data = node.getSemanticsData();
    if (!compactHeaderLabels.contains(data.label)) return result;
    var rect = node.rect;
    for (SemanticsNode? n = node; n != null; n = n.parent) {
      final t = n.transform;
      if (t != null) rect = MatrixUtils.transformRect(t, rect);
    }
    final size = rect.size / view.flutterView.devicePixelRatio;
    if (size.width < compactSize.width - precisionErrorTolerance ||
        size.height < compactSize.height - precisionErrorTolerance) {
      result += Evaluation.fail(
        '$node: expected at least $compactSize, found $size',
      );
    }
    return result;
  }

  @override
  String get description =>
      'Tappable nodes are at least 48 x 48 (header controls 36 x 48)';
}

const _sleuthTapTargetGuideline = SleuthTapTargetGuideline();

const _adapter = AiChatAdapter(sendMessage: _reply);

Stream<String> _reply(AiChatRequest request) => Stream.value('ok');

/// Overlay over an opaque [host] colour with the mixed issues, the root
/// card expanded.
Future<SleuthController> _pump(
  WidgetTester tester, {
  required Color host,
  required Brightness brightness,
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = await pumpOverlay(
    tester,
    app: MaterialApp(home: ColoredBox(color: host)),
    textScale: textScale,
    platformBrightness: brightness,
    config: const SleuthConfig(
      aiChat: _adapter,
      treeScanInterval: Duration(hours: 1),
      showDebugModeBanner: false,
    ),
  );
  controller.overlayUiState.setCardGeometry(
    offset: const Offset(40, 40),
    width: 340,
    height: 700,
    windowState: CardWindowState.normal,
  );
  controller.issuesNotifier.value = mixedOverlayIssues();
  await openDashboard(tester, controller);
  return controller;
}

Future<void> _expectGuidelines(WidgetTester tester, String where) async {
  await expectLater(
    tester,
    meetsGuideline(_sleuthTapTargetGuideline),
    reason: '$where: tap targets',
  );
  await expectLater(
    tester,
    meetsGuideline(labeledTapTargetGuideline),
    reason: '$where: labels',
  );
  await expectLater(
    tester,
    meetsGuideline(textContrastGuideline),
    reason: '$where: contrast',
  );
}

Future<void> _open(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder.first);
  await tester.pump();
  await tester.tap(finder.first);
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

/// Page names announced through route semantics.
const _pageNames = {
  'Issue Encyclopedia',
  'Sleuth Guide',
  'Hidden issues',
  'Ask AI',
  'Rebuild stats',
  'Startup metrics',
};

int _routeNodes(WidgetTester tester) {
  var count = 0;
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    // `flagsCollection` is not available on the 3.32 floor.
    // ignore: deprecated_member_use
    if (data.hasFlag(SemanticsFlag.scopesRoute) &&
        _pageNames.contains(data.label)) {
      count++;
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  for (final view in tester.binding.renderViews) {
    visit(view.owner!.semanticsOwner!.rootSemanticsNode!);
  }
  return count;
}

void main() {
  for (final brightness in Brightness.values) {
    for (final (hostName, host) in [
      ('black', const Color(0xFF000000)),
      ('white', const Color(0xFFFFFFFF)),
    ]) {
      for (final scale in [1.0, 1.3]) {
        testWidgets('card: ${brightness.name} theme over $hostName at '
            '${scale}x', (tester) async {
          final handle = tester.ensureSemantics();
          await _pump(
            tester,
            host: host,
            brightness: brightness,
            textScale: scale,
          );
          await _expectGuidelines(tester, 'collapsed');
          await _open(tester, find.textContaining('Nested intrinsic layout'));
          await _expectGuidelines(tester, 'expanded');
          handle.dispose();
        });
      }
    }

    testWidgets('pages: ${brightness.name} theme', (tester) async {
      final handle = tester.ensureSemantics();
      final controller = await _pump(
        tester,
        host: const Color(0xFF000000),
        brightness: brightness,
      );
      await _open(tester, find.textContaining('Nested intrinsic layout'));

      Future<void> page(Finder opener, String name) async {
        await _open(tester, opener);
        expect(_routeNodes(tester), 1, reason: name);
        await _expectGuidelines(tester, name);
        await systemBack(tester);
        expect(_routeNodes(tester), 0, reason: 'after $name');
      }

      await page(find.text('Learn more about this issue'), 'encyclopedia');
      await page(find.text('Ask AI about this issue'), 'AI chat');
      await page(find.bySemanticsLabel('Guide'), 'guide');
      controller.overlayUiState.hide('slow_request');
      await tester.pump();
      await page(
        find.bySemanticsLabel('1 hidden. Show hidden issues'),
        'hidden issues',
      );
      handle.dispose();
    });

    testWidgets('trigger: ${brightness.name} theme', (tester) async {
      final handle = tester.ensureSemantics();
      final controller = await _pump(
        tester,
        host: const Color(0xFF000000),
        brightness: brightness,
      );
      controller.overlayUiState.dashboardOpen = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await expectLater(tester, meetsGuideline(_sleuthTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      handle.dispose();
    });
  }
}
