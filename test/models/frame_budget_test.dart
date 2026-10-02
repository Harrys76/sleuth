import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

void main() {
  FrameBudget resolve({
    int fpsTarget = 60,
    double display = 0,
    double? measured,
    bool auto = true,
  }) => resolveFrameBudget(
    fpsTarget: fpsTarget,
    displayRefreshRateHz: display,
    measuredCadenceHz: measured,
    auto: auto,
  );

  group('resolveFrameBudget pinned cases', () {
    test('ProMotion display rendering at 60 keeps the 60 Hz budget', () {
      final b = resolve(display: 120, measured: 60);
      expect(b.budgetUs, 16667);
      expect(b.source, FrameRateSource.measured);
    });

    test('display rate alone does not tighten the budget', () {
      final b = resolve(display: 120);
      expect(b.budgetUs, 16667);
      expect(b.source, FrameRateSource.fixed);
    });

    test('slow cadence clamps up to fpsTarget', () {
      final b = resolve(display: 60, measured: 30);
      expect(b.budgetUs, 16667);
      expect(b.source, FrameRateSource.fixed);
    });

    test('120 Hz cadence on a 120 Hz display tightens to 8333', () {
      final b = resolve(display: 120, measured: 120);
      expect(b.budgetUs, 8333);
      expect(b.effectiveHz, 120);
      expect(b.source, FrameRateSource.measured);
    });

    test('no display, no measurement -> fixed fpsTarget', () {
      final b = resolve();
      expect(b.budgetUs, 16667);
      expect(b.source, FrameRateSource.fixed);
    });

    test('measured above the display rate clamps to the display', () {
      final b = resolve(display: 60, measured: 120);
      expect(b.budgetUs, 16667);
      expect(b.source, FrameRateSource.display);
    });

    test('measured with unknown display caps at fpsTarget', () {
      final b = resolve(measured: 120);
      expect(b.budgetUs, 16667);
      expect(b.source, FrameRateSource.fixed);
    });

    test('59.7 Hz snaps to 60', () {
      final b = resolve(display: 120, measured: 59.7);
      expect(b.effectiveHz, 60);
      expect(b.budgetUs, 16667);
    });

    test('90 Hz -> 11111', () {
      final b = resolve(display: 120, measured: 90);
      expect(b.budgetUs, 11111);
      expect(b.source, FrameRateSource.measured);
    });

    test('off-grid cadence is used raw', () {
      final b = resolve(display: 120, measured: 75);
      expect(b.effectiveHz, 75);
      expect(b.budgetUs, 13333);
    });

    test('non-finite or non-positive inputs are treated as unknown', () {
      expect(resolve(display: double.nan, measured: 120).budgetUs, 16667);
      expect(resolve(display: 120, measured: double.nan).budgetUs, 16667);
      expect(resolve(display: 120, measured: -5).budgetUs, 16667);
      expect(resolve(display: double.infinity, measured: 120).budgetUs, 16667);
    });
  });

  group('resolveFrameBudget table', () {
    const displays = <double>[0, 60, 120];
    const measures = <double?>[null, 30, 59.7, 60, 120];
    const targets = <int>[60, 120];

    for (final auto in [true, false]) {
      for (final display in displays) {
        for (final measured in measures) {
          for (final target in targets) {
            test('auto=$auto display=$display measured=$measured '
                'fpsTarget=$target', () {
              final b = resolve(
                fpsTarget: target,
                display: display,
                measured: measured,
                auto: auto,
              );
              if (!auto) {
                expect(b.budgetUs, (1e6 / target).round());
                expect(b.source, FrameRateSource.fixed);
                return;
              }
              // Never looser than fpsTarget.
              expect(b.effectiveHz, greaterThanOrEqualTo(target));
              // Never tighter than the display (or fpsTarget when unknown).
              final cap = display > 0 && display > target ? display : target;
              expect(b.effectiveHz, lessThanOrEqualTo(cap));
              expect(b.budgetUs, (1e6 / b.effectiveHz).round());
              if (measured == null) {
                expect(b.effectiveHz, target);
                expect(b.source, FrameRateSource.fixed);
              }
              if (b.source == FrameRateSource.measured) {
                expect(measured, isNotNull);
              }
            });
          }
        }
      }
    }

    test('expected budgets', () {
      // (fpsTarget, display, measured) -> budgetUs
      final cases = <(int, double, double?), int>{
        (60, 0, null): 16667,
        (60, 0, 120): 16667,
        (60, 60, 30): 16667,
        (60, 60, 120): 16667,
        (60, 120, null): 16667,
        (60, 120, 30): 16667,
        (60, 120, 59.7): 16667,
        (60, 120, 60): 16667,
        (60, 120, 120): 8333,
        (120, 0, null): 8333,
        (120, 60, 60): 8333,
        (120, 120, 60): 8333,
        (120, 120, 120): 8333,
      };
      cases.forEach((key, expected) {
        final (target, display, measured) = key;
        expect(
          resolve(
            fpsTarget: target,
            display: display,
            measured: measured,
          ).budgetUs,
          expected,
          reason: '$key',
        );
      });
    });
  });

  test('FrameBudget value equality', () {
    const a = FrameBudget(
      budgetUs: 8333,
      effectiveHz: 120,
      source: FrameRateSource.measured,
    );
    const b = FrameBudget(
      budgetUs: 8333,
      effectiveHz: 120,
      source: FrameRateSource.measured,
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
  });
}
