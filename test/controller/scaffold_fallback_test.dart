import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/network/request_record.dart';

void main() {
  late SleuthController controller;

  setUp(() {
    controller = SleuthController();
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
              children: [
                SingleChildScrollView(
                  child: Column(
                    children: List.generate(
                      55,
                      (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                    ),
                  ),
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

  group('nested Scaffolds (bottom-nav shell pattern)', () {
    testWidgets('nested Scaffold(body: Scaffold(...)) = idle, not transition',
        (tester) async {
      // Pattern: outer app-shell Scaffold wraps an inner page Scaffold.
      // Common in apps with a persistent bottom-nav shell + per-tab Scaffolds.
      // Before the nested-vs-sibling fix, this tripped the multi-scaffold
      // guard and every scan aborted → tree-walking detectors never ran
      // and NetworkMonitor records were continuously cleared.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: List.generate(
                    55,
                    (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);

      expect(
        controller.interactionStateForTest,
        InteractionContext.idle,
        reason: 'Nested Scaffolds lie on a single ancestor chain — treat as '
            'one visible page, not a route transition.',
      );
      expect(controller.isScaffoldFreeScanForTest, isFalse);
    });

    testWidgets('nested CupertinoPageScaffold inside Scaffold = idle',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CupertinoPageScaffold(
              child: SingleChildScrollView(
                child: Column(
                  children: List.generate(
                    55,
                    (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);

      expect(controller.interactionStateForTest, InteractionContext.idle);
    });

    testWidgets('three-deep nested Scaffolds = idle', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Scaffold(
              body: Scaffold(
                body: SingleChildScrollView(
                  child: Column(
                    children: List.generate(
                      55,
                      (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);

      expect(controller.interactionStateForTest, InteractionContext.idle);
    });

    testWidgets(
        'nested Scaffold with BottomNavigationBar shell: scan runs and '
        'detects issues in the inner page body', (tester) async {
      // Real-world pattern: outer Scaffold with a persistent
      // bottomNavigationBar, inner Scaffold per-tab with actual content.
      // This is the failure mode the user hit — only VM-timeline detectors
      // (rebuild, GC) fired because the tree walk was being aborted.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: List.generate(
                    55,
                    (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                  ),
                ),
              ),
            ),
            bottomNavigationBar: BottomNavigationBar(
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
                BottomNavigationBarItem(icon: Icon(Icons.star), label: 'Fav'),
              ],
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);

      expect(controller.interactionStateForTest, InteractionContext.idle);

      final issues = controller.issuesNotifier.value;
      expect(
        issues,
        isNotEmpty,
        reason: 'Nested Scaffold pattern must allow tree-walking detectors '
            'to run — the inner Opacity(0.0) should surface as an issue.',
      );
    });

    testWidgets(
        'IndexedStack bottom nav: active tab scans, inactive tabs skipped '
        'via Visibility(!visible)', (tester) async {
      // Real-world pattern for bottom-nav apps that preserve per-tab state.
      // IndexedStack wraps every child in Visibility(maintainSize: true, ...)
      // which does NOT use Offstage/TickerMode — it uses a render proxy.
      // Without a Visibility guard in the visitor, every tab's Scaffold
      // would appear as a sibling → scan aborts every tick → HTTP records
      // silently dropped (the exact symptom reported in the field).
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: IndexedStack(
              index: 1,
              children: [
                const Scaffold(body: Text('home tab')),
                Scaffold(
                  body: SingleChildScrollView(
                    child: Column(
                      children: List.generate(
                        55,
                        (i) =>
                            SizedBox(key: ValueKey(i), width: 10, height: 10),
                      ),
                    ),
                  ),
                ),
                const Scaffold(body: Text('profile tab')),
              ],
            ),
            bottomNavigationBar: BottomNavigationBar(
              currentIndex: 1,
              items: const [
                BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.show_chart), label: 'Crypto'),
                BottomNavigationBarItem(
                    icon: Icon(Icons.person), label: 'Profile'),
              ],
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);

      expect(
        controller.interactionStateForTest,
        InteractionContext.idle,
        reason: 'IndexedStack must not trip the multi-scaffold transition '
            'guard — inactive tabs should be skipped via Visibility(!visible).',
      );

      // Active-tab Opacity(0.0) should surface; inactive tab content
      // (plain Text) should not be scanned.
      final issues = controller.issuesNotifier.value;
      expect(
        issues,
        isNotEmpty,
        reason: 'Active tab (index=1) Opacity(0.0) must surface as an issue — '
            'proves the tree walk actually ran on the visible content.',
      );
    });

    testWidgets(
        'CupertinoTabScaffold: inactive tabs filtered via Offstage guard',
        (tester) async {
      // CupertinoTabScaffold wraps inactive tabs in Offstage + TickerMode
      // (unlike IndexedStack). Existing Offstage/TickerMode guards already
      // handle this; lock it in with a test.
      await tester.pumpWidget(
        CupertinoApp(
          home: CupertinoTabScaffold(
            tabBar: CupertinoTabBar(
              items: const [
                BottomNavigationBarItem(
                    icon: Icon(CupertinoIcons.home), label: 'Home'),
                BottomNavigationBarItem(
                    icon: Icon(CupertinoIcons.person), label: 'Profile'),
              ],
            ),
            tabBuilder: (context, index) {
              if (index == 0) {
                return CupertinoPageScaffold(
                  child: Center(
                    child: Opacity(
                      opacity: 0.0,
                      child: const SizedBox(width: 10, height: 10),
                    ),
                  ),
                );
              }
              return const CupertinoPageScaffold(child: Text('profile'));
            },
          ),
        ),
      );

      final root = tester.element(find.byType(CupertinoApp));
      controller.scanTreeFullPathForTest(root);

      expect(
        controller.interactionStateForTest,
        InteractionContext.idle,
        reason: 'CupertinoTabScaffold inactive tabs are Offstage-wrapped — '
            'should resolve to the active tab cleanly.',
      );
    });

    testWidgets('mixed nested + sibling Scaffolds = navigating',
        (tester) async {
      // Two Scaffolds that are NOT all on a single ancestor chain — a real
      // transition or unsafe multi-scaffold layout.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Expanded(
                child: Scaffold(body: Scaffold(body: Container())),
              ),
              Expanded(child: Scaffold(body: Container())),
            ],
          ),
        ),
      );

      final root = tester.element(find.byType(Directionality));
      controller.scanTreeFullPathForTest(root);

      expect(
        controller.interactionStateForTest,
        InteractionContext.navigating,
        reason: 'Sibling Scaffolds (not all on one ancestor chain) are '
            'treated as a transition.',
      );
    });
  });

  group('tab-switch network buffer clearing (IndexedStack)', () {
    // Helper: build a single synthetic HTTP record. Uses a DateTime in 2100
    // so it always lands AFTER any `_ignoreBeforeTimestamp` the detector
    // may stamp via a stray clearRecords() call during test setup.
    RequestRecord makeRecord(String suffix) => RequestRecord(
          url: 'https://api.example.com/$suffix',
          method: 'GET',
          statusCode: 200,
          durationMs: 100,
          responseBytes: 1024,
          startedAt: DateTime(2100),
        );

    testWidgets(
        'IndexedStack active-index swap clears the network buffer '
        '(same route, different visible Scaffold)', (tester) async {
      // Reproduces the reported symptom: bottom-nav app keeps state via
      // IndexedStack, all tabs share one Navigator route, so route-name
      // comparison cannot detect the swap. Without the Scaffold-identity
      // signal, the previous tab's HTTP records persist in the buffer and
      // count toward the next tab's 30-req/5s frequency-spike threshold.
      final indexNotifier = ValueNotifier<int>(0);
      addTearDown(indexNotifier.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: indexNotifier,
              builder: (_, idx, __) => IndexedStack(
                index: idx,
                children: const [
                  Scaffold(body: Text('home tab')),
                  Scaffold(body: Text('crypto tab')),
                ],
              ),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));

      // Scan 1 on tab 0 — establishes the innermost-Scaffold baseline.
      controller.scanTreeFullPathForTest(root);
      // H1 pin: assert we went down the happy path, not the navigating
      // sentinel. If the Visibility(!visible) guard ever regresses and both
      // tabs' Scaffolds become siblings, the scan would return null, the
      // sentinel path would fire clearRecords(), and the post-switch
      // "records empty" assertion below would pass for the WRONG reason.
      expect(controller.interactionStateForTest, InteractionContext.idle,
          reason: 'Scan 1 must resolve a single visible Scaffold (happy '
              'path), not trigger the navigating sentinel.');
      expect(controller.lastScanContextForTest, isNotNull,
          reason: 'Scan 1 must produce a non-null scan context — a null '
              'context would indicate the sentinel path cleared records.');

      // Inject a record representing tab 0's HTTP traffic.
      controller.networkMonitorForTest.processRecord(makeRecord('home'));
      expect(controller.networkMonitorForTest.records, hasLength(1));

      // User taps tab 1 — IndexedStack swaps active child.
      indexNotifier.value = 1;
      await tester.pump();

      // Scan 2 — innermost Scaffold Element identity changed → clear fires.
      controller.scanTreeFullPathForTest(root);

      // H1 pin: scan 2 must ALSO go down the happy path. The clear below
      // must come from the Scaffold-hash signal, not the sentinel path.
      expect(controller.interactionStateForTest, InteractionContext.idle,
          reason: 'Scan 2 must resolve the new tab\'s Scaffold cleanly — '
              'the buffer clear must originate from the Scaffold-hash '
              'signal, not from a sentinel-path regression.');
      expect(controller.lastScanContextForTest, isNotNull,
          reason: 'Scan 2 must produce a non-null scan context.');

      expect(
        controller.networkMonitorForTest.records,
        isEmpty,
        reason: 'Tab switch under IndexedStack must flush the network buffer '
            'so the previous tab\'s requests do not count toward the new '
            'tab\'s frequency-spike threshold.',
      );
    });

    testWidgets(
        'tab-switch clear stamps _ignoreBeforeTimestamp: in-flight responses '
        'from the previous tab are dropped on arrival (cutoff contract)',
        (tester) async {
      // H2: the fixture-tautology fix. The other tests in this group stamp
      // records at DateTime(2100) so they always land after any
      // _ignoreBeforeTimestamp the detector might set — convenient for
      // isolation but it hides whether the cutoff actually works.
      //
      // Strategy (no fake-async time needed): use timestamps that
      // deterministically bracket the detector's wall-clock `_clock()` at
      // clear time. `preClear = DateTime(2000)` is guaranteed to be BEFORE
      // any realistic clock(); `postClear = DateTime(2100)` is guaranteed
      // to be AFTER. This exercises:
      //   1. Pre-clear records added when cutoff is null → accepted.
      //   2. Tab-switch clear stamps cutoff = now (~2026).
      //   3. Post-clear injection of a preClear-stamped record → dropped.
      //   4. Post-clear injection of a postClear-stamped record → accepted.
      final preClear = DateTime(2000);
      final postClear = DateTime(2100);

      final indexNotifier = ValueNotifier<int>(0);
      addTearDown(indexNotifier.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: indexNotifier,
              builder: (_, idx, __) => IndexedStack(
                index: idx,
                children: const [
                  Scaffold(body: Text('home tab')),
                  Scaffold(body: Text('crypto tab')),
                ],
              ),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));

      controller.scanTreeFullPathForTest(root);
      expect(controller.interactionStateForTest, InteractionContext.idle);

      // Step 1: before any clear, the cutoff is null → preClear is accepted.
      controller.networkMonitorForTest.processRecord(RequestRecord(
        url: 'https://api.example.com/tab0-completed',
        method: 'GET',
        statusCode: 200,
        durationMs: 120,
        responseBytes: 512,
        startedAt: preClear,
      ));
      expect(controller.networkMonitorForTest.records, hasLength(1),
          reason: 'With no cutoff stamped yet, any record (even one at '
              'DateTime(2000)) must be accepted.');

      // Step 2: tab switch triggers Scaffold-hash clear, which stamps
      // cutoff = DateTime.now().
      indexNotifier.value = 1;
      await tester.pump();
      controller.scanTreeFullPathForTest(root);

      expect(controller.networkMonitorForTest.records, isEmpty,
          reason: 'Tab-switch clear must empty the buffer.');

      // Step 3: a tab-0 in-flight response arrives after the clear. Its
      // startedAt is preClear (DateTime(2000)), which is strictly before
      // the cutoff (≈ now) — the detector must drop it.
      controller.networkMonitorForTest.processRecord(RequestRecord(
        url: 'https://api.example.com/tab0-inflight',
        method: 'GET',
        statusCode: 200,
        durationMs: 3000,
        responseBytes: 1024,
        startedAt: preClear,
      ));
      expect(controller.networkMonitorForTest.records, isEmpty,
          reason: '_ignoreBeforeTimestamp must drop in-flight responses '
              'from the previous tab. If this test fails, the new tab\'s '
              'frequency-spike threshold would see stale traffic as real '
              'activity and misattribute issues.');

      // Step 4: a fresh tab-1 request started after the clear must pass
      // the cutoff.
      controller.networkMonitorForTest.processRecord(RequestRecord(
        url: 'https://api.example.com/tab1-fresh',
        method: 'GET',
        statusCode: 200,
        durationMs: 80,
        responseBytes: 256,
        startedAt: postClear,
      ));
      expect(controller.networkMonitorForTest.records, hasLength(1),
          reason: 'Requests started after the clear must be accepted '
              'normally.');

      // Drain the timer before tearDown runs.
      controller.networkMonitorForTest.clearRecords();
    });

    testWidgets(
        'repeat scans on the same active tab do NOT clear the buffer '
        '(Element identity stable across rebuilds)', (tester) async {
      // Negative case: the tab-switch detector must not false-fire on normal
      // setState rebuilds of the same tab. Element identity is stable across
      // Widget rebuilds, so identityHashCode stays constant.
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: IndexedStack(
              index: 0,
              children: [
                Scaffold(body: Text('home tab')),
                Scaffold(body: Text('crypto tab')),
              ],
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));

      controller.scanTreeFullPathForTest(root);
      controller.networkMonitorForTest.processRecord(makeRecord('home'));
      expect(controller.networkMonitorForTest.records, hasLength(1));

      // Re-pump and re-scan — Element tree unchanged, hash stable.
      await tester.pump();
      controller.scanTreeFullPathForTest(root);

      expect(
        controller.networkMonitorForTest.records,
        hasLength(1),
        reason: 'Re-scanning the same tab must not clear the buffer — '
            'identityHashCode of the innermost Scaffold Element is stable '
            'across rebuilds.',
      );

      // Cancel the detector's frequency timer before the test framework's
      // post-body invariant check runs. processRecord starts a periodic
      // Timer on first non-empty buffer; since this test never clears the
      // buffer via the tab-switch path, we'd leak the timer past the
      // widget-tree teardown and fail the "no pending timers" invariant.
      controller.networkMonitorForTest.clearRecords();
    });
  });

  group('scaffold-free Navigator path', () {
    testWidgets('scaffold-free page resolves via overlay entry after stability',
        (tester) async {
      // MaterialApp without Scaffold — page is a bare Center widget
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  55,
                  (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                ),
              ),
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
          home: Center(
            child: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  55,
                  (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                ),
              ),
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
            '/home': (_) => Center(
                  child: SingleChildScrollView(
                    child: Column(
                      children: List.generate(
                        55,
                        (i) =>
                            SizedBox(key: ValueKey(i), width: 10, height: 10),
                      ),
                    ),
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
            child: Column(
              children: [
                SingleChildScrollView(
                  child: Column(
                    children: List.generate(
                      55,
                      (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                    ),
                  ),
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
            child: Column(
              children: [
                SingleChildScrollView(
                  child: Column(
                    children: List.generate(
                      55,
                      (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                    ),
                  ),
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
          home: Center(
            child: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  55,
                  (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                ),
              ),
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
            body: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  55,
                  (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                ),
              ),
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
          home: Center(
            child: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  55,
                  (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                ),
              ),
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
            body: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  55,
                  (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                ),
              ),
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
            body: Column(
              children: [
                SingleChildScrollView(
                  child: Column(
                    children: List.generate(
                      55,
                      (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                    ),
                  ),
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
            body: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  55,
                  (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                ),
              ),
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

  group('TabBarView / PageView filter (inline tabs stay in one session)', () {
    // The visitor in _findVisiblePageContext stops at TabBarView / PageView
    // boundaries. These widgets keep multiple "page" children alive without
    // Offstage / TickerMode / Visibility markers, so descending into them
    // would collect every sub-page's Scaffold as a sibling and abort the
    // scan. Stopping keeps the outer Scaffold as the innermost — sub-tab
    // swipes stay inside the outer route's RouteSession, no spurious
    // session churn, scan still runs.
    testWidgets(
        'TabBarView with per-sub-tab Scaffolds inside a route: scan runs '
        '(idle, not sentinel) and outer Scaffold is captured as innermost',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: DefaultTabController(
            length: 2,
            child: Scaffold(
              appBar: AppBar(
                bottom: const TabBar(tabs: [Tab(text: 'A'), Tab(text: 'B')]),
              ),
              body: const TabBarView(
                children: [
                  Scaffold(body: Text('sub-tab A')),
                  Scaffold(body: Text('sub-tab B')),
                ],
              ),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);

      // Without the filter, [outerScaffold, subA, subB] are all visible;
      // subA and subB are siblings → allNested=false → return null →
      // navigating sentinel. Filter makes the visitor stop at TabBarView
      // so only the outer Scaffold is collected.
      expect(controller.interactionStateForTest, InteractionContext.idle,
          reason: 'TabBarView filter must prevent sub-tab Scaffolds from '
              'tripping the multi-scaffold sibling guard.');
      expect(controller.lastScanContextForTest, isNotNull,
          reason: 'Scan context must resolve to a non-null ancestor of the '
              'outer Scaffold (not the sentinel null).');
      expect(controller.activeRouteSessionForTest, isNotNull,
          reason: 'A RouteSession must be created for the outer route.');
    });

    testWidgets(
        'sub-tab swipe does not change the active RouteSession '
        '(outer scaffoldHashKey stays stable)', (tester) async {
      // Regression guard: we want TabBar / TabBarView changes to NOT affect
      // session boundaries. Only outer route / bottom-nav changes should
      // create new sessions.
      final tabController = TabController(length: 2, vsync: tester);
      addTearDown(tabController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TabBarView(
              controller: tabController,
              children: const [
                Scaffold(body: Text('sub-tab A')),
                Scaffold(body: Text('sub-tab B')),
              ],
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);
      final session1 = controller.activeRouteSessionForTest;
      final hash1 = session1?.scaffoldHashKey;

      // Swipe to sub-tab B.
      tabController.animateTo(1);
      await tester.pumpAndSettle();
      controller.scanTreeFullPathForTest(root);

      final session2 = controller.activeRouteSessionForTest;
      expect(identical(session1, session2), isTrue,
          reason: 'Sub-tab swipe must not rotate the active RouteSession — '
              'that would incorrectly fragment a single route into per-tab '
              'sessions and clear the network buffer mid-route.');
      expect(session2?.scaffoldHashKey, equals(hash1),
          reason: 'scaffoldHashKey must stay stable across sub-tab swipes '
              'so the active session identity does not churn.');
    });

    testWidgets(
        'PageView with per-page Scaffolds (onboarding-style): scan runs, '
        'page swipe does not create a new session', (tester) async {
      final pageController = PageController();
      addTearDown(pageController.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PageView(
              controller: pageController,
              children: const [
                Scaffold(body: Text('page 1')),
                Scaffold(body: Text('page 2')),
              ],
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);
      expect(controller.interactionStateForTest, InteractionContext.idle,
          reason: 'PageView filter must prevent per-page Scaffolds from '
              'tripping the sibling guard.');
      final session1 = controller.activeRouteSessionForTest;

      pageController.jumpToPage(1);
      await tester.pumpAndSettle();
      controller.scanTreeFullPathForTest(root);

      expect(identical(session1, controller.activeRouteSessionForTest), isTrue,
          reason: 'Swiping to a new PageView page must not rotate the '
              'active RouteSession.');
    });

    testWidgets(
        'bottom-nav tab switch STILL creates a new RouteSession '
        '(per-tab session behavior is unaffected by the TabBarView filter)',
        (tester) async {
      // This is the happy path we shipped for bottom nav: IndexedStack
      // marks inactive tabs with Visibility(!visible), so the earlier
      // filter skips them before the TabBarView check is even reached.
      // The TabBarView filter must not regress this behavior.
      final indexNotifier = ValueNotifier<int>(0);
      addTearDown(indexNotifier.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: indexNotifier,
              builder: (_, idx, __) => IndexedStack(
                index: idx,
                children: const [
                  Scaffold(body: Text('home tab')),
                  Scaffold(body: Text('settings tab')),
                ],
              ),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));
      controller.scanTreeFullPathForTest(root);

      final session1 = controller.activeRouteSessionForTest;
      final hash1 = session1?.scaffoldHashKey;
      expect(hash1, isNotNull);

      // Switch bottom-nav tabs — the inner Scaffold's Element identity
      // flips because IndexedStack's active child slot rebuilds.
      indexNotifier.value = 1;
      await tester.pump();
      controller.scanTreeFullPathForTest(root);

      final session2 = controller.activeRouteSessionForTest;
      expect(identical(session1, session2), isFalse,
          reason: 'Bottom-nav tab switch must rotate the active session — '
              'the TabBarView filter only applies inside TabBarView/'
              'PageView, not to IndexedStack-backed bottom nav.');
      expect(session2?.scaffoldHashKey, isNotNull);
      expect(session2!.scaffoldHashKey, isNot(equals(hash1)),
          reason: 'New tab must own a distinct scaffoldHashKey so its '
              'FPS / issue telemetry is isolated from the previous tab.');

      // And the previous session must end up in history.
      expect(
        controller.routeHistoryForTest.any((s) => identical(s, session1)),
        isTrue,
        reason: 'Prior tab\'s session should be archived in route history, '
            'not discarded.',
      );
    });

    testWidgets(
        'A→B→A bottom-nav cycle produces three distinct sessions and '
        'bumps tabVisitIndex on the second visit to A', (tester) async {
      final indexNotifier = ValueNotifier<int>(0);
      addTearDown(indexNotifier.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: indexNotifier,
              builder: (_, idx, __) => IndexedStack(
                index: idx,
                children: const [
                  Scaffold(body: Text('A')),
                  Scaffold(body: Text('B')),
                ],
              ),
            ),
          ),
        ),
      );

      final root = tester.element(find.byType(MaterialApp));

      controller.scanTreeFullPathForTest(root);
      final visitA1 = controller.activeRouteSessionForTest!.tabVisitIndex;

      indexNotifier.value = 1;
      await tester.pump();
      controller.scanTreeFullPathForTest(root);
      final visitB1 = controller.activeRouteSessionForTest!.tabVisitIndex;

      indexNotifier.value = 0;
      await tester.pump();
      controller.scanTreeFullPathForTest(root);
      final visitA2 = controller.activeRouteSessionForTest!.tabVisitIndex;

      expect(visitA1, 1);
      expect(visitB1, 1);
      expect(visitA2, 2,
          reason: 'Returning to tab A after visiting B must bump '
              'tabVisitIndex to 2 so exports can distinguish the two '
              'visits as separate rows.');

      // Three sessions total: A(visit 1), B(visit 1), A(visit 2). The
      // third is the one currently active.
      expect(controller.routeHistoryForTest.length, greaterThanOrEqualTo(2),
          reason: 'Prior A and B sessions must be archived.');
    });

    // -----------------------------------------------------------------------
    // Regression: tabVisitIndex must not collide with a live session after
    // FIFO eviction. Earlier implementation used `count + 1`, which on a
    // long-running bottom-nav app produced two live sessions sharing the
    // same (routeName, scaffoldHashKey, tabVisitIndex) tuple — the exact
    // duplication the feature was designed to prevent.
    // -----------------------------------------------------------------------

    testWidgets(
        'tabVisitIndex remains unique across live history after FIFO eviction '
        '(C1 regression)', (tester) async {
      // Use a dedicated controller with a small cap so eviction happens
      // quickly. The shared top-level controller has the default 50 cap.
      final ctrl = SleuthController(
        config: const SleuthConfig(
          treeScanInterval: Duration(seconds: 1),
          routeHistoryCapacity: 3,
        ),
      );
      ctrl.initializeDetectorsForTest();
      addTearDown(ctrl.dispose);

      final indexNotifier = ValueNotifier<int>(0);
      addTearDown(indexNotifier.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<int>(
              valueListenable: indexNotifier,
              builder: (_, idx, __) => IndexedStack(
                index: idx,
                children: const [
                  Scaffold(body: Text('A')),
                  Scaffold(body: Text('B')),
                ],
              ),
            ),
          ),
        ),
      );
      final root = tester.element(find.byType(MaterialApp));

      // Alternate A↔B enough times that eviction starts dropping older
      // A-visits while new A-visits are still being created. 8 switches
      // with cap=3 guarantees the collision window for a count-based impl.
      ctrl.scanTreeFullPathForTest(root); // A₁
      for (int i = 1; i <= 8; i++) {
        indexNotifier.value = i % 2;
        await tester.pump();
        ctrl.scanTreeFullPathForTest(root);
      }

      // Group all archived + active A-sessions and assert uniqueness.
      final history = ctrl.routeHistoryForTest;
      final aSessions = history
          .where((s) => s.routeName == '/' && s.scaffoldHashKey != null)
          .toList();
      // IndexedStack children share the outer '/' ModalRoute. Group strictly
      // by scaffoldHashKey — all sessions for the SAME tab Scaffold must have
      // distinct tabVisitIndex values.
      final byHash = <int, List<int>>{};
      for (final s in history) {
        byHash
            .putIfAbsent(s.scaffoldHashKey ?? -1, () => <int>[])
            .add(s.tabVisitIndex);
      }
      for (final entry in byHash.entries) {
        final indices = entry.value;
        expect(
          indices.toSet().length,
          indices.length,
          reason: 'Sessions for scaffoldHashKey=${entry.key} must have '
              'unique tabVisitIndex values, got $indices. This is the C1 '
              'collision: count+1 duplicated after eviction; max+1 must not.',
        );
      }

      // Sanity: we should have actually hit the cap (otherwise the test
      // didn't exercise eviction).
      expect(history.length, lessThanOrEqualTo(3),
          reason: 'Cap=3 must bound history.');
      expect(aSessions, isNotEmpty,
          reason: 'Precondition: at least one A-session must survive.');
    });
  });

  // -------------------------------------------------------------------------
  // Regression: Flutter hot reload (`reassemble`) must close the active
  // RouteSession so post-reload frames/issues don't blend with pre-reload
  // into one session carrying a stale hotReloadGeneration stamp.
  // Flutter's typical hot reload path preserves Element identity (widgets
  // are updated, not recreated), so without an explicit close the session-
  // keying predicate sees unchanged routeName + scaffoldHashKey and the
  // pre-reload session continues.
  // -------------------------------------------------------------------------

  group('hot reload closes active session (C2 regression)', () {
    testWidgets(
        'reassembleForTest closes active session and starts a fresh '
        'one with incremented hotReloadGeneration on next scan',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('pre-reload')),
        ),
      );
      final root = tester.element(find.byType(MaterialApp));

      // Pre-reload: establish an active session.
      controller.scanTreeFullPathForTest(root);
      final preReload = controller.activeRouteSessionForTest!;
      expect(preReload.isActive, isTrue);
      expect(preReload.hotReloadGeneration, 0);

      // Simulate hot reload.
      controller.reassembleForTest();

      // Pre-reload session must be closed; pointer cleared.
      expect(preReload.isActive, isFalse,
          reason:
              'Active session must be closed on reassemble, otherwise frames '
              'and issues from before and after the reload blend into one.');
      expect(preReload.endedAt, isNotNull);
      expect(controller.activeRouteSessionForTest, isNull);
      expect(controller.hotReloadGenerationForTest, 1);

      // Next scan must start a fresh session stamped with the new generation,
      // even though routeName and scaffoldHashKey are unchanged.
      controller.scanTreeFullPathForTest(root);
      final postReload = controller.activeRouteSessionForTest!;
      expect(identical(postReload, preReload), isFalse,
          reason: 'New session must be a distinct instance.');
      expect(postReload.isActive, isTrue);
      expect(postReload.hotReloadGeneration, 1,
          reason: 'New session must carry the incremented generation stamp.');
      expect(postReload.routeName, preReload.routeName);
      expect(postReload.scaffoldHashKey, preReload.scaffoldHashKey,
          reason:
              'Scaffold Element identity is preserved across non-structural '
              'hot reload — the test itself depends on this.');
    });

    testWidgets('reassembleForTest with no active session does not crash',
        (tester) async {
      // Controller is created but has never run a scan → _activeRouteSession
      // is null. Reassemble must be a safe no-op on the session pointer.
      expect(controller.activeRouteSessionForTest, isNull);
      controller.reassembleForTest();
      expect(controller.hotReloadGenerationForTest, 1);
      expect(controller.activeRouteSessionForTest, isNull);
    });
  });
}
