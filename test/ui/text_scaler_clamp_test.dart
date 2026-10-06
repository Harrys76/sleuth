import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/text_scale_clamp.dart';

import '../helpers/overlay_harness.dart';

/// Non-linear scaler in the style of Android's: 10 px text doubles, 30 px
/// and larger text grows by 1.2x, sizes between interpolate.
class _StepScaler extends TextScaler {
  const _StepScaler();

  @override
  double scale(double fontSize) {
    if (fontSize <= 10) return fontSize * 2;
    if (fontSize >= 30) return fontSize * 1.2;
    return fontSize * (2 - (fontSize - 10) / 20 * 0.8);
  }

  @override
  double get textScaleFactor => 1.5;

  @override
  bool operator ==(Object other) => other is _StepScaler;

  @override
  int get hashCode => (_StepScaler).hashCode;
}

/// A base whose own clamp must never be called.
class _NoClampScaler extends _StepScaler {
  const _NoClampScaler();

  @override
  TextScaler clamp({
    double minScaleFactor = 0,
    double maxScaleFactor = double.infinity,
  }) => throw StateError('base clamp called');
}

/// A host app above the overlay: the non-linear system scaler, then the
/// app's own `MediaQuery.withClampedTextScaling`.
Widget Function(Widget) _host(
  WidgetTester tester, {
  double min = 0,
  double max = double.infinity,
}) =>
    (overlay) => MediaQuery(
      data: MediaQueryData.fromView(
        tester.view,
      ).copyWith(textScaler: const _StepScaler()),
      child: MediaQuery.withClampedTextScaling(
        minScaleFactor: min,
        maxScaleFactor: max,
        child: overlay,
      ),
    );

Future<SleuthController> _pumpHosted(
  WidgetTester tester, {
  Widget Function(Widget)? host,
  double? textScale,
}) async {
  final controller = await pumpOverlay(
    tester,
    host: host,
    textScale: textScale,
    // No scan replaces the fixture issues during the test.
    config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
  );
  expect(tester.takeException(), isNull, reason: 'trigger');
  controller.issuesNotifier.value = mixedOverlayIssues();
  await openDashboard(tester, controller);
  expect(tester.takeException(), isNull, reason: 'dashboard');
  return controller;
}

TextScaler _cardScaler(WidgetTester tester) =>
    MediaQuery.textScalerOf(tester.element(find.byType(FloatingIssuesCard)));

/// The status row is chrome, clamped again inside the card.
TextScaler _chromeScaler(WidgetTester tester) =>
    MediaQuery.textScalerOf(tester.element(find.text('FRAME')));

