import 'dart:io';

import 'package:flutter/material.dart' show Brightness, ThemeData;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/sleuth_theme.dart';

import '../helpers/contrast_helpers.dart';

const _presets = <String, SleuthThemeData>{
  'dark': SleuthThemeData(),
  'light': SleuthThemeData.light(),
  'highContrastDark': SleuthThemeData.highContrastDark(),
  'highContrastLight': SleuthThemeData.highContrastLight(),
};

const _black = Color(0xFF000000);
const _white = Color(0xFFFFFFFF);

/// Opaque surfaces the overlay draws text on. The translucent card
/// background is taken over a black and a white host.
Map<String, Color> _surfaces(SleuthThemeData t) => {
  'pageBackground': t.pageBackground,
  'sectionBackground': t.sectionBackground,
  'cardBackground/black': composite(t.cardBackground, _black),
  'cardBackground/white': composite(t.cardBackground, _white),
  'cardDefault': t.cardDefault,
  'cardHighlighted': t.cardHighlighted,
  'cardJankFlash': t.cardJankFlash,
  'aboutBackground': t.aboutBackground,
  'fixHintBackground': t.fixHintBackground,
};

/// Every (text, background) pair the overlay draws, with its minimum ratio.
List<(String, Color, Color, double)> _pairs(SleuthThemeData t) {
  final surfaces = _surfaces(t);
  final pairs = <(String, Color, Color, double)>[];
  void add(String name, Color fg, Color bg, [double min = 4.5]) =>
      pairs.add((name, fg, bg, min));

  final texts = {
    'textPrimary': t.textPrimary,
    'textSecondary': t.textSecondary,
    'textTertiary': t.textTertiary,
    'textQuaternary': t.textQuaternary,
    'severityCriticalText': t.severityCriticalText,
    'severityWarningText': t.severityWarningText,
    'severityOkText': t.severityOkText,
  };
  for (final text in texts.entries) {
    for (final s in surfaces.entries) {
      add('${text.key} on ${s.key}', text.value, s.value);
    }
  }
  // Severity badges: severity text on the severity tint.
  for (final severity in IssueSeverity.values) {
    final accent = t.severityColor(severity);
    final fg = t.badgeTextOn(accent, tinted: t.severityTextColor(severity));
    for (final s in [
      'cardDefault',
      'cardHighlighted',
      'cardBackground/black',
    ]) {
      add(
        '${severity.name} badge on $s',
        fg,
        composite(t.badgeFill(accent), surfaces[s]!),
      );
    }
  }
  // Category, confidence, source, effort and effects badges.
  final accents = {
    for (final c in IssueCategory.values)
      'category.${c.name}': t.categoryColor(c),
    for (final c in IssueConfidence.values)
      'confidence.${c.name}': t.confidenceColor(c),
    for (final e in FixEffort.values) 'effort.${e.name}': t.effortColor(e),
    'effectsBadge': t.effectsBadge,
  };
  for (final a in accents.entries) {
    for (final s in [
      'cardDefault',
      'cardHighlighted',
      'aboutBackground',
      'fixHintBackground',
    ]) {
      add(
        '${a.key} badge on $s',
        t.badgeTextOn(a.value),
        composite(t.badgeFill(a.value), surfaces[s]!),
      );
    }
  }
  add('badgeVm', t.badgeVmText, t.badgeVmBg);
  add('badgeFrame', t.badgeFrameText, t.badgeFrameBg);
  add('badgeDbg', t.badgeDbgText, t.badgeDbgBg);
  add('bannerDebug', t.bannerDebugText, t.bannerDebugBg);
  add(
    'bannerInstrumentation',
    t.bannerInstrumentationText,
    t.bannerInstrumentationBg,
  );
  add('bannerSuccess', t.bannerSuccessText, t.bannerSuccessBg);
  add('bannerWarning', t.bannerWarningText, t.bannerWarningBg);
  add('fixHintText', t.fixHintText, t.fixHintBackground);
  add('disclaimerText on cardDefault', t.disclaimerText, t.cardDefault);
  add('disclaimerText on cardHighlighted', t.disclaimerText, t.cardHighlighted);
  add('aiChatUserBubble', t.aiChatUserBubbleText, t.aiChatUserBubbleBg);
  add(
    'checkboxActive text on pageBackground',
    t.checkboxActive,
    t.pageBackground,
  );
  add(
    'checkboxActive text on cardBackground',
    t.checkboxActive,
    surfaces['cardBackground/black']!,
  );
  add('checkboxActive on cardDefault', t.checkboxActive, t.cardDefault, 3);
  add('trigger count', t.textPrimary, t.triggerBadgeBg);
  add('trigger icon on critical', t.triggerIconColor, t.severityCritical, 3);
  add(
    'trigger icon on warning',
    t.triggerIconOnLightFill,
    t.severityWarning,
    3,
  );
  add('trigger icon on ok', t.triggerIconOnLightFill, t.severityOk, 3);
  return pairs;
}

