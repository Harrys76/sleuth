import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/custom_painter_detector.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';

void main() {
  setUp(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });
  tearDown(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });

  /// Pumps [app], then records [frames] frames 16 ms apart, calling
  /// [tick] before each, and returns the coordinator's snapshot over a
  /// one-second window.
  Future<DebugSnapshot> record(
    WidgetTester tester,
    Widget app, {
    required void Function(int frame) tick,
    int frames = 60,
    bool userWidgetsOnly = true,
  }) async {
    await tester.pumpWidget(
      Directionality(textDirection: TextDirection.ltr, child: app),
    );
    await tester.pump(const Duration(milliseconds: 16));
    var now = DateTime(2026);
    final coord = DebugInstrumentationCoordinator(
      userWidgetsOnly: userWidgetsOnly,
      clock: () => now,
    );
    coord.install();
    for (var i = 0; i < frames; i++) {
      tick(i);
      await tester.pump(const Duration(milliseconds: 16));
    }
    now = now.add(const Duration(seconds: 1));
    final snap = coord.snapshot();
    // The binding checks the paint hook is unset before tear-down runs.
    coord.dispose();
    return snap;
  }

  /// The per-widget repaint cards a [RepaintDetector] reports for [snap].
  List<String> repaintCards(DebugSnapshot snap) {
    final detector = RepaintDetector()..updateDebugSnapshot(snap);
    detector.evaluateNow();
    return [
      for (final issue in detector.issues)
        if (issue.stableId!.startsWith('repaint_debug_')) issue.stableId!,
    ];
  }

  testWidgets('one ticking painter is the only origin in its layer', (
    tester,
  ) async {
    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);
    final snap = await record(
      tester,
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(4),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CustomPaint(painter: _TickPainter(notifier)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.all(4),
              child: ColoredBox(
                color: Color(0xFF00FF00),
                child: SizedBox(width: 20, height: 20),
              ),
            ),
          ],
        ),
      ),
      tick: (_) => notifier.value++,
    );

    // Every widget in the layer paints each frame.
    for (final type in [
      'Center',
      'Column',
      'Padding',
      'SizedBox',
      'ColoredBox',
      'CustomPaint',
    ]) {
      expect(snap.paintCounts[type], greaterThanOrEqualTo(60), reason: type);
    }
    // Only the painter started the repaint.
    expect(snap.paintOrigins.keys, ['CustomPaint']);
    final origins = snap.paintOrigins['CustomPaint']!;
    expect(origins.maxCount, 60);
    expect(origins.instanceCount, 1);
    expect(origins.busiest.single.element, same(_elementOf<CustomPaint>()));
    expect(origins.ancestorChain, contains('CustomPaint'));

    expect(repaintCards(snap), ['repaint_debug_CustomPaint']);
  }, semanticsEnabled: false);

  testWidgets('a sibling wrapped in a RepaintBoundary is not an origin', (
    tester,
  ) async {
    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);
    final snap = await record(
      tester,
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CustomPaint(painter: _TickPainter(notifier)),
            ),
            const RepaintBoundary(
              child: Padding(
                padding: EdgeInsets.all(4),
                child: SizedBox(width: 20, height: 20),
              ),
            ),
          ],
        ),
      ),
      tick: (_) => notifier.value++,
    );

    // The reused boundary is still visited every frame; its contents
    // are not.
    expect(snap.paintCounts['RepaintBoundary'], greaterThanOrEqualTo(60));
    expect(snap.paintCounts['Padding'], isNull);
    expect(snap.paintOrigins.keys, ['CustomPaint']);
    expect(repaintCards(snap), ['repaint_debug_CustomPaint']);
  }, semanticsEnabled: false);

  testWidgets('a RepaintBoundary around the origin is not an origin', (
    tester,
  ) async {
    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);
    final snap = await record(
      tester,
      Center(
        child: RepaintBoundary(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CustomPaint(painter: _TickPainter(notifier)),
          ),
        ),
      ),
      tick: (_) => notifier.value++,
    );

    expect(snap.paintOrigins.keys, ['CustomPaint']);
    expect(snap.paintOrigins['CustomPaint']!.maxCount, 60);
  }, semanticsEnabled: false);

  testWidgets('a ticking Text is credited to the nearest widget the app '
      'created', (tester) async {
    final snap = await record(
      tester,
      const Center(child: _Clock()),
      tick: (_) {},
    );

    // The RenderParagraph belongs to the framework's RichText; the Text
    // the app wrote is the nearest widget it created.
    expect(snap.paintCounts.containsKey('Text'), isFalse);
    expect(snap.paintOrigins.keys, ['Text']);
    expect(snap.paintOrigins['Text']!.maxCount, greaterThanOrEqualTo(59));
    expect(repaintCards(snap), ['repaint_debug_Text']);
  }, semanticsEnabled: false);

  testWidgets('a static painter beside a ticking Text is not blamed for '
      'repainting', (tester) async {
    final snap = await record(
      tester,
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(size: const Size(20, 20), painter: _StaticPainter()),
            const _Clock(),
          ],
        ),
      ),
      tick: (_) {},
    );

    // The painter paints with the layer every frame but never starts a
    // repaint, so shouldRepaint is not in question.
    expect(snap.paintCounts['CustomPaint'], greaterThanOrEqualTo(59));
    expect(snap.paintOrigins.keys, ['Text']);
    final painters = CustomPainterDetector()..updateDebugSnapshot(snap);
    painters.scanTree(tester.element(find.byType(Directionality)));
    expect(painters.issues, isEmpty);
  }, semanticsEnabled: false);

  testWidgets('with userWidgetsOnly off the framework widget is credited', (
    tester,
  ) async {
    final snap = await record(
      tester,
      const Center(child: _Clock()),
      tick: (_) {},
      userWidgetsOnly: false,
    );

    expect(snap.paintOrigins.keys, ['RichText']);
  }, semanticsEnabled: false);

  testWidgets('forty instances at 10 Hz each stay below the threshold', (
    tester,
  ) async {
    final notifiers = [for (var i = 0; i < 40; i++) ValueNotifier<int>(0)];
    addTearDown(() {
      for (final n in notifiers) {
        n.dispose();
      }
    });
    final snap = await record(
      tester,
      Wrap(
        children: [
          for (final n in notifiers)
            Padding(
              padding: const EdgeInsets.all(1),
              child: SizedBox(
                width: 5,
                height: 5,
                child: CustomPaint(painter: _TickPainter(n)),
              ),
            ),
        ],
      ),
      // Every sixth frame: 10 repaints per instance over the second.
      tick: (frame) {
        if (frame % 6 == 0) {
          for (final n in notifiers) {
            n.value++;
          }
        }
      },
    );

    // Participation sums to 400 a second per type.
    expect(snap.paintCounts['Padding'], 400);
    final origins = snap.paintOrigins['CustomPaint']!;
    expect(origins.maxCount, 10);
    expect(origins.instanceCount, 40);
    expect(origins.busiest, hasLength(PaintOriginStats.maxBusiest));
    expect(snap.paintOrigins.keys, ['CustomPaint']);
    expect(repaintCards(snap), isEmpty);
  }, semanticsEnabled: false);

  testWidgets('a repaint boundary that marks itself with clean children is '
      'its own origin', (tester) async {
    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);
    final snap = await record(
      tester,
      Center(
        child: _SelfDirtying(
          notifier: notifier,
          child: const ColoredBox(
            color: Color(0xFF0000FF),
            child: SizedBox(width: 20, height: 20),
          ),
        ),
      ),
      tick: (_) => notifier.value++,
    );

    // Flutter paints the boundary from flushPaint with no hook call of
    // its own; its children paint clean.
    expect(snap.paintCounts['_SelfDirtying'], isNull);
    expect(snap.paintCounts['ColoredBox'], greaterThanOrEqualTo(60));
    expect(snap.paintOrigins.keys, ['_SelfDirtying']);
    expect(snap.paintOrigins['_SelfDirtying']!.maxCount, 60);
  }, semanticsEnabled: false);

  testWidgets('scrolling credits neither the scroll view nor content that '
      'follows the scroll', (tester) async {
    debugOnProfilePaint = null;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              const SliverAppBar(
                expandedHeight: 200,
                pinned: true,
                flexibleSpace: FlexibleSpaceBar(title: Text('Title')),
              ),
              SliverList.builder(
                itemCount: 500,
                itemBuilder: (_, i) =>
                    SizedBox(height: 40, child: Text('row $i')),
              ),
            ],
          ),
        ),
      ),
    );
    final coord = DebugInstrumentationCoordinator();
    coord.install();
    final gesture = await tester.startGesture(const Offset(400, 400));
    for (var i = 0; i < 60; i++) {
      await gesture.moveBy(const Offset(0, -3));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    final snap = coord.snapshot();
    coord.dispose();
    await tester.pumpAndSettle();

    // The app bar collapses and the list moves every frame.
    expect(snap.totalPaintCount, greaterThan(60));
    expect(snap.paintOrigins, isEmpty);
  }, semanticsEnabled: false);

  testWidgets('an animation owner driving the origin leaves it out', (
    tester,
  ) async {
    final snap = await record(
      tester,
      const Center(
        child: SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(),
        ),
      ),
      tick: (_) {},
    );

    expect(snap.paintOrigins, isEmpty);
  }, semanticsEnabled: false);

  testWidgets('frames pumped with the same time stamp still count once '
      'each', (tester) async {
    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CustomPaint(painter: _TickPainter(notifier)),
          ),
        ),
      ),
    );
    final coord = DebugInstrumentationCoordinator();
    coord.install();
    for (var i = 0; i < 5; i++) {
      notifier.value++;
      await tester.pump();
    }
    final snap = coord.snapshot();
    coord.dispose();
    expect(snap.paintOrigins['CustomPaint']!.maxCount, 5);
  }, semanticsEnabled: false);

  testWidgets('a discarded window drops the open frame', (tester) async {
    final notifier = ValueNotifier<int>(0);
    addTearDown(notifier.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CustomPaint(painter: _TickPainter(notifier)),
          ),
        ),
      ),
    );
    final coord = DebugInstrumentationCoordinator();
    coord.install();
    final ro = tester.renderObject(find.byType(CustomPaint));
    ro.markNeedsPaint();
    debugOnProfilePaint!(ro);
    coord.discardWindow();
    final snap = coord.snapshot();
    coord.dispose();
    await tester.pump();
    expect(snap.paintOrigins, isEmpty);
  }, semanticsEnabled: false);

  testWidgets(
    'a nested boundary repainted first does not make the ancestors it '
    'relaid out into origins',
    (tester) async {
      final notifier = ValueNotifier<int>(0);
      addTearDown(notifier.dispose);
      final snap = await record(
        tester,
        MaterialApp(
          home: Column(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Row(
                    children: [RepaintBoundary(child: _CountText(notifier))],
                  ),
                ),
              ),
            ],
          ),
        ),
        // A new value every frame relays out the text and, through it,
        // the scroll view above the boundary. `flushPaint` repaints the
        // boundary's layer before the scroll view's.
        tick: (i) => notifier.value = i * 7919,
      );
      expect(snap.paintOrigins.keys, ['Text']);
    },
  );
}

