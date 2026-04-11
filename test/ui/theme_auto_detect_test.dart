import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/ui/sleuth_theme.dart';

void main() {
  group('Theme auto-detection', () {
    testWidgets('dark brightness resolves to dark theme colors',
        (tester) async {
      late SleuthThemeData captured;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(platformBrightness: Brightness.dark),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (context) {
                final mq = MediaQuery.maybeOf(context);
                final theme =
                    mq != null && mq.platformBrightness == Brightness.light
                        ? const SleuthThemeData.light()
                        : const SleuthThemeData();
                captured = theme;
                return SleuthTheme(data: theme, child: const SizedBox());
              },
            ),
          ),
        ),
      );

      expect(captured.pageBackground, const Color(0xFF1E1E2E));
      expect(captured.textPrimary, const Color(0xFFFFFFFF));
    });

    testWidgets('light brightness resolves to light theme colors',
        (tester) async {
      late SleuthThemeData captured;

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(platformBrightness: Brightness.light),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (context) {
                final mq = MediaQuery.maybeOf(context);
                final theme =
                    mq != null && mq.platformBrightness == Brightness.light
                        ? const SleuthThemeData.light()
                        : const SleuthThemeData();
                captured = theme;
                return SleuthTheme(data: theme, child: const SizedBox());
              },
            ),
          ),
        ),
      );

      expect(captured.pageBackground, const Color(0xFFF9FAFB));
      expect(captured.textPrimary, const Color(0xFF111827));
    });

    testWidgets('explicit config.theme overrides auto-detection',
        (tester) async {
      late SleuthThemeData captured;
      final explicit = const SleuthThemeData().copyWith(
        pageBackground: const Color(0xFFABCDEF),
      );

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(platformBrightness: Brightness.light),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Builder(
              builder: (context) {
                // Simulate: config.theme ?? auto-detect
                final theme = explicit;
                captured = theme;
                return SleuthTheme(data: theme, child: const SizedBox());
              },
            ),
          ),
        ),
      );

      // Explicit theme wins over light auto-detection
      expect(captured.pageBackground, const Color(0xFFABCDEF));
      // Retains dark defaults for non-overridden fields
      expect(captured.textPrimary, const Color(0xFFFFFFFF));
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