void main() {
  group('contrast', () {
    test('helper agrees with the theme ratio', () {
      expect(wcagContrast(_black, _white), closeTo(21, 0.01));
      expect(
        SleuthThemeData.contrastRatio(
          const Color(0xFF374151),
          const Color(0xFFE5E7EB),
        ),
        closeTo(
          wcagContrast(const Color(0xFF374151), const Color(0xFFE5E7EB)),
          1e-9,
        ),
      );
    });

    for (final preset in _presets.entries) {
      test('${preset.key}: every text pair meets its minimum', () {
        final failures = [
          for (final (name, fg, bg, min) in _pairs(preset.value))
            if (wcagContrast(fg, bg) < min)
              '$name: ${wcagContrast(fg, bg).toStringAsFixed(2)} < $min',
        ];
        expect(failures, isEmpty);
      });
    }

    const seeds = [
      Color(0xFF6750A4),
      Color(0xFF0B57D0),
      Color(0xFF146C2E),
      Color(0xFFB3261E),
      Color(0xFFFFC107),
      Color(0xFF00838F),
    ];
    for (final brightness in Brightness.values) {
      test('fromSeed (${brightness.name}) text passes on every surface', () {
        for (final seed in seeds) {
          final t = SleuthThemeData.fromSeed(seed, brightness: brightness);
          final surfaces = _surfaces(t);
          for (final text in [
            t.textPrimary,
            t.textSecondary,
            t.textTertiary,
            t.textQuaternary,
          ]) {
            for (final s in surfaces.entries) {
              expect(
                wcagContrast(text, s.value),
                greaterThanOrEqualTo(4.5),
                reason: 'seed $seed ${brightness.name}: $text on ${s.key}',
              );
            }
          }
          // Never light text on a light surface or dark on dark.
          final surfaceDark =
              ThemeData.estimateBrightnessForColor(t.pageBackground) ==
              Brightness.dark;
          final textLight =
              ThemeData.estimateBrightnessForColor(t.textPrimary) ==
              Brightness.light;
          expect(textLight, surfaceDark, reason: 'seed $seed');
          expect(
            t.brightness,
            surfaceDark ? Brightness.dark : Brightness.light,
          );
          // Sleuth's semantic colours stay.
          expect(t.severityCritical, const SleuthThemeData().severityCritical);
          expect(t.categoryBuild, const SleuthThemeData().categoryBuild);
        }
      });
    }
  });

  group('presets', () {
    test('theme token map covers every field', () {
      final src = File('lib/src/ui/sleuth_theme.dart').readAsStringSync();
      final fields = RegExp(
        r'^  final (?:Color|double|Brightness) (\w+);',
        multiLine: true,
      ).allMatches(src).map((m) => m.group(1)).toSet();
      expect(themeTokens(const SleuthThemeData()).keys.toSet(), fields);
    });

    test('brightness matches each preset', () {
      expect(const SleuthThemeData().brightness, Brightness.dark);
      expect(const SleuthThemeData.light().brightness, Brightness.light);
      expect(
        const SleuthThemeData.highContrastDark().brightness,
        Brightness.dark,
      );
      expect(
        const SleuthThemeData.highContrastLight().brightness,
        Brightness.light,
      );
    });

    Set<String> diff(SleuthThemeData a, SleuthThemeData b) {
      final ta = themeTokens(a);
      final tb = themeTokens(b);
      return {
        for (final k in ta.keys)
          if (ta[k] != tb[k]) k,
      };
    }

    const hcTokens = {
      'textTertiary',
      'textQuaternary',
      'border',
      'badgeFillAlpha',
      'focusRingWidth',
      'sourceAccentWidth',
    };

    test('highContrastDark differs from dark only on the listed tokens', () {
      expect(
        diff(const SleuthThemeData.highContrastDark(), const SleuthThemeData()),
        hcTokens,
      );
    });

    test('highContrastLight differs from light only on the listed tokens', () {
      expect(
        diff(
          const SleuthThemeData.highContrastLight(),
          const SleuthThemeData.light(),
        ),
        hcTokens,
      );
    });

    test('high-contrast text collapses to secondary, fills are opaque', () {
      for (final t in [
        const SleuthThemeData.highContrastDark(),
        const SleuthThemeData.highContrastLight(),
      ]) {
        expect(t.textTertiary, t.textSecondary);
        expect(t.textQuaternary, t.textSecondary);
        expect(t.badgeFillAlpha, 1);
        expect(t.focusRingWidth, 2);
      }
    });

    test('const presets are canonical instances', () {
      expect(
        identical(
          const SleuthThemeData.highContrastDark(),
          const SleuthThemeData.highContrastDark(),
        ),
        isTrue,
      );
      expect(
        identical(
          const SleuthThemeData.highContrastLight(),
          const SleuthThemeData.highContrastLight(),
        ),
        isTrue,
      );
    });

    test('copyWith round-trips every new field', () {
      final t = const SleuthThemeData().copyWith(
        brightness: Brightness.light,
        severityCriticalText: const Color(0xFF010101),
        severityWarningText: const Color(0xFF020202),
        severityOkText: const Color(0xFF030303),
        badgeFillAlpha: 0.5,
        focusRingWidth: 3,
        sourceAccentWidth: 7,
        triggerIconOnLightFill: const Color(0xFF040404),
      );
      expect(t.brightness, Brightness.light);
      expect(t.severityCriticalText, const Color(0xFF010101));
      expect(t.severityWarningText, const Color(0xFF020202));
      expect(t.severityOkText, const Color(0xFF030303));
      expect(t.badgeFillAlpha, 0.5);
      expect(t.focusRingWidth, 3);
      expect(t.sourceAccentWidth, 7);
      expect(t.triggerIconOnLightFill, const Color(0xFF040404));
      // Unset fields keep their value.
      expect(
        themeTokens(const SleuthThemeData.light().copyWith()),
        themeTokens(const SleuthThemeData.light()),
      );
    });

    test('badgeTextOn picks black or white on opaque fills', () {
      const hc = SleuthThemeData.highContrastDark();
      expect(hc.badgeTextOn(const Color(0xFFF59E0B)), _black);
      expect(hc.badgeTextOn(const Color(0xFF1E3A5F)), _white);
      const base = SleuthThemeData();
      expect(base.badgeTextOn(const Color(0xFFF59E0B)), base.textPrimary);
      expect(
        base.badgeTextOn(
          const Color(0xFFF59E0B),
          tinted: base.severityWarningText,
        ),
        base.severityWarningText,
      );
    });
  });

  group('SleuthThemeData', () {
    test('dark defaults match documented hex values', () {
      const t = SleuthThemeData();
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
      expect(t.textTertiary, const Color(0xFFB4BAC4));
      expect(t.textQuaternary, const Color(0xFFA8AFBA));
      expect(t.textSubtle, const Color(0xFF4B5563));
      // Category
      expect(t.categoryBuild, const Color(0xFF3B82F6));
      expect(t.categoryNetwork, const Color(0xFFF97316));
      // Special
      expect(t.guideStepAccent, const Color(0xFF3B82F6));
      expect(t.guideTipIcon, const Color(0xFFF59E0B));
    });

    test('dark() is identical to default constructor', () {
      const def = SleuthThemeData();
      const dark = SleuthThemeData.dark();
      expect(identical(def, dark), isTrue);
    });

    test('light() returns distinct surface/text values', () {
      const dark = SleuthThemeData();
      const light = SleuthThemeData.light();
      expect(light.pageBackground, isNot(dark.pageBackground));
      expect(light.textPrimary, isNot(dark.textPrimary));
      expect(light.sectionBackground, isNot(dark.sectionBackground));
      expect(light.cardBackground, isNot(dark.cardBackground));
      expect(light.border, isNot(dark.border));
    });

    test('light() preserves semantic accent colors', () {
      const dark = SleuthThemeData();
      const light = SleuthThemeData.light();
      expect(light.severityCritical, dark.severityCritical);
      expect(light.severityWarning, dark.severityWarning);
      expect(light.severityOk, dark.severityOk);
      expect(light.categoryBuild, dark.categoryBuild);
      expect(light.categoryMemory, dark.categoryMemory);
      expect(light.categoryNetwork, dark.categoryNetwork);
    });

    test('copyWith overrides specific field and preserves others', () {
      const original = SleuthThemeData();
      final custom = original.copyWith(
        severityCritical: const Color(0xFFFF0000),
      );
      expect(custom.severityCritical, const Color(0xFFFF0000));
      expect(custom.severityWarning, original.severityWarning);
      expect(custom.pageBackground, original.pageBackground);
      expect(custom.textPrimary, original.textPrimary);
    });

    test('copyWith with no args returns equivalent data', () {
      const original = SleuthThemeData();
      final copy = original.copyWith();
      expect(copy.severityCritical, original.severityCritical);
      expect(copy.pageBackground, original.pageBackground);
      expect(copy.textPrimary, original.textPrimary);
      expect(copy.guideTipIcon, original.guideTipIcon);
    });
  });

  group('spacing tokens', () {
    test('dark defaults have correct values', () {
      const t = SleuthThemeData();
      expect(t.spacingXxs, 2);
      expect(t.spacingXs, 4);
      expect(t.spacingSm, 6);
      expect(t.spacingMd, 8);
      expect(t.spacingLg, 12);
      expect(t.spacingXl, 16);
    });

    test('light theme shares same spacing defaults', () {
      const dark = SleuthThemeData();
      const light = SleuthThemeData.light();
      expect(light.spacingXxs, dark.spacingXxs);
      expect(light.spacingXs, dark.spacingXs);
      expect(light.spacingSm, dark.spacingSm);
      expect(light.spacingMd, dark.spacingMd);
      expect(light.spacingLg, dark.spacingLg);
      expect(light.spacingXl, dark.spacingXl);
    });

    test('copyWith overrides spacing tokens', () {
      const t = SleuthThemeData();
      final custom = t.copyWith(spacingMd: 10, spacingXl: 20);
      expect(custom.spacingMd, 10);
      expect(custom.spacingXl, 20);
      // Unchanged
      expect(custom.spacingXs, t.spacingXs);
      expect(custom.spacingSm, t.spacingSm);
    });
  });

  group('categoryColor', () {
    const t = SleuthThemeData();

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
    const t = SleuthThemeData();

    test('returns correct color for all 3 levels', () {
      expect(
        t.confidenceColor(IssueConfidence.confirmed),
        t.confidenceConfirmed,
      );
      expect(t.confidenceColor(IssueConfidence.likely), t.confidenceLikely);
      expect(t.confidenceColor(IssueConfidence.possible), t.confidencePossible);
    });
  });

  group('sourceAccentColor', () {
    const t = SleuthThemeData();

    test('returns correct color for all sources and null', () {
      expect(
        t.sourceAccentColor(ObservationSource.vmTimeline),
        t.sourceVmTimeline,
      );
      expect(
        t.sourceAccentColor(ObservationSource.debugCallback),
        t.sourceDebugCallback,
      );
      expect(
        t.sourceAccentColor(ObservationSource.debugCallbackAndStructural),
        t.sourceDebugCallback,
      );
      expect(
        t.sourceAccentColor(ObservationSource.structural),
        t.sourceStructural,
      );
      expect(
        t.sourceAccentColor(ObservationSource.frameTiming),
        t.sourceVmTimeline,
      );
      expect(t.sourceAccentColor(null), t.sourceNone);
    });
  });

  group('effortColor', () {
    const t = SleuthThemeData();

    test('returns correct color for all 3 levels', () {
      expect(t.effortColor(FixEffort.quick), t.effortQuick);
      expect(t.effortColor(FixEffort.medium), t.effortMedium);
      expect(t.effortColor(FixEffort.involved), t.effortInvolved);
    });
  });

  group('fpsColor', () {
    const t = SleuthThemeData();

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

  group('SleuthTheme InheritedWidget', () {
    testWidgets('of() returns dark fallback when no ancestor', (tester) async {
      late SleuthThemeData captured;

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Builder(
            builder: (context) {
              captured = SleuthTheme.of(context);
              return const SizedBox();
            },
          ),
        ),
      );

      expect(captured.pageBackground, const Color(0xFF1E1E2E));
      expect(captured.textPrimary, const Color(0xFFFFFFFF));
    });

    testWidgets('of() returns provided theme when ancestor exists', (
      tester,
    ) async {
      late SleuthThemeData captured;
      const light = SleuthThemeData.light();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SleuthTheme(
            data: light,
            child: Builder(
              builder: (context) {
                captured = SleuthTheme.of(context);
                return const SizedBox();
              },
            ),
          ),
        ),
      );

      expect(identical(captured, light), isTrue);
    });

    testWidgets('custom theme propagates to descendants', (tester) async {
      late SleuthThemeData captured;
      final custom = const SleuthThemeData().copyWith(
        severityCritical: const Color(0xFFFF0000),
      );

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SleuthTheme(
            data: custom,
            child: Builder(
              builder: (context) {
                captured = SleuthTheme.of(context);
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
