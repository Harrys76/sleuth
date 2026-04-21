// Hermetic reproducer for [OpacityDetector].
//
// Cited by `OpacityDetector.validationMetadata.reproducerPath` as the
// single-file evidence supporting the detector's
// `EvidenceTier.reproducerOnly` claim (v0.16.3 per-detector validation
// milestone). Covers the `opacity_zero` stable-id family.
//
// The detector fires in three cases, all exercised below:
//   1. widget is Opacity with opacity == 0.0 (exact)
//   2. widget is AnimatedOpacity settled at 0.0
//      (status is completed or dismissed)
//   3. widget is standalone FadeTransition settled at 0.0 — only when
//      NOT already inside an AnimatedOpacity subtree (AnimatedOpacity
//      internally builds a FadeTransition; counting both double-reports).
//      Tested with a bare `FadeTransition` driven by an
//      `AnimationController(duration: Duration.zero)..value = 0.0` so the
//      `AnimationStatus` lands at `dismissed`/`completed`.
//
// Non-zero opacity (0.005, 0.5, 1.0) is ignored — the "fully invisible"
// claim is an exact-zero contract.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/opacity_detector.dart';

// Minimal host that mounts a bare `FadeTransition` driven by an
// `AnimationController(duration: Duration.zero)`. Setting `..value =
// opacity` lands `AnimationStatus.dismissed` (for 0.0) or `.completed`
// (for 1.0) on the first tick, which is what
// `OpacityDetector._checkSettledAtZero` gates on. For intermediate
// values the status stays `dismissed` but the opacity value blocks the
// exact-zero check.
class _FadeTransitionHost extends StatefulWidget {
  const _FadeTransitionHost({required this.opacity});
  final double opacity;

  @override
  State<_FadeTransitionHost> createState() => _FadeTransitionHostState();
}

class _FadeTransitionHostState extends State<_FadeTransitionHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: Duration.zero)
      ..value = widget.opacity;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: const SizedBox(width: 10, height: 10),
    );
  }
}

void main() {
  group('OpacityDetector reproducer — opacity_zero threshold', () {
    late OpacityDetector detector;

    setUp(() {
      detector = OpacityDetector();
    });

    tearDown(() => detector.dispose());

    testWidgets('Opacity(0.0) fires opacity_zero', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(opacity: 0.0, child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues =
          detector.issues.where((i) => i.stableId == 'opacity_zero').toList();
      expect(issues, hasLength(1));
      expect(issues.single.title, contains('1'));
    });

    testWidgets('Opacity(0.5) does NOT fire', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(opacity: 0.5, child: SizedBox(width: 10, height: 10)),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where((i) => i.stableId == 'opacity_zero'),
        isEmpty,
        reason: 'only exact 0.0 is considered "fully invisible".',
      );
    });

    testWidgets('Opacity(0.005) does NOT fire (near-zero is not zero)', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(
            opacity: 0.005,
            child: SizedBox(width: 10, height: 10),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where((i) => i.stableId == 'opacity_zero'),
        isEmpty,
        reason: '0.005 is technically visible — detector contract is exact '
            '0.0 match (v9.1). Rounding near-zero to zero would flag '
            'intentional barely-visible effects.',
      );
    });

    testWidgets(
        'AnimatedOpacity(0.0) settled at 0.0 fires opacity_zero '
        'exactly once (inner FadeTransition suppressed)', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: AnimatedOpacity(
            opacity: 0.0,
            duration: Duration.zero,
            child: SizedBox(width: 10, height: 10),
          ),
        ),
      );
      // Let AnimatedOpacity settle to `completed`/`dismissed`. With
      // `Duration.zero`, one extra pump is enough for the animation
      // controller's status to land.
      await tester.pump();
      await tester.pump();

      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues =
          detector.issues.where((i) => i.stableId == 'opacity_zero').toList();
      expect(issues, hasLength(1),
          reason: 'AnimatedOpacity internally builds a FadeTransition; '
              'the detector must NOT double-count them. '
              '_insideAnimatedOpacity depth counter is the suppression.');
      expect(issues.single.title, contains('1'));
    });

    testWidgets(
        'bare FadeTransition settled at 0.0 fires opacity_zero '
        '(standalone — not inside AnimatedOpacity)', (tester) async {
      // Opacity detector line 84 handles `FadeTransition &&
      // _insideAnimatedOpacity == 0` as a standalone flag-zero emission.
      // Without this explicit test, a regression inverting the guard
      // (`== 0` → `> 0`), deleting the branch, or breaking the
      // AnimationStatus check would stop detecting a real pathology
      // while the AnimatedOpacity-inner-FadeTransition assertion still
      // passed.
      final host = _FadeTransitionHost(opacity: 0.0);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: host,
        ),
      );
      // One pump is enough — `AnimationController(duration: Duration.zero)`
      // + `..value = 0.0` lands the status at `dismissed` immediately.
      await tester.pump();

      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues =
          detector.issues.where((i) => i.stableId == 'opacity_zero').toList();
      expect(issues, hasLength(1),
          reason: 'bare FadeTransition at opacity 0.0 must fire — the '
              '`_insideAnimatedOpacity == 0` guard is the gate, and '
              'nothing is suppressing it here.');
    });

    testWidgets('bare FadeTransition at non-zero does NOT fire', (
      tester,
    ) async {
      final host = _FadeTransitionHost(opacity: 0.5);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: host,
        ),
      );
      await tester.pump();

      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(
        detector.issues.where((i) => i.stableId == 'opacity_zero'),
        isEmpty,
        reason: 'FadeTransition only fires at exact 0.0 with settled status.',
      );
    });

    testWidgets(
        'Opacity(0.0) nested inside Opacity(0.0) fires ONE rollup issue with '
        'count=2', (
      tester,
    ) async {
      // Both static Opacity widgets count independently — the depth
      // counter only suppresses FadeTransition inside AnimatedOpacity.
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(
            opacity: 0.0,
            child: Opacity(
              opacity: 0.0,
              child: SizedBox(width: 10, height: 10),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issues =
          detector.issues.where((i) => i.stableId == 'opacity_zero').toList();
      expect(issues, hasLength(1), reason: 'one rollup issue emitted');
      expect(
        issues.single.title,
        contains('2'),
        reason: 'but rollup title reflects both nested occurrences.',
      );
    });
  });
}
