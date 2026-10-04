import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';
import 'package:sleuth/src/ui/sleuth_theme.dart';
import 'package:sleuth/src/ui/trigger_button.dart';

import '../helpers/overlay_harness.dart';

SleuthThemeData _overlayTheme(WidgetTester tester) =>
    tester.widget<SleuthTheme>(find.byType(SleuthTheme)).data;

double _scaleAt(WidgetTester tester, Finder finder) =>
    MediaQuery.textScalerOf(tester.element(finder)).scale(10) / 10;

void main() {
  group('Theme auto-detection', () {
    testWidgets('dark brightness resolves to the dark preset', (tester) async {
      await pumpOverlay(tester, platformBrightness: Brightness.dark);
      expect(identical(_overlayTheme(tester), const SleuthThemeData()), isTrue);
    });

    testWidgets('light brightness resolves to the light preset', (
      tester,
    ) async {
      await pumpOverlay(tester, platformBrightness: Brightness.light);
      expect(
        identical(_overlayTheme(tester), const SleuthThemeData.light()),
        isTrue,
      );
    });

    testWidgets('a platform brightness flip re-resolves the theme', (
      tester,
    ) async {
      await pumpOverlay(tester, platformBrightness: Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pump();
      expect(identical(_overlayTheme(tester), const SleuthThemeData()), isTrue);
    });

    testWidgets('high contrast picks the high-contrast preset and back', (
      tester,
    ) async {
      await pumpOverlay(
        tester,
        platformBrightness: Brightness.dark,
        accessibilityFeatures: const FakeAccessibilityFeatures(
          highContrast: true,
        ),
      );
      expect(
        identical(
          _overlayTheme(tester),
          const SleuthThemeData.highContrastDark(),
        ),
        isTrue,
      );

      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pump();
      expect(
        identical(
          _overlayTheme(tester),
          const SleuthThemeData.highContrastLight(),
        ),
        isTrue,
      );

      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures();
      await tester.pump();
      expect(
        identical(_overlayTheme(tester), const SleuthThemeData.light()),
        isTrue,
      );
    });

    testWidgets('the resolved preset keeps its identity across rebuilds', (
      tester,
    ) async {
      final controller = await pumpOverlay(
        tester,
        platformBrightness: Brightness.dark,
      );
      final first = _overlayTheme(tester);
      await openDashboard(tester, controller);
      controller.overlayUiState.dashboardOpen = false;
      await tester.pump();
      expect(identical(_overlayTheme(tester), first), isTrue);
    });
  });

  group('Theme precedence', () {
    final configured = const SleuthThemeData().copyWith(
      pageBackground: const Color(0xFFABCDEF),
    );

    testWidgets('config.theme wins over auto-detection', (tester) async {
      await pumpOverlay(
        tester,
        config: SleuthConfig(theme: configured),
        platformBrightness: Brightness.light,
      );
      expect(identical(_overlayTheme(tester), configured), isTrue);
    });

    testWidgets('themeMode light or dark wins over config.theme; system '
        'restores it', (tester) async {
      final controller = await pumpOverlay(
        tester,
        config: SleuthConfig(theme: configured),
        themeMode: SleuthThemeMode.light,
      );
      expect(
        identical(_overlayTheme(tester), const SleuthThemeData.light()),
        isTrue,
      );
      controller.overlayUiState.themeMode = SleuthThemeMode.dark;
      await tester.pump();
      expect(identical(_overlayTheme(tester), const SleuthThemeData()), isTrue);
      controller.overlayUiState.themeMode = SleuthThemeMode.system;
      await tester.pump();
      expect(identical(_overlayTheme(tester), configured), isTrue);
    });

    testWidgets('themeMode keeps high contrast', (tester) async {
      await pumpOverlay(
        tester,
        themeMode: SleuthThemeMode.light,
        accessibilityFeatures: const FakeAccessibilityFeatures(
          highContrast: true,
        ),
      );
      expect(
        identical(
          _overlayTheme(tester),
          const SleuthThemeData.highContrastLight(),
        ),
        isTrue,
      );
    });

    testWidgets('updateTheme wins over themeMode and config.theme', (
      tester,
    ) async {
      final controller = await pumpOverlay(
        tester,
        config: SleuthConfig(theme: configured),
        themeMode: SleuthThemeMode.light,
      );
      controller.updateTheme(const SleuthThemeData.highContrastDark());
      await tester.pump();
      expect(
        identical(
          _overlayTheme(tester),
          const SleuthThemeData.highContrastDark(),
        ),
        isTrue,
      );
      controller.updateTheme(null);
      await tester.pump();
      expect(
        identical(_overlayTheme(tester), const SleuthThemeData.light()),
        isTrue,
      );
    });

    testWidgets('a themeMode change rebuilds the theme with the dashboard '
        'open', (tester) async {
      final controller = await pumpOverlay(
        tester,
        platformBrightness: Brightness.dark,
      );
      await openDashboard(tester, controller);
      controller.overlayUiState.themeMode = SleuthThemeMode.light;
      await tester.pump();
      expect(
        identical(_overlayTheme(tester), const SleuthThemeData.light()),
        isTrue,
      );
      expect(controller.overlayUiState.dashboardOpen, isTrue);
    });
  });

  group('Text scale clamp', () {
    testWidgets('3.0 reads back as 2.0 in the overlay, 3.0 in the app', (
      tester,
    ) async {
      final controller = await pumpOverlay(tester, textScale: 3);
      expect(_scaleAt(tester, find.byType(TriggerButton)), 2.0);
      expect(_scaleAt(tester, find.text('app')), 3.0);
      await openDashboard(tester, controller);
      expect(_scaleAt(tester, find.byType(FloatingIssuesCard)), 2.0);
      expect(_scaleAt(tester, find.text('app')), 3.0);
    });

    testWidgets('0.85 is kept in the overlay', (tester) async {
      final controller = await pumpOverlay(tester, textScale: 0.85);
      await openDashboard(tester, controller);
      expect(
        _scaleAt(tester, find.byType(FloatingIssuesCard)),
        closeTo(0.85, 1e-9),
      );
    });

    testWidgets('0.5 is raised to 0.8 in the overlay only', (tester) async {
      final controller = await pumpOverlay(tester, textScale: 0.5);
      await openDashboard(tester, controller);
      expect(
        _scaleAt(tester, find.byType(FloatingIssuesCard)),
        closeTo(0.8, 1e-9),
      );
      expect(_scaleAt(tester, find.text('app')), 0.5);
    });
  });

  group('SleuthController.updateTheme', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
    });

    tearDown(() => controller.dispose());

    test('updateTheme sets override value', () {
      expect(controller.themeOverride.value, isNull);
      controller.updateTheme(const SleuthThemeData.light());
      expect(controller.themeOverride.value, isNotNull);
      expect(
        controller.themeOverride.value!.pageBackground,
        const Color(0xFFF9FAFB),
      );
    });

    test('updateTheme(null) reverts to auto-detection', () {
      controller.updateTheme(const SleuthThemeData.light());
      expect(controller.themeOverride.value, isNotNull);
      controller.updateTheme(null);
      expect(controller.themeOverride.value, isNull);
    });

    test('themeOverride notifier fires on update', () {
      int callCount = 0;
      controller.themeOverride.addListener(() => callCount++);

      controller.updateTheme(const SleuthThemeData.light());
      expect(callCount, 1);

      controller.updateTheme(const SleuthThemeData());
      expect(callCount, 2);

      controller.updateTheme(null);
      expect(callCount, 3);
    });
  });
}