void main() {
  group('clampTextScaler', () {
    const base = _StepScaler();

    test('keeps a non-linear base non-linear inside the range', () {
      final overlay = clampTextScaler(base, min: 0.8, max: 2.0);
      expect(overlay.scale(10), 20);
      expect(overlay.scale(30), closeTo(36, 1e-9));
      final chrome = clampTextScaler(base, max: 1.3);
      // 10 px is capped at 1.3x; 30 px stays at its own 1.2x.
      expect(chrome.scale(10), closeTo(13, 1e-9));
      expect(chrome.scale(30), closeTo(36, 1e-9));
      final floor = clampTextScaler(base, min: 1.5);
      expect(floor.scale(30), closeTo(45, 1e-9));
      expect(floor.scale(10), 20);
    });

    test('the default range returns the base', () {
      expect(clampTextScaler(base), same(base));
    });

    test('nested clamps compose like clamping the output twice', () {
      final nested = clampTextScaler(
        clampTextScaler(base, min: 0.8, max: 2.0),
        max: 1.3,
      );
      expect(nested, clampTextScaler(base, min: 0.8, max: 1.3));
      for (final size in [4.0, 10.0, 14.0, 22.0, 30.0, 60.0]) {
        expect(
          nested.scale(size),
          closeTo(clampDouble(base.scale(size), size * 0.8, size * 1.3), 1e-9),
        );
      }
    });

    test('a range below an earlier floor pins to the new maximum', () {
      final scaler = clampTextScaler(clampTextScaler(base, min: 1.5), max: 1.3);
      expect(scaler.scale(10), closeTo(13, 1e-9));
      expect(scaler.scale(30), closeTo(39, 1e-9));
    });

    test('a range above an earlier ceiling pins to the new minimum', () {
      final scaler = clampTextScaler(
        clampTextScaler(base, max: 0.7),
        min: 0.8,
        max: 2.0,
      );
      expect(scaler.scale(10), 8);
      expect(scaler.scale(30), 24);
    });

    test('its own clamp composes instead of asserting', () {
      final chrome = clampTextScaler(base, min: 0.8, max: 1.3);
      final pinned = chrome.clamp(minScaleFactor: 1.5, maxScaleFactor: 3);
      expect(pinned.scale(10), 15);
      expect(chrome.clamp(minScaleFactor: 1.3).scale(30), closeTo(39, 1e-9));
    });

    test('min above max gives a fixed scale of max', () {
      final scaler = clampTextScaler(base, min: 2.5, max: 2.0);
      expect(scaler.scale(10), 20);
      expect(scaler.scale(30), 60);
      expect(scaler, clampTextScaler(const _NoClampScaler(), min: 2, max: 2));
    });

    test('never calls the base clamp', () {
      const noClamp = _NoClampScaler();
      final scaler = clampTextScaler(
        clampTextScaler(noClamp, min: 0.8, max: 2.0),
        min: 1.5,
        max: 1.3,
      );
      expect(scaler.scale(10), 13);
      expect(scaler.clamp(maxScaleFactor: 1.1).scale(10), closeTo(11, 1e-9));
    });

    test('textScaleFactor is the clamped base estimate', () {
      // ignore: deprecated_member_use
      expect(clampTextScaler(base, max: 1.3).textScaleFactor, 1.3);
      // ignore: deprecated_member_use
      expect(clampTextScaler(base, min: 0.8, max: 2).textScaleFactor, 1.5);
    });

    test('equal inputs give equal scalers', () {
      final a = clampTextScaler(base, min: 0.8, max: 2.0);
      final b = clampTextScaler(const _StepScaler(), min: 0.8, max: 2.0);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(clampTextScaler(base, min: 0.8, max: 1.3)));
      expect(
        a,
        isNot(clampTextScaler(const TextScaler.linear(1.5), min: 0.8, max: 2)),
      );
    });
  });

  group('overlay under a host text-scale clamp', () {
    testWidgets('a host maximum below the overlay minimum gives 0.8x', (
      tester,
    ) async {
      await _pumpHosted(tester, host: _host(tester, max: 0.7));
      final card = _cardScaler(tester);
      expect(card.scale(10), 8);
      expect(card.scale(30), 24);
      expect(_chromeScaler(tester).scale(10), 8);
    });

    testWidgets('a host minimum above the overlay maximum gives 2.0x', (
      tester,
    ) async {
      await _pumpHosted(tester, host: _host(tester, min: 2.5));
      final card = _cardScaler(tester);
      expect(card.scale(10), 20);
      expect(card.scale(30), 60);
      expect(_chromeScaler(tester).scale(10), closeTo(13, 1e-9));
    });

    testWidgets('a host minimum above the chrome maximum gives 1.3x chrome', (
      tester,
    ) async {
      final controller = await _pumpHosted(
        tester,
        host: _host(tester, min: 1.5),
      );
      expect(_cardScaler(tester).scale(30), closeTo(45, 1e-9));
      final chrome = _chromeScaler(tester);
      expect(chrome.scale(10), closeTo(13, 1e-9));
      expect(chrome.scale(30), closeTo(39, 1e-9));

      // Pages and the Hidden list carry their own chrome clamps.
      for (final label in ['Encyclopedia', 'Guide']) {
        await tester.tap(find.bySemanticsLabel(label));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull, reason: label);
        await systemBack(tester);
        await tester.pump(const Duration(milliseconds: 600));
      }
      controller.overlayUiState.hide('slow_request');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('1 hidden. Show hidden issues'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull, reason: 'hidden page');
    });

    testWidgets('a non-linear system scale stays non-linear in range', (
      tester,
    ) async {
      await _pumpHosted(tester, host: _host(tester));
      final card = _cardScaler(tester);
      expect(card.scale(10), 20);
      expect(card.scale(30), closeTo(36, 1e-9));
      final chrome = _chromeScaler(tester);
      expect(chrome.scale(10), closeTo(13, 1e-9));
      expect(chrome.scale(30), closeTo(36, 1e-9));
    });

    testWidgets('a 3.0x system scale gives 2.0x content and 1.3x chrome', (
      tester,
    ) async {
      await _pumpHosted(tester, textScale: 3);
      expect(_cardScaler(tester).scale(10), 20);
      expect(_chromeScaler(tester).scale(10), closeTo(13, 1e-9));
    });
  });
}
