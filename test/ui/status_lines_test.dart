import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/coverage_report.dart';
import 'package:sleuth/src/controller/run_state.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/status_lines.dart';

/// A report with [on] checks on, [needsVm] off for the VM, [partial] partly
/// on and [optIn] opt-in checks off.
CoverageReport _coverage({
  int on = 0,
  int needsVm = 0,
  int partial = 0,
  int optIn = 0,
}) {
  final types = DetectorType.values
      .where((t) => t != DetectorType.custom)
      .toList();
  var i = 0;
  final map = <DetectorType, CheckCoverage>{};
  void take(int n, CheckCoverage c) {
    for (var k = 0; k < n; k++) {
      map[types[i++]] = c;
    }
  }

  take(on, CheckCoverage.on);
  take(needsVm, CheckCoverage.needsVm);
  take(partial, CheckCoverage.partial);
  take(optIn, CheckCoverage.optInOff);
  return CoverageReport(map);
}

/// A controller whose Reconnect succeeds at once.
class _ReconnectingController extends SleuthController {
  @override
  Future<bool> reconnect() async {
    vmConnectedNotifier.value = true;
    runStateNotifier.value = const SleuthRunState(
      phase: SleuthRunPhase.running,
      vmConnected: true,
      everConnected: true,
    );
    return true;
  }
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

Future<void> _pumpBox(WidgetTester tester, SleuthStatusBox box) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: box)),
      ),
    );

