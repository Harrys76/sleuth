import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/rebuild_detector.dart';
import 'package:sleuth/src/models/base_detector.dart';

/// Returns [next] from each drain (a fresh 1 s debug-callback window with
/// `_Tile` rebuilding 40 times unless changed).
class _FakeCoordinator extends DebugInstrumentationCoordinator {
  _FakeCoordinator() : super(installRebuild: false, installPaint: false);

  DebugSnapshot next = busy;
  int discards = 0;

  static const busy = DebugSnapshot(
    rebuildCounts: {'_Tile': 40},
    totalPaintCount: 0,
    elapsed: Duration(seconds: 1),
    source: RebuildCountSource.debugCallback,
  );

  @override
  DebugSnapshot snapshot() => next;

  @override
  void discardWindow() => discards++;
}

Widget _app({Set<String> twoPanes = const {}}) => MaterialApp(
  initialRoute: '/a',
  onGenerateRoute: (settings) => MaterialPageRoute<void>(
    settings: settings,
    builder: (_) => twoPanes.contains(settings.name)
        ? const Row(
            children: [
              Expanded(child: Scaffold()),
              Expanded(child: Scaffold()),
            ],
          )
        : Scaffold(key: ValueKey(settings.name)),
  ),
);

void main() {
  late SleuthController controller;
  late _FakeCoordinator fake;

  void setUpController({Set<String> ignore = const {}}) {
    controller = SleuthController(
      config: SleuthConfig(
        treeScanInterval: const Duration(seconds: 1),
        enabledDetectors: const {DetectorType.rebuild},
        routeIgnorePatterns: ignore,
      ),
    );
    controller.initializeDetectorsForTest();
    fake = _FakeCoordinator();
    controller.debugCoordinatorForTest = fake;
  }

  tearDown(() {
    controller.debugCoordinatorForTest = null;
    controller.dispose();
  });

  List<String> rebuildIds() => [
    for (final i
        in controller.detectorsForAudit
            .whereType<RebuildDetector>()
            .single
            .issues)
      i.stableId!,
  ];

  void scan(WidgetTester tester) => controller.scanTreeFullPathForTest(
    tester.element(find.byType(MaterialApp)),
  );

  testWidgets('the first scan on a screen does not use its counts, the next '
      'one does', (tester) async {
    setUpController();
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    scan(tester);
    expect(rebuildIds(), isEmpty);
    scan(tester);
    expect(rebuildIds(), ['rebuild_debug__Tile']);
  });

  testWidgets('a route change drops held cards and the window that spans '
      'it', (tester) async {
    setUpController();
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    scan(tester);
    scan(tester);
    expect(rebuildIds(), ['rebuild_debug__Tile']);

    tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/b');
    await tester.pumpAndSettle();
    scan(tester);
    expect(rebuildIds(), isEmpty);
    scan(tester);
    expect(rebuildIds(), ['rebuild_debug__Tile']);
  });

  testWidgets('an ignored route still keeps its evidence between scans', (
    tester,
  ) async {
    setUpController(ignore: {'/a'});
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    scan(tester);
    scan(tester);
    expect(rebuildIds(), ['rebuild_debug__Tile']);
  });

  testWidgets('a hot reload discards the reload frame and the next window', (
    tester,
  ) async {
    setUpController();
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    scan(tester);
    scan(tester);
    expect(rebuildIds(), ['rebuild_debug__Tile']);

    controller.notifyReassemble();
    // A reload schedules its frame; the reload frame's counts go.
    tester.binding.scheduleFrame();
    await tester.pump();
    expect(fake.discards, 1);
    scan(tester);
    expect(rebuildIds(), isEmpty);
  });

  testWidgets('scans that cannot find one page drop the held cards', (
    tester,
  ) async {
    setUpController();
    await tester.pumpWidget(_app(twoPanes: {'/b'}));
    await tester.pumpAndSettle();
    scan(tester);
    scan(tester);
    expect(rebuildIds(), ['rebuild_debug__Tile']);

    tester.state<NavigatorState>(find.byType(Navigator)).pushNamed('/b');
    await tester.pumpAndSettle();
    scan(tester);
    expect(rebuildIds(), isEmpty);
  });
}
