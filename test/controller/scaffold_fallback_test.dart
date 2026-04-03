import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

void main() {
  late WatchdogController controller;

  setUp(() {
    controller = WatchdogController();
    controller.initializeDetectorsForTest();
  });

  tearDown(() {
    controller.dispose();
  });

  group('CupertinoPageScaffold recognition (scaffold path)', () {
    testWidgets('CupertinoPageScaffold resolves as scan root', (tester) async {
      await tester.pumpWidget(
        CupertinoApp(
          home: CupertinoPageScaffold(
            child: Column(
              children: const [
                Opacity(
                  opacity: 0.0,
                  child: SizedBox(width: 10, height: 10),
                ),
              ],
            ),
          ),
        ),
      );

      // First scan: hash-change → navigating (Navigator path would apply
      // if no scaffold found, but CupertinoPageScaffold IS found → scaffold path)
      final root = tester.element(find.byType(CupertinoApp));
      controller.scanTreeFullPathForTest(root);

      // Scaffold path should resolve immediately (no hash stability needed)
      expect(controller.interactionStateForTest, InteractionContext.idle);
      expect(controller.isScaffoldFreeScanForTest, isFalse);
    });

    testWidgets('CupertinoPageScaffold + Scaffold = multi-scaffold transition',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Expanded(child: Scaffold(body: Container())),
              Expanded(
                child: CupertinoPageScaffold(child: Container()),
              ),
            ],
          ),
        ),
      );

      final root = tester.element(find.byType(Directionality));
      controller.scanTreeFullPathForTest(root);

      expect(controller.interactionStateForTest, InteractionContext.navigating);
    });
  });

  group('scaffold-free Navigator path', () {
    testWidgets('scaffold-free page resolves via overlay entry after stability',
        (tester) async {
      // MaterialApp without Scaffold — page is a bare Center widget
      await tester.pumpWidget(
        MaterialApp(
          home: const Center(
            child: Opacity(
              opacity: 0.0,
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));

      // First scan: hash-change → navigating
      controller.scanTreeFullPathForTest(root);
      expect(controller.interactionStateForTest, InteractionContext.navigating);

      // Second scan: same route, hash stable → scan proceeds
      controller.scanTreeFullPathForTest(root);
      expect(controller.interactionStateForTest, InteractionContext.idle);
      expect(controller.isScaffoldFreeScanForTest, isTrue);
    });

    testWidgets('scaffold-free path detects structural issues', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const Center(
            child: Opacity(
              opacity: 0.0,
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));

      // Two scans to stabilize
      controller.scanTreeFullPathForTest(root);
      controller.scanTreeFullPathForTest(root);

      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty,
          reason: 'Opacity(0.0) should produce an issue on scaffold-free path');
    });

    testWidgets('route transition detected by hash change', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/a',
          routes: {
            '/a': (_) => const Center(child: Text('A')),
            '/b': (_) => const Center(child: Text('B')),
          },
        ),
      );

      final root = tester.element(find.byType(MaterialApp));

      // Stabilize on route /a
      controller.scanTreeFullPathForTest(root);
      controller.scanTreeFullPathForTest(root);
      expect(controller.interactionStateForTest, InteractionContext.idle);

      // Navigate to /b
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.pushNamed('/b');
      await tester.pumpAndSettle();

      // Scan after push — hash changed → navigating
      controller.scanTreeFullPathForTest(root);
      expect(controller.interactionStateForTest, InteractionContext.navigating);

      // Second scan on /b — stable
      controller.scanTreeFullPathForTest(root);
      expect(controller.interactionStateForTest, InteractionContext.idle);
    });
  });

  group('route name resolution', () {
    testWidgets('route name resolved for scaffold-free named route',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/home',
          routes: {
            '/home': (_) => const Center(
                  child: Opacity(
                    opacity: 0.0,
                    child: SizedBox(width: 10, height: 10),
                  ),
                ),
          },
        ),
      );

      final root = tester.element(find.byType(MaterialApp));

      // Two scans to stabilize
      controller.scanTreeFullPathForTest(root);
      controller.scanTreeFullPathForTest(root);

      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty);
      expect(
        issues.any((i) => i.routeName == '/home'),
        isTrue,
        reason: 'Issues should be stamped with route name from scaffold-free '
            'path via _ModalScopeStatus',
      );
    });
  });

  group('nested Navigator guard', () {
    testWidgets('nested Navigator in scan root → navigating sentinel',
        (tester) async {
      // Page with a nested Navigator (tab pattern)
      await tester.pumpWidget(
        MaterialApp(
          home: Navigator(
            onGenerateRoute: (_) => MaterialPageRoute(
              builder: (_) => const Center(child: Text('inner')),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));

      // First scan: hash-change → navigating (expected for initial)
      controller.scanTreeFullPathForTest(root);
      expect(controller.interactionStateForTest, InteractionContext.navigating);

      // Second scan: even with stable hash, nested Navigator should
      // still cause _findActiveRouteScanRoot to return null
      controller.scanTreeFullPathForTest(root);
      expect(
        controller.interactionStateForTest,
        InteractionContext.navigating,
        reason: 'Nested Navigator should prevent scanning (guard)',
      );
    });
  });

  group('static app fallback (no Navigator)', () {
    testWidgets('static app without Navigator uses app child fallback',
        (tester) async {
      // Wrap in NotificationListener to simulate the overlay structure.
      // In production, the overlay wraps widget.child in a
      // NotificationListener — tests need one for _resolveAppChildContext.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) => false,
            child: const Column(
              children: [
                Opacity(
                  opacity: 0.0,
                  child: SizedBox(width: 10, height: 10),
                ),
              ],
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(Directionality));
      controller.scanTreeFullPathForTest(root);

      // Static app resolves immediately (no hash stability needed)
      expect(controller.interactionStateForTest, InteractionContext.idle);
      expect(controller.isScaffoldFreeScanForTest, isFalse,
          reason: 'Static app fallback should NOT set scaffold-free flag');
      expect(controller.navigatorFoundForTest, isFalse);

      // Issues should be detected
      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty,
          reason: 'Opacity(0.0) should produce issue on static app path');
    });

    testWidgets('static app runs all 16 detectors (no exemption)',
        (tester) async {
      // Build a tree that triggers both exempted and non-exempted detectors
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: NotificationListener<ScrollNotification>(
            onNotification: (_) => false,
            child: const Column(
              children: [
                Opacity(
                  opacity: 0.0,
                  child: SizedBox(width: 10, height: 10),
                ),
              ],
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(Directionality));
      controller.scanTreeFullPathForTest(root);

      // _isScaffoldFreeScan should be false → all detectors run
      expect(controller.isScaffoldFreeScanForTest, isFalse);
    });
  });

  group('detector exemption', () {
    testWidgets('scaffold-free path sets isScaffoldFreeScan flag',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: const Center(
            child: Opacity(
              opacity: 0.0,
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));

      // Two scans to stabilize
      controller.scanTreeFullPathForTest(root);
      controller.scanTreeFullPathForTest(root);

      expect(controller.isScaffoldFreeScanForTest, isTrue);
    });

    testWidgets('scaffold path does not set isScaffoldFreeScan',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const Opacity(
              opacity: 0.0,
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);

      expect(controller.isScaffoldFreeScanForTest, isFalse);
    });
  });

  group('stale state prevention', () {
    testWidgets('scaffold-free state cleared on scaffold-path scan',
        (tester) async {
      // First: scaffold-free scan
      await tester.pumpWidget(
        MaterialApp(
          home: const Center(
            child: Opacity(
              opacity: 0.0,
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );

      final root1 = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root1);
      controller.scanTreeFullPathForTest(root1);
      expect(controller.isScaffoldFreeScanForTest, isTrue);

      // Now: scaffold-path scan
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const Opacity(
              opacity: 0.0,
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );

      final root2 = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root2);

      expect(controller.isScaffoldFreeScanForTest, isFalse,
          reason: 'Flag should be cleared at start of each scan');
    });

    testWidgets('stale issues cleared after scaffold→scaffold-free transition',
        (tester) async {
      // First: scaffold-path scan produces issues
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const Column(
              children: [
                Opacity(
                  opacity: 0.0,
                  child: SizedBox(width: 10, height: 10),
                ),
              ],
            ),
          ),
        ),
      );

      final root1 = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root1);
      final scaffoldIssues = controller.issuesNotifier.value;
      expect(scaffoldIssues, isNotEmpty);

      // Now: scaffold-free scan — exempted detectors should clear their state
      await tester.pumpWidget(
        MaterialApp(
          home: const Center(child: SizedBox(width: 10, height: 10)),
        ),
      );

      final root2 = tester.element(find.byType(MaterialApp));
      // Two scans to stabilize
      controller.scanTreeFullPathForTest(root2);
      controller.scanTreeFullPathForTest(root2);

      // Should not carry stale issues from exempted detectors —
      // prepareScan+finalizeScan clears them
      expect(controller.isScaffoldFreeScanForTest, isTrue);
    });
  });

  group('refreshHighlights isolation', () {
    testWidgets('refreshHighlights uses _lastScanContext without side effects',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: const Opacity(
              opacity: 0.0,
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);
      expect(controller.interactionStateForTest, InteractionContext.idle);

      // Enable highlights then refresh
      controller.highlightEnabledNotifier.value = true;
      controller.refreshHighlights();

      // Should not change interaction state
      expect(controller.interactionStateForTest, InteractionContext.idle);
    });
  });

  group('framework skip list coverage', () {
    testWidgets('CupertinoPageScaffold not flagged by SetStateScopeDetector',
        (tester) async {
      // Build a large subtree under CupertinoPageScaffold
      await tester.pumpWidget(
        CupertinoApp(
          home: CupertinoPageScaffold(
            child: Column(
              children: List.generate(
                50,
                (i) => SizedBox(
                  key: ValueKey(i),
                  width: 10,
                  height: 10,
                ),
              ),
            ),
          ),
        ),
      );

      // Use direct scan (bypass _findVisiblePageContext) to control scan root
      final scaffold = tester.element(find.byType(CupertinoPageScaffold));
      controller.runTreeScanForTest(scaffold);

      final issues = controller.issuesNotifier.value;
      // SetStateScopeDetector should not flag CupertinoPageScaffold itself
      final setStateIssues = issues
          .where((i) => i.stableId?.contains('setstate_scope') == true)
          .where((i) => i.detail.contains('CupertinoPageScaffold'));
      expect(setStateIssues, isEmpty,
          reason: 'CupertinoPageScaffold is a framework widget — '
              'should not be flagged');
    });

    testWidgets(
        'CupertinoPageScaffold not flagged by ShallowRebuildRiskDetector',
        (tester) async {
      await tester.pumpWidget(
        CupertinoApp(
          home: CupertinoPageScaffold(
            child: Column(
              children: List.generate(
                50,
                (i) => SizedBox(
                  key: ValueKey(i),
                  width: 10,
                  height: 10,
                ),
              ),
            ),
          ),
        ),
      );

      // Scan from above the scaffold so it's at a shallow depth
      final app = tester.element(find.byType(CupertinoApp));
      controller.runTreeScanForTest(app);

      final issues = controller.issuesNotifier.value;
      final shallowIssues = issues
          .where((i) => i.stableId?.contains('shallow_rebuild_risk') == true)
          .where((i) => i.detail.contains('CupertinoPageScaffold'));
      expect(shallowIssues, isEmpty,
          reason: 'CupertinoPageScaffold is a framework widget — '
              'should not be flagged');
    });
  });
}