Element _elementOf<T extends Widget>() => find.byType(T).evaluate().single;

class _TickPainter extends CustomPainter {
  _TickPainter(Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint());
  }

  @override
  bool shouldRepaint(_TickPainter oldDelegate) => false;
}

class _StaticPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint());
  }

  @override
  bool shouldRepaint(_StaticPainter oldDelegate) => false;
}

/// Rebuilds every frame with a new count in a [Text].
class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _count = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(() => _count++))..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text('$_count');
}

/// A repaint boundary that marks itself as needing paint whenever
/// [notifier] changes, leaving its child clean.
class _SelfDirtying extends SingleChildRenderObjectWidget {
  const _SelfDirtying({required this.notifier, super.child});

  final Listenable notifier;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSelfDirtying(notifier);
}

class _RenderSelfDirtying extends RenderProxyBox {
  _RenderSelfDirtying(this.notifier);

  final Listenable notifier;

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    notifier.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    notifier.removeListener(markNeedsPaint);
    super.detach();
  }
}

/// Shows [notifier]'s value through its own `setState`, so no animation
/// owner sits above the text it repaints.
class _CountText extends StatefulWidget {
  const _CountText(this.notifier);

  final ValueNotifier<int> notifier;

  @override
  State<_CountText> createState() => _CountTextState();
}

class _CountTextState extends State<_CountText> {
  @override
  void initState() {
    super.initState();
    widget.notifier.addListener(_changed);
  }

  @override
  void dispose() {
    widget.notifier.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) => Text('${widget.notifier.value}');
}