void main() {
  group('statusKindOf', () {
    test('maps each run state to its line', () {
      expect(statusKindOf(const SleuthRunState()), SleuthStatusKind.starting);
      expect(
        statusKindOf(
          const SleuthRunState(
            phase: SleuthRunPhase.warmingUp,
            vmConnected: true,
            everConnected: true,
          ),
        ),
        SleuthStatusKind.warmingUp,
      );
      expect(
        statusKindOf(
          const SleuthRunState(
            phase: SleuthRunPhase.running,
            vmConnected: true,
            everConnected: true,
          ),
        ),
        SleuthStatusKind.clean,
      );
      // A link never made is no VM link, even while warming up.
      expect(
        statusKindOf(const SleuthRunState(phase: SleuthRunPhase.warmingUp)),
        SleuthStatusKind.noVm,
      );
      expect(
        statusKindOf(
          const SleuthRunState(
            phase: SleuthRunPhase.running,
            everConnected: true,
            reconnectAttempt: 2,
            maxReconnectAttempts: 7,
          ),
        ),
        SleuthStatusKind.vmLost,
      );
      expect(
        statusKindOf(
          const SleuthRunState(
            phase: SleuthRunPhase.running,
            everConnected: true,
            stoppedRetrying: true,
          ),
        ),
        SleuthStatusKind.stoppedRetrying,
      );
    });
  });

  group('SleuthStatusBox', () {
    testWidgets('no VM link counts from the coverage report, with the '
        'command', (tester) async {
      var copied = 0;
      await _pumpBox(
        tester,
        SleuthStatusBox(
          kind: SleuthStatusKind.noVm,
          run: const SleuthRunState(phase: SleuthRunPhase.running),
          coverage: _coverage(on: 10, needsVm: 6, partial: 3),
          onCopyCommand: () => copied++,
        ),
      );
      expect(find.text('No VM link: 6 checks off, 3 partly off.'), findsOne);
      expect(find.text(sleuthRunCommand), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Copy command'));
      expect(copied, 1);
    });

    testWidgets('clean counts checks on and opt-in checks off', (tester) async {
      await _pumpBox(
        tester,
        SleuthStatusBox(
          kind: SleuthStatusKind.clean,
          run: const SleuthRunState(
            phase: SleuthRunPhase.running,
            vmConnected: true,
            everConnected: true,
          ),
          coverage: _coverage(on: 19, optIn: 2),
        ),
      );
      expect(
        find.text('VM link on; 19 checks on, 2 opt-in checks off.'),
        findsOneWidget,
      );
    });

    testWidgets('a lost link counts the attempt', (tester) async {
      await _pumpBox(
        tester,
        SleuthStatusBox(
          kind: SleuthStatusKind.vmLost,
          run: const SleuthRunState(
            phase: SleuthRunPhase.running,
            everConnected: true,
            reconnectAttempt: 2,
            maxReconnectAttempts: 7,
          ),
          coverage: _coverage(on: 19),
        ),
      );
      expect(find.textContaining('Reconnecting, attempt 2 of 7'), findsOne);
    });

    testWidgets('stopped retrying offers Reconnect', (tester) async {
      var asked = 0;
      await _pumpBox(
        tester,
        SleuthStatusBox(
          kind: SleuthStatusKind.stoppedRetrying,
          run: const SleuthRunState(
            phase: SleuthRunPhase.running,
            everConnected: true,
            stoppedRetrying: true,
          ),
          coverage: _coverage(on: 19),
          onReconnect: () => asked++,
        ),
      );
      await tester.tap(find.bySemanticsLabel('Reconnect'));
      expect(asked, 1);
    });

    testWidgets('a live region whose label holds while the countdown moves '
        'in the value', (tester) async {
      final start = DateTime.now();
      await _pumpBox(
        tester,
        SleuthStatusBox(
          kind: SleuthStatusKind.warmingUp,
          run: const SleuthRunState(
            phase: SleuthRunPhase.warmingUp,
            vmConnected: true,
            everConnected: true,
          ),
          coverage: _coverage(on: 19),
          initializedAt: start,
          warmupDuration: const Duration(seconds: 3),
        ),
      );
      final node = find.bySemanticsLabel('Warming up');
      expect(tester.widget<Semantics>(node).properties.liveRegion, isTrue);
      final firstValue = tester.getSemantics(node).value;
      expect(firstValue, '0 of 3 seconds');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await tester.pump(const Duration(seconds: 1));
      final second = tester.getSemantics(node);
      expect(second.label, 'Warming up');
      expect(second.value, isNot(firstValue));
    });
  });

  group('in the card', () {
    late SleuthController controller;

    setUp(
      () =>
          controller = _ReconnectingController()..initializeDetectorsForTest(),
    );
    tearDown(() => controller.dispose());

    Future<void> pumpCard(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(
              controller: controller,
              onClose: () {},
              isDebugMode: false,
            ),
          ),
        ),
      );
      await tester.pump();
    }

    PerformanceIssue issue(String id) => PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.likely,
      title: 'Title $id',
      detail: 'D',
      fixHint: 'F',
      stableId: id,
    );

    testWidgets('an empty list shows the status line and the row names it', (
      tester,
    ) async {
      controller.runStateNotifier.value = const SleuthRunState(
        phase: SleuthRunPhase.running,
        vmConnected: true,
        everConnected: true,
      );
      controller.coverageNotifier.value = _coverage(on: 19, optIn: 2);
      await pumpCard(tester);
      expect(find.byType(SleuthStatusBox), findsOneWidget);
      expect(find.text('No issues'), findsOneWidget);
      expect(find.text('No issues found.'), findsOneWidget);
    });

    testWidgets('with cards listed, only a lost link takes the line', (
      tester,
    ) async {
      controller.issuesNotifier.value = [issue('a')];
      controller.runStateNotifier.value = const SleuthRunState(
        phase: SleuthRunPhase.running,
        vmConnected: true,
        everConnected: true,
      );
      await pumpCard(tester);
      expect(find.byType(SleuthStatusBox), findsNothing);
      controller.runStateNotifier.value = const SleuthRunState(
        phase: SleuthRunPhase.running,
        everConnected: true,
        reconnectAttempt: 1,
        maxReconnectAttempts: 7,
      );
      await tester.pump();
      expect(find.byType(SleuthStatusBox), findsOneWidget);
      expect(find.text('Title a'), findsOneWidget);
    });

    testWidgets('a lost link shows above an expanded card whose issue is '
        'gone', (tester) async {
      controller.issuesNotifier.value = [issue('a')];
      controller.runStateNotifier.value = const SleuthRunState(
        phase: SleuthRunPhase.running,
        vmConnected: true,
        everConnected: true,
      );
      await pumpCard(tester);
      await tester.tap(find.text('Title a'));
      await tester.pump();
      controller.issuesNotifier.value = const [];
      await tester.pump();
      expect(find.text('Not detected right now'), findsOneWidget);
      controller.runStateNotifier.value = const SleuthRunState(
        phase: SleuthRunPhase.running,
        everConnected: true,
        stoppedRetrying: true,
      );
      await tester.pump();
      expect(find.byType(SleuthStatusBox), findsOneWidget);
      expect(find.bySemanticsLabel('Reconnect'), findsOneWidget);
    });

    testWidgets('a reconnect with cards listed moves the screen reader to '
        'the header', (tester) async {
      controller.issuesNotifier.value = [issue('a')];
      controller.runStateNotifier.value = const SleuthRunState(
        phase: SleuthRunPhase.running,
        everConnected: true,
        stoppedRetrying: true,
      );
      await pumpCard(tester);
      final focused = _recordScreenReaderFocus(tester);
      await tester.tap(find.bySemanticsLabel('Reconnect'));
      await tester.pump();
      await tester.pump();
      expect(find.byType(SleuthStatusBox), findsNothing);
      expect(focused, isNotEmpty);
      expect(
        focused.last,
        tester.getSemantics(find.bySemanticsLabel(RegExp('^Sleuth'))).id,
      );
    });

    testWidgets('a lost link toasts while no action toast holds the slot', (
      tester,
    ) async {
      controller.vmConnectedNotifier.value = true;
      await pumpCard(tester);
      controller.vmConnectedNotifier.value = false;
      await tester.pump();
      expect(find.textContaining('VM link lost. Checks'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
    }, semanticsEnabled: false);

    testWidgets('an Undo toast keeps the slot when the link drops', (
      tester,
    ) async {
      controller.issuesNotifier.value = [issue('a')];
      controller.vmConnectedNotifier.value = true;
      await pumpCard(tester);
      await tester.tap(find.text('Title a'));
      await tester.pump();
      // Semantics are off here, so the button is found by its icon.
      final hide = find.byIcon(Icons.visibility_off_outlined);
      await tester.ensureVisible(hide);
      await tester.pump();
      await tester.tap(hide);
      await tester.pump();
      expect(find.text('Undo'), findsOneWidget);
      controller.vmConnectedNotifier.value = false;
      await tester.pump();
      expect(find.textContaining('VM link lost. Checks'), findsNothing);
      expect(find.text('Undo'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
    }, semanticsEnabled: false);

    testWidgets('under a screen reader the status line says it instead', (
      tester,
    ) async {
      controller.vmConnectedNotifier.value = true;
      await pumpCard(tester);
      controller.vmConnectedNotifier.value = false;
      await tester.pump();
      expect(find.textContaining('VM link lost. Checks'), findsNothing);
    });

    testWidgets('under a screen reader the toast still comes when the '
        'status line is out of reach', (tester) async {
      controller.vmConnectedNotifier.value = true;
      await pumpCard(tester);
      await tester.tap(find.bySemanticsLabel('Minimize'));
      await tester.pump();
      controller.vmConnectedNotifier.value = false;
      await tester.pump();
      expect(find.textContaining('VM link lost. Checks'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('Copy command copies the run command and confirms', (
      tester,
    ) async {
      String? copied;
      controller.runStateNotifier.value = const SleuthRunState(
        phase: SleuthRunPhase.running,
      );
      controller.coverageNotifier.value = _coverage(on: 10, needsVm: 6);
      await pumpCard(tester);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      await tester.tap(find.bySemanticsLabel('Copy command'));
      await tester.pump();
      expect(copied, sleuthRunCommand);
      expect(find.text('Command copied'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
    });
  });
}
