import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';
import 'package:widget_watchdog/src/ui/watchdog_theme.dart';

void main() {
  group('WatchdogThemeData', () {
    test('dark defaults match documented hex values', () {
      const t = WatchdogThemeData();
      // Severity
      expect(t.severityCritical, const Color(0xFFEF4444));
      expect(t.severityWarning, const Color(0xFFF59E0B));
      expect(t.severityOk, const Color(0xFF10B981));
      // Surfaces
      expect(t.pageBackground, const Color(0xFF1E1E2E));
      expect(t.sectionBackground, const Color(0xFF252536));
      expect(t.cardBackground, const Color(0xF51E1E2E));
      expect(t.border, const Color(0xFF374151));
      // Text hierarchy
      expect(t.textPrimary, const Color(0xFFFFFFFF));
      expect(t.textSecondary, const Color(0xFFD1D5DB));
      expect(t.textTertiary, const Color(0xFF9CA3AF));
      expect(t.textQuaternary, const Color(0xFF6B7280));
      expect(t.textSubtle, const Color(0xFF4B5563));
      // Category
      expect(t.categoryBuild, const Color(0xFF3B82F6));
      expect(t.categoryNetwork, const Color(0xFFF97316));
      // Special
      expect(t.guideStepAccent, const Color(0xFF3B82F6));
      expect(t.guideTipIcon, const Color(0xFFF59E0B));
    });

    test('dark() is identical to default constructor', () {
      const def = WatchdogThemeData();
      const dark = WatchdogThemeData.dark();
      expect(identical(def, dark), isTrue);
    });

    test('light() returns distinct surface/text values', () {
      const dark = WatchdogThemeData();
      const light = WatchdogThemeData.light();
      expect(light.pageBackground, isNot(dark.pageBackground));
      expect(light.textPrimary, isNot(dark.textPrimary));
      expect(light.sectionBackground, isNot(dark.sectionBackground));
      expect(light.cardBackground, isNot(dark.cardBackground));
      expect(light.border, isNot(dark.border));
    });

    test('light() preserves semantic accent colors', () {
      const dark = WatchdogThemeData();
      const light = WatchdogThemeData.light();
      expect(light.severityCritical, dark.severityCritical);
      expect(light.severityWarning, dark.severityWarning);
      expect(light.severityOk, dark.severityOk);
      expect(light.categoryBuild, dark.categoryBuild);
      expect(light.categoryMemory, dark.categoryMemory);
      expect(light.categoryNetwork, dark.categoryNetwork);
    });

    test('copyWith overrides specific field and preserves others', () {
      const original = WatchdogThemeData();
      final custom = original.copyWith(
        severityCritical: const Color(0xFFFF0000),
      );
      expect(custom.severityCritical, const Color(0xFFFF0000));
      expect(custom.severityWarning, original.severityWarning);
      expect(custom.pageBackground, original.pageBackground);
      expect(custom.textPrimary, original.textPrimary);
    });

    test('copyWith with no args returns equivalent data', () {
      const original = WatchdogThemeData();
      final copy = original.copyWith();
      expect(copy.severityCritical, original.severityCritical);
      expect(copy.pageBackground, original.pageBackground);
      expect(copy.textPrimary, original.textPrimary);
      expect(copy.guideTipIcon, original.guideTipIcon);
    });
  });

  group('spacing tokens', () {
    test('dark defaults have correct values', () {
      const t = WatchdogThemeData();
      expect(t.spacingXxs, 2);
      expect(t.spacingXs, 4);
      expect(t.spacingSm, 6);
      expect(t.spacingMd, 8);
      expect(t.spacingLg, 12);
      expect(t.spacingXl, 16);
    });

    test('light theme shares same spacing defaults', () {
      const dark = WatchdogThemeData();
      const light = WatchdogThemeData.light();
      expect(light.spacingXxs, dark.spacingXxs);
      expect(light.spacingXs, dark.spacingXs);
      expect(light.spacingSm, dark.spacingSm);
      expect(light.spacingMd, dark.spacingMd);
      expect(light.spacingLg, dark.spacingLg);
      expect(light.spacingXl, dark.spacingXl);
    });

    test('copyWith overrides spacing tokens', () {
      const t = WatchdogThemeData();
      final custom = t.copyWith(spacingMd: 10, spacingXl: 20);
      expect(custom.spacingMd, 10);
      expect(custom.spacingXl, 20);
      // Unchanged
      expect(custom.spacingXs, t.spacingXs);
      expect(custom.spacingSm, t.spacingSm);
    });
  });

  group('categoryColor', () {
    const t = WatchdogThemeData();

    test('returns correct color for all 8 categories', () {
      expect(t.categoryColor(IssueCategory.build), t.categoryBuild);
      expect(t.categoryColor(IssueCategory.layout), t.categoryLayout);
      expect(t.categoryColor(IssueCategory.paint), t.categoryPaint);
      expect(t.categoryColor(IssueCategory.raster), t.categoryRaster);
      expect(t.categoryColor(IssueCategory.memory), t.categoryMemory);
      expect(t.categoryColor(IssueCategory.channel), t.categoryChannel);
      expect(t.categoryColor(IssueCategory.font), t.categoryFont);
      expect(t.categoryColor(IssueCategory.network), t.categoryNetwork);
    });
  });

  group('confidenceColor', () {
    const t = WatchdogThemeData();

    test('returns correct color for all 3 levels', () {
      expect(
          t.confidenceColor(IssueConfidence.confirmed), t.confidenceConfirmed);
      expect(t.confidenceColor(IssueConfidence.likely), t.confidenceLikely);
      expect(t.confidenceColor(IssueConfidence.possible), t.confidencePossible);
    });
  });

  group('sourceAccentColor', () {
    const t = WatchdogThemeData();

    test('returns correct color for all sources and null', () {
      expect(t.sourceAccentColor(ObservationSource.vmTimeline),
          t.sourceVmTimeline);
      expect(t.sourceAccentColor(ObservationSource.debugCallback),
          t.sourceDebugCallback);
      expect(t.sourceAccentColor(ObservationSource.debugCallbackAndStructural),
          t.sourceDebugCallback);
      expect(t.sourceAccentColor(ObservationSource.structural),
          t.sourceStructural);
      expect(t.sourceAccentColor(null), t.sourceNone);
    });
  });

  group('effortColor', () {
    const t = WatchdogThemeData();

    test('returns correct color for all 3 levels', () {
      expect(t.effortColor(FixEffort.quick), t.effortQuick);
      expect(t.effortColor(FixEffort.medium), t.effortMedium);
      expect(t.effortColor(FixEffort.involved), t.effortInvolved);
    });
  });

  group('fpsColor', () {
    const t = WatchdogThemeData();

    test('returns green at or above 83% of target', () {
      expect(t.fpsColor(60), t.severityOk);
      expect(t.fpsColor(50), t.severityOk);
    });

    test('returns amber between 50% and 83% of target', () {
      expect(t.fpsColor(49), t.severityWarning);
      expect(t.fpsColor(30), t.severityWarning);
    });

    test('returns red below 50% of target', () {
      expect(t.fpsColor(29), t.severityCritical);
      expect(t.fpsColor(0), t.severityCritical);
    });

    test('respects custom target', () {
      // target=120: 83% = 99.6, 50% = 60
      expect(t.fpsColor(100, target: 120), t.severityOk);
      expect(t.fpsColor(80, target: 120), t.severityWarning);
      expect(t.fpsColor(50, target: 120), t.severityCritical);
    });
  });

  group('WatchdogTheme InheritedWidget', () {
    testWidgets('of() returns dark fallback when no ancestor', (tester) async {
      late WatchdogThemeData captured;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              captured = WatchdogTheme.of(context);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(captured.pageBackground, const Color(0xFF1E1E2E));
      expect(captured.textPrimary, const Color(0xFFFFFFFF));
    });

    testWidgets('of() returns provided theme when ancestor exists',
        (tester) async {
      late WatchdogThemeData captured;
      const light = WatchdogThemeData.light();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: WatchdogTheme(
            data: light,
            child: Builder(
              builder: (context) {
                captured = WatchdogTheme.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      expect(identical(captured, light), isTrue);
    });

    testWidgets('custom theme propagates to descendants', (tester) async {
      late WatchdogThemeData captured;
      final custom = const WatchdogThemeData().copyWith(
        severityCritical: const Color(0xFFFF0000),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: WatchdogTheme(
            data: custom,
            child: Builder(
              builder: (context) {
                captured = WatchdogTheme.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      expect(captured.severityCritical, const Color(0xFFFF0000));
      // Other fields unchanged
      expect(captured.severityWarning, const Color(0xFFF59E0B));
    });
  });
}
