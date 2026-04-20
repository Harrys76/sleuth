// Hermetic reproducer for [OpacityDetector].
//
// Cited by `OpacityDetector.validationMetadata.reproducerPath` as the
// single-file evidence supporting the detector's
// `EvidenceTier.reproducerOnly` claim (v0.16.3 per-detector validation
// milestone). Covers the `opacity_zero` stable-id family.
//
// The detector fires in three cases:
//   1. widget is Opacity with opacity == 0.0 (exact)
//   2. widget is AnimatedOpacity settled at 0.0
//      (status is completed or dismissed)
//   3. widget is standalone FadeTransition settled at 0.0 — only when
//      NOT already inside an AnimatedOpacity subtree (AnimatedOpacity
//      internally builds a FadeTransition; counting both double-reports)
//
// Non-zero opacity (0.005, 0.5, 1.0) is ignored — the "fully invisible"
// claim is an exact-zero contract.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/opacity_detector.dart';

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
