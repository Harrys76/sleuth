import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';

void main() {
  setUp(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });
  tearDown(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });

  /// Installs a coordinator, runs [drive] and returns one snapshot.
  Future<DebugSnapshot> record(
    WidgetTester tester,
    Future<void> Function() drive, {
    int maxTrackedTypes = 50,
    bool installRebuild = true,
  }) async {
    var now = DateTime(2026);
    final coord = DebugInstrumentationCoordinator(
      maxTrackedTypes: maxTrackedTypes,
      installRebuild: installRebuild,
      clock: () => now,
    );
    coord.install();
    await drive();
    now = now.add(const Duration(seconds: 1));
    final snap = coord.snapshot();
    coord.dispose();
    return snap;
  }

  testWidgets('a parent setState names the parent', (tester) async {
    final parent = GlobalKey<_ParentState<int>>();
    await tester.pumpWidget(_Parent<int>(key: parent));

    // The first rebuild after install is the first time the coordinator
    // sees each element, which it does not count.
    final snap = await record(tester, () async {
      for (var i = 0; i < 4; i++) {
        parent.currentState!.bump();
        await tester.pump();
      }
    });

    expect(snap.rebuildCounts, {'_Parent<int>': 3});
    expect(snap.forcedRebuildsOf, {
      '_Leaf': {'_Parent<int>': 3},
    });
    // The existing per-root count is unchanged.
    expect(snap.forcedRebuildsByRoot, {'_Parent<int>': 3});
    expect(snap.forcedTypesCapped, isFalse);
  }, semanticsEnabled: false);

  testWidgets('a framework root is named but not counted as a rebuild', (
    tester,
  ) async {
    // The overlay creates the entry's widget, so it is a framework widget
    // that marks itself dirty and rebuilds the app's builder output.
    var n = 0;
    final entry = OverlayEntry(builder: (_) => _Leaf(n));
    addTearDown(
      () => entry
        ..remove()
        ..dispose(),
    );
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Overlay(initialEntries: [entry]),
      ),
    );

    final snap = await record(tester, () async {
      for (var i = 0; i < 3; i++) {
        n++;
        entry.markNeedsBuild();
        await tester.pump();
      }
    });

    expect(snap.rebuildCounts, isEmpty);
    expect(snap.forcedRebuildsByRoot, isEmpty);
    expect(snap.forcedRebuildsOf, {
      '_Leaf': {'_OverlayEntryWidget': 2},
    });
  }, semanticsEnabled: false);

  testWidgets('the forced-type cap sets the flag', (tester) async {
    final parent = GlobalKey<_TwoLeavesState>();
    await tester.pumpWidget(_TwoLeaves(key: parent));

    final snap = await record(tester, () async {
      for (var i = 0; i < 2; i++) {
        parent.currentState!.bump();
        await tester.pump();
      }
    }, maxTrackedTypes: 1);

    expect(snap.forcedRebuildsOf.keys, hasLength(1));
    expect(snap.forcedTypesCapped, isTrue);
  }, semanticsEnabled: false);

  testWidgets('at most 8 forcing types are kept for one forced type', (
    tester,
  ) async {
    final keys = <GlobalKey<_ParentState<Object?>>>[];
    final parents = <Widget>[];
    void add<T>() {
      final key = GlobalKey<_ParentState<T>>();
      keys.add(key as GlobalKey<_ParentState<Object?>>);
      parents.add(_Parent<T>(key: key));
    }

    add<int>();
    add<double>();
    add<String>();
    add<bool>();
    add<num>();
    add<Object>();
    add<List<int>>();
    add<Set<int>>();
    add<Map<int, int>>();
    await tester.pumpWidget(Column(children: parents));

    final snap = await record(tester, () async {
      for (var i = 0; i < 2; i++) {
        for (final key in keys) {
          key.currentState!.bump();
        }
        await tester.pump();
      }
    });

    expect(snap.forcedRebuildsOf['_Leaf'], hasLength(8));
    expect(snap.forcedTypesCapped, isTrue);
  }, semanticsEnabled: false);

  testWidgets('nothing is recorded without the rebuild hook', (tester) async {
    final parent = GlobalKey<_ParentState<int>>();
    await tester.pumpWidget(_Parent<int>(key: parent));

    final snap = await record(tester, () async {
      for (var i = 0; i < 2; i++) {
        parent.currentState!.bump();
        await tester.pump();
      }
    }, installRebuild: false);

    expect(snap.forcedRebuildsOf, isEmpty);
    expect(snap.forcedTypesCapped, isFalse);
  }, semanticsEnabled: false);
}

class _Parent<T> extends StatefulWidget {
  const _Parent({super.key});

  @override
  State<_Parent<T>> createState() => _ParentState<T>();
}

class _ParentState<T> extends State<_Parent<T>> {
  int _n = 0;

  void bump() => setState(() => _n++);

  @override
  Widget build(BuildContext context) => _Leaf(_n);
}

class _TwoLeaves extends StatefulWidget {
  const _TwoLeaves({super.key});

  @override
  State<_TwoLeaves> createState() => _TwoLeavesState();
}

class _TwoLeavesState extends State<_TwoLeaves> {
  int _n = 0;

  void bump() => setState(() => _n++);

  @override
  Widget build(BuildContext context) =>
      Column(children: [_Leaf(_n), _OtherLeaf(_n)]);
}

class _Leaf extends StatelessWidget {
  const _Leaf(this.n);

  final int n;

  @override
  Widget build(BuildContext context) => SizedBox(width: n.toDouble());
}

class _OtherLeaf extends StatelessWidget {
  const _OtherLeaf(this.n);

  final int n;

  @override
  Widget build(BuildContext context) => SizedBox(height: n.toDouble());
}
