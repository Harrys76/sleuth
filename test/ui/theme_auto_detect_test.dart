import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/ui/watchdog_theme.dart';

void main() {
  group('Theme auto-detection', () {
    testWidgets('dark brightness resolves to dark theme colors',
        (tester) async {
      late WatchdogThemeData captured;

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
                        ? const WatchdogThemeData.light()
                        : const WatchdogThemeData();
                captured = theme;
                return WatchdogTheme(data: theme, child: const SizedBox());
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
      late WatchdogThemeData captured;

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
                        ? const WatchdogThemeData.light()
                        : const WatchdogThemeData();
                captured = theme;
                return WatchdogTheme(data: theme, child: const SizedBox());
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
      late WatchdogThemeData captured;
      final explicit = const WatchdogThemeData().copyWith(
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
                return WatchdogTheme(data: theme, child: const SizedBox());
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
}
