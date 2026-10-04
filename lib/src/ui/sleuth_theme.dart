import 'package:flutter/material.dart' show ColorScheme, ThemeData;
import 'package:flutter/widgets.dart';

import '../models/performance_issue.dart';

/// All visual tokens for the Sleuth overlay UI.
///
/// Default constructor produces the **dark** theme (matching the original
/// hardcoded overlay). Use [SleuthThemeData.light] for light-background
/// apps, or call [copyWith] to override individual tokens.
///
/// ## Quick start
///
/// ```dart
/// // Auto-detect (default) — no config needed
/// Sleuth.track(child: MyApp());
///
/// // Force light theme
/// Sleuth.track(
///   child: MyApp(),
///   config: SleuthConfig(theme: SleuthThemeData.light()),
/// );
///
/// // Custom overrides
/// Sleuth.track(
///   child: MyApp(),
///   config: SleuthConfig(
///     theme: SleuthThemeData.light().copyWith(
///       severityCritical: Color(0xFFDC2626),
///       severityWarning: Color(0xFFD97706),
///     ),
///   ),
/// );
/// ```
///
/// ## Token groups
///
/// - **Severity** (3): `severityCritical`, `severityWarning`, `severityOk`
/// - **Severity text** (3): `severityCriticalText`, `severityWarningText`,
///   `severityOkText`, severity-hued text readable on the card surfaces
/// - **Category badges** (8): one per [IssueCategory] — `categoryBuild`, etc.
/// - **Confidence** (3): `confidenceConfirmed`, `confidenceLikely`, `confidencePossible`
/// - **Source accents** (4): left border on issue cards — `sourceVmTimeline`, etc.
/// - **Fix effort** (3): `effortQuick`, `effortMedium`, `effortInvolved`
/// - **Surfaces** (9): backgrounds, borders, card states
/// - **Text hierarchy** (5): `textPrimary` through `textSubtle`
/// - **Badge pairs** (6): bg + text for VM/FRAME/DBG badges
/// - **Banner pairs** (8): bg + text for debug/instrumentation/success/warning
/// - **Causal graph** (1): `effectsBadge` for downstream effects count
/// - **Spacing** (6): `spacingXxs` through `spacingXl`
/// - **Typography** (9): `fontXxs` (10) through `fontDisplay` (24); 10 px
///   is the smallest size the overlay draws
/// - **Border radius** (7): `radiusSm` (4) through `radiusFull` (20)
/// - **Special** (12): fix hint text, grip dots, guide accents, etc.
/// - **Accessibility** (4): `badgeFillAlpha`, `focusRingWidth`,
///   `sourceAccentWidth`, `triggerIconOnLightFill`
///
/// ## Presets
///
/// - [SleuthThemeData.new] / [SleuthThemeData.dark] and
///   [SleuthThemeData.light]: the default dark and light themes.
/// - [SleuthThemeData.highContrastDark] and
///   [SleuthThemeData.highContrastLight]: chosen automatically when the
///   platform reports high contrast and no theme is set.
/// - [SleuthThemeData.fromColorScheme] and [SleuthThemeData.fromSeed]:
///   surfaces and text from a Material [ColorScheme]; severity, category,
///   confidence and source colours stay Sleuth's.
///
/// Text tokens meet WCAG AA (4.5:1) on every surface token in all four
/// presets. Badges draw [textPrimary] on a [badgeFillAlpha] tint of their
/// accent with a 1 px accent border; severity badges use the severity text
/// tokens. With opaque fills (`badgeFillAlpha == 1`, the high-contrast
/// presets) badge text is black or white, whichever contrasts more.
///
/// ## Badge and banner pairs
///
/// Tokens like [badgeVmBg]/[badgeVmText] are designed as contrast pairs.
/// When overriding, always set both bg and text together to maintain
/// readability.
///
/// ## Design principles
///
/// The [light] constructor inverts surfaces and text while keeping semantic
/// accent colors (severity, category, confidence) unchanged — their meaning
/// comes from hue, which should be consistent across themes.
class SleuthThemeData {
  /// Dark theme — matches every original hardcoded color exactly.
  ///
  /// **Palette note:** Several semantic tokens share the same default hex
  /// value (e.g. `severityOk`, `confidenceConfirmed`, `effortQuick`, and
  /// `sourceVmTimeline` are all `0xFF10B981` green). This is intentional —
  /// "green = good" is a consistent semantic across contexts. Each token is
  /// independently overridable via [copyWith], so changing one does not
  /// affect the others.
  const SleuthThemeData({
    this.brightness = Brightness.dark,

    // ── Severity (also used for FPS) ──
    // Note: severity palette overlaps with category/effort/confidence by
    // design — red/amber/green carries the same meaning everywhere.
    this.severityCritical = const Color(0xFFEF4444),
    this.severityWarning = const Color(0xFFF59E0B),
    this.severityOk = const Color(0xFF10B981),
    this.severityCriticalText = const Color(0xFFFCA5A5),
    this.severityWarningText = const Color(0xFFFCD34D),
    this.severityOkText = const Color(0xFF6EE7B7),

    // ── Category badges ──
    this.categoryBuild = const Color(0xFF3B82F6),
    this.categoryLayout = const Color(0xFFF59E0B),
    this.categoryPaint = const Color(0xFF10B981),
    this.categoryRaster = const Color(0xFFEF4444),
    this.categoryMemory = const Color(0xFF8B5CF6),
    this.categoryChannel = const Color(0xFF06B6D4),
    this.categoryFont = const Color(0xFF6B7280),
    this.categoryNetwork = const Color(0xFFF97316),
    this.categoryStartup = const Color(0xFF0EA5E9),

    // ── Confidence ──
    this.confidenceConfirmed = const Color(0xFF10B981),
    this.confidenceLikely = const Color(0xFFF59E0B),
    this.confidencePossible = const Color(0xFF6B7280),

    // ── Source accents (left border on issue cards) ──
    this.sourceVmTimeline = const Color(0xFF10B981),
    this.sourceDebugCallback = const Color(0xFF8B5CF6),
    this.sourceStructural = const Color(0xFF6B7280),
    this.sourceNone = const Color(0xFF4B5563),

    // ── Fix effort ──
    this.effortQuick = const Color(0xFF10B981),
    this.effortMedium = const Color(0xFFF59E0B),
    this.effortInvolved = const Color(0xFFEF4444),

    // ── Surfaces ──
    this.cardBackground = const Color(0xF51E1E2E),
    this.pageBackground = const Color(0xFF1E1E2E),
    this.sectionBackground = const Color(0xFF252536),
    this.aboutBackground = const Color(0xFF111827),
    this.fixHintBackground = const Color(0xFF1F2937),
    this.border = const Color(0xFF374151),
    this.cardDefault = const Color(0xFF374151),
    this.cardHighlighted = const Color(0xFF1E3A5F),
    this.cardJankFlash = const Color(0xFF5F2D1E),

    // ── Text hierarchy ──
    this.textPrimary = const Color(0xFFFFFFFF),
    this.textSecondary = const Color(0xFFD1D5DB),
    this.textTertiary = const Color(0xFFB4BAC4),
    this.textQuaternary = const Color(0xFFA8AFBA),
    this.textSubtle = const Color(0xFF4B5563),

    // ── Badge pairs ──
    this.badgeVmBg = const Color(0xFF065F46),
    this.badgeVmText = const Color(0xFF6EE7B7),
    this.badgeFrameBg = const Color(0xFF1E3A5F),
    this.badgeFrameText = const Color(0xFF93C5FD),
    this.badgeDbgBg = const Color(0xFF5B21B6),
    this.badgeDbgText = const Color(0xFFC4B5FD),

    // ── Banner pairs ──
    this.bannerDebugBg = const Color(0xFF92400E),
    this.bannerDebugText = const Color(0xFFFCD34D),
    this.bannerInstrumentationBg = const Color(0xFF5B21B6),
    this.bannerInstrumentationText = const Color(0xFFDDD6FE),
    this.bannerSuccessBg = const Color(0xFF065F46),
    this.bannerSuccessText = const Color(0xFF6EE7B7),
    this.bannerWarningBg = const Color(0xFF78350F),
    this.bannerWarningText = const Color(0xFFFCD34D),

    // ── Causal graph ──
    this.effectsBadge = const Color(0xFF64748B),

    // ── Special ──
    this.fixHintText = const Color(0xFF93C5FD),
    this.disclaimerText = const Color(0xFFFCD34D),
    this.dimOverlay = const Color(0x44000000),
    this.shadow = const Color(0xCC000000),
    this.gripDots = const Color(0xFF9CA3AF),
    this.checkboxActive = const Color(0xFF60A5FA),
    this.triggerBadgeBg = const Color(0xFF1F2937),
    this.guideStepAccent = const Color(0xFF3B82F6),
    this.guideTipIcon = const Color(0xFFF59E0B),
    this.highlightLabelText = const Color(0xFFFFFFFF),
    this.highlightDot = const Color(0xFFFFFFFF),
    this.triggerIconColor = const Color(0xFFFFFFFF),

    // ── Accessibility ──
    this.badgeFillAlpha = 0.15,
    this.focusRingWidth = 0,
    this.sourceAccentWidth = 3,
    this.triggerIconOnLightFill = const Color(0xFF111827),

    // ── AI Chat ──
    this.aiChatUserBubbleBg = const Color(0xFF2563EB),
    this.aiChatUserBubbleText = const Color(0xFFFFFFFF),

    // ── AI Shimmer (Ask AI link gradient) ──
    this.aiShimmerStart = const Color(0xFF8B5CF6),
    this.aiShimmerMid = const Color(0xFF3B82F6),
    this.aiShimmerEnd = const Color(0xFFEC4899),

    // ── Spacing ──
    this.spacingXxs = 2,
    this.spacingXs = 4,
    this.spacingSm = 6,
    this.spacingMd = 8,
    this.spacingLg = 12,
    this.spacingXl = 16,

    // ── Typography scale ──
    this.fontXxs = 10,
    this.fontXs = 10,
    this.fontSm = 10,
    this.fontMd = 11,
    this.fontBase = 12,
    this.fontLg = 13,
    this.fontXl = 16,
    this.fontXxl = 20,
    this.fontDisplay = 24,

    // ── Border radius scale ──
    this.radiusSm = 4,
    this.radiusMd = 6,
    this.radiusLg = 8,
    this.radiusXl = 10,
    this.radiusXxl = 12,
    this.radiusCard = 16,
    this.radiusFull = 20,
  });

  /// Explicit dark theme — identical to the default constructor.
  ///
  /// Provided for readability when you want to make the dark choice visible:
  /// `SleuthConfig(theme: SleuthThemeData.dark())`.
  const SleuthThemeData.dark() : this();

  /// Light theme for light-background apps.
  ///
  /// Inverts surfaces (dark → white/light gray) and text (white → near-black)
  /// while keeping all semantic accent colors (severity, category, confidence,
  /// source, effort) identical. Badge and banner pairs are swapped
  /// (dark bg + light text → light bg + dark text).
  ///
  /// Tokens not overridden here (e.g. [guideStepAccent], [guideTipIcon])
  /// retain their dark-theme values because they are used on colored
  /// backgrounds where the dark value provides correct contrast.
  const SleuthThemeData.light()
    : this(
        brightness: Brightness.light,
        // Surfaces
        cardBackground: const Color(0xF5FFFFFF),
        pageBackground: const Color(0xFFF9FAFB),
        sectionBackground: const Color(0xFFF3F4F6),
        aboutBackground: const Color(0xFFE5E7EB),
        fixHintBackground: const Color(0xFFEFF6FF),
        border: const Color(0xFFD1D5DB),
        cardDefault: const Color(0xFFE5E7EB),
        cardHighlighted: const Color(0xFFDBEAFE),
        cardJankFlash: const Color(0xFFFEE2E2),
        // Text (dark on light)
        textPrimary: const Color(0xFF111827),
        textSecondary: const Color(0xFF374151),
        textTertiary: const Color(0xFF4B5563),
        textQuaternary: const Color(0xFF5B6270),
        textSubtle: const Color(0xFFD1D5DB),
        // Severity text (deep tones for light surfaces)
        severityCriticalText: const Color(0xFF991B1B),
        severityWarningText: const Color(0xFF92400E),
        severityOkText: const Color(0xFF065F46),
        // Badge pairs (inverted: light bg, dark text)
        badgeVmBg: const Color(0xFFD1FAE5),
        badgeVmText: const Color(0xFF065F46),
        badgeFrameBg: const Color(0xFFDBEAFE),
        badgeFrameText: const Color(0xFF1E3A5F),
        badgeDbgBg: const Color(0xFFEDE9FE),
        badgeDbgText: const Color(0xFF5B21B6),
        // Banner pairs (inverted)
        bannerDebugBg: const Color(0xFFFEF3C7),
        bannerDebugText: const Color(0xFF92400E),
        bannerInstrumentationBg: const Color(0xFFEDE9FE),
        bannerInstrumentationText: const Color(0xFF5B21B6),
        bannerSuccessBg: const Color(0xFFD1FAE5),
        bannerSuccessText: const Color(0xFF065F46),
        bannerWarningBg: const Color(0xFFFEF3C7),
        bannerWarningText: const Color(0xFF78350F),
        // Special (contrast-appropriate for light bg)
        fixHintText: const Color(0xFF1D4ED8),
        disclaimerText: const Color(0xFF92400E),
        dimOverlay: const Color(0x22000000),
        shadow: const Color(0x33000000),
        gripDots: const Color(0xFF6B7280),
        checkboxActive: const Color(0xFF2563EB),
        triggerBadgeBg: const Color(0xFFE5E7EB),
      );

  /// High-contrast dark theme.
  ///
  /// The dark theme with tertiary and quaternary text raised to
  /// [textSecondary], stronger borders, opaque badge fills, a 2 px focus
  /// ring and a wider source accent. Chosen automatically when the
  /// platform reports high contrast (`MediaQuery.highContrastOf`, iOS
  /// Increase Contrast) in dark mode and no theme is set; pass it to
  /// `Sleuth.updateTheme` on other platforms.
  const SleuthThemeData.highContrastDark()
    : this(
        textTertiary: const Color(0xFFD1D5DB),
        textQuaternary: const Color(0xFFD1D5DB),
        border: const Color(0xFF9CA3AF),
        badgeFillAlpha: 1,
        focusRingWidth: 2,
        sourceAccentWidth: 5,
      );

  /// High-contrast light theme. See [SleuthThemeData.highContrastDark].
  const SleuthThemeData.highContrastLight()
    : this(
        brightness: Brightness.light,
        cardBackground: const Color(0xF5FFFFFF),
        pageBackground: const Color(0xFFF9FAFB),
        sectionBackground: const Color(0xFFF3F4F6),
        aboutBackground: const Color(0xFFE5E7EB),
        fixHintBackground: const Color(0xFFEFF6FF),
        border: const Color(0xFF6B7280),
        cardDefault: const Color(0xFFE5E7EB),
        cardHighlighted: const Color(0xFFDBEAFE),
        cardJankFlash: const Color(0xFFFEE2E2),
        textPrimary: const Color(0xFF111827),
        textSecondary: const Color(0xFF374151),
        textTertiary: const Color(0xFF374151),
        textQuaternary: const Color(0xFF374151),
        textSubtle: const Color(0xFFD1D5DB),
        severityCriticalText: const Color(0xFF991B1B),
        severityWarningText: const Color(0xFF92400E),
        severityOkText: const Color(0xFF065F46),
        badgeVmBg: const Color(0xFFD1FAE5),
        badgeVmText: const Color(0xFF065F46),
        badgeFrameBg: const Color(0xFFDBEAFE),
        badgeFrameText: const Color(0xFF1E3A5F),
        badgeDbgBg: const Color(0xFFEDE9FE),
        badgeDbgText: const Color(0xFF5B21B6),
        bannerDebugBg: const Color(0xFFFEF3C7),
        bannerDebugText: const Color(0xFF92400E),
        bannerInstrumentationBg: const Color(0xFFEDE9FE),
        bannerInstrumentationText: const Color(0xFF5B21B6),
        bannerSuccessBg: const Color(0xFFD1FAE5),
        bannerSuccessText: const Color(0xFF065F46),
        bannerWarningBg: const Color(0xFFFEF3C7),
        bannerWarningText: const Color(0xFF78350F),
        fixHintText: const Color(0xFF1D4ED8),
        disclaimerText: const Color(0xFF92400E),
        dimOverlay: const Color(0x22000000),
        shadow: const Color(0x33000000),
        gripDots: const Color(0xFF6B7280),
        checkboxActive: const Color(0xFF2563EB),
        triggerBadgeBg: const Color(0xFFE5E7EB),
        badgeFillAlpha: 1,
        focusRingWidth: 2,
        sourceAccentWidth: 5,
      );

  /// Maps a Material [ColorScheme] onto the overlay's surfaces and text.
  ///
  /// `surface` → [pageBackground], `surfaceContainer` → [cardBackground]
  /// (alpha 0xF5), `surfaceContainerHigh` → [sectionBackground],
  /// `surfaceContainerHighest` → [cardDefault], `onSurface` →
  /// [textPrimary], `onSurfaceVariant` → [textSecondary] and
  /// [textTertiary], `outline` → [textQuaternary], `outlineVariant` →
  /// [border], `primary` → [checkboxActive], [guideStepAccent] and
  /// [aiChatUserBubbleBg], `onPrimary` → [aiChatUserBubbleText],
  /// `primaryContainer` → [cardHighlighted], `errorContainer` →
  /// [cardJankFlash]. Every other token, including the severity, category,
  /// confidence and source colours, comes from [SleuthThemeData.dark] or
  /// [SleuthThemeData.light], whichever matches the brightness of
  /// `scheme.surface` (which also sets [brightness]).
  ///
  /// Each text token is checked against each surface for 4.5:1. When the
  /// scheme's text fails, `onSurfaceVariant` replaces `outline` for
  /// [textQuaternary]; when that fails too, the whole text group (primary
  /// to quaternary) comes from the preset whose brightness matches
  /// [pageBackground], so surfaces are never paired with text of the
  /// wrong brightness.
  ///
  /// Build the theme once and pass the same instance to
  /// `SleuthConfig.theme` or `Sleuth.updateTheme`: the overlay compares
  /// themes by identity, so a new instance on every build rebuilds every
  /// themed widget.
  factory SleuthThemeData.fromColorScheme(ColorScheme scheme) {
    final brightness = ThemeData.estimateBrightnessForColor(scheme.surface);
    final base = brightness == Brightness.dark
        ? const SleuthThemeData()
        : const SleuthThemeData.light();
    final surfaces = <Color>[
      scheme.surface,
      scheme.surfaceContainer,
      scheme.surfaceContainerHigh,
      scheme.surfaceContainerHighest,
      scheme.primaryContainer,
      scheme.errorContainer,
      base.aboutBackground,
      base.fixHintBackground,
    ];
    bool passes(List<Color> texts) => texts.every(
      (text) => surfaces.every((s) => contrastRatio(text, s) >= 4.5),
    );
    final candidates = <List<Color>>[
      [
        scheme.onSurface,
        scheme.onSurfaceVariant,
        scheme.onSurfaceVariant,
        scheme.outline,
      ],
      [
        scheme.onSurface,
        scheme.onSurfaceVariant,
        scheme.onSurfaceVariant,
        scheme.onSurfaceVariant,
      ],
    ];
    final text = candidates.firstWhere(
      passes,
      orElse: () => [
        base.textPrimary,
        base.textSecondary,
        base.textTertiary,
        base.textQuaternary,
      ],
    );
    return base.copyWith(
      brightness: brightness,

      pageBackground: scheme.surface,
      cardBackground: scheme.surfaceContainer.withAlpha(0xF5),
      sectionBackground: scheme.surfaceContainerHigh,
      cardDefault: scheme.surfaceContainerHighest,
      cardHighlighted: scheme.primaryContainer,
      cardJankFlash: scheme.errorContainer,
      border: scheme.outlineVariant,
      textPrimary: text[0],
      textSecondary: text[1],
      textTertiary: text[2],
      textQuaternary: text[3],
      checkboxActive: scheme.primary,
      guideStepAccent: scheme.primary,
      aiChatUserBubbleBg: scheme.primary,
      aiChatUserBubbleText: scheme.onPrimary,
    );
  }

  /// [SleuthThemeData.fromColorScheme] for `ColorScheme.fromSeed`.
  factory SleuthThemeData.fromSeed(
    Color seed, {
    Brightness brightness = Brightness.light,
  }) => SleuthThemeData.fromColorScheme(
    ColorScheme.fromSeed(seedColor: seed, brightness: brightness),
  );

  /// WCAG 2 contrast ratio of two opaque colours (1 to 21). Alpha is
  /// ignored.
  static double contrastRatio(Color a, Color b) {
    final la = a.withAlpha(0xFF).computeLuminance();
    final lb = b.withAlpha(0xFF).computeLuminance();
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// Whether this is a dark or a light theme. Picks the header toggle icon
  /// and the high-contrast variant.
  final Brightness brightness;

  // ── Severity text ──

  /// Critical-hued text on the card surfaces and on a critical tint.
  final Color severityCriticalText;

  /// Warning-hued text on the card surfaces and on a warning tint.
  final Color severityWarningText;

  /// OK-hued text on the card surfaces and on an OK tint.
  final Color severityOkText;

  // ── Accessibility ──

  /// Alpha of badge fills over their accent colour: 0.15, or 1 (opaque) in
  /// the high-contrast presets.
  final double badgeFillAlpha;

  /// Width of the focus ring drawn around focused overlay controls; 0
  /// draws none.
  final double focusRingWidth;

  /// Width of the source accent on the left edge of an issue card.
  final double sourceAccentWidth;

  /// Trigger icon colour on the warning and OK fills, where the white
  /// [triggerIconColor] lacks contrast.
  final Color triggerIconOnLightFill;

  // ── Severity ──
  final Color severityCritical;
  final Color severityWarning;
  final Color severityOk;

  // ── Category badges ──
  final Color categoryBuild;
  final Color categoryLayout;
  final Color categoryPaint;
  final Color categoryRaster;
  final Color categoryMemory;
  final Color categoryChannel;
  final Color categoryFont;
  final Color categoryNetwork;
  final Color categoryStartup;

  // ── Confidence ──
  final Color confidenceConfirmed;
  final Color confidenceLikely;
  final Color confidencePossible;

  // ── Source accents ──
  final Color sourceVmTimeline;
  final Color sourceDebugCallback;
  final Color sourceStructural;
  final Color sourceNone;

  // ── Fix effort ──
  final Color effortQuick;
  final Color effortMedium;
  final Color effortInvolved;

  // ── Surfaces ──
  final Color cardBackground;
  final Color pageBackground;
  final Color sectionBackground;
  final Color aboutBackground;
  final Color fixHintBackground;
  final Color border;
  final Color cardDefault;
  final Color cardHighlighted;
  final Color cardJankFlash;

  // ── Text hierarchy ──
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textQuaternary;
  final Color textSubtle;

  // ── Badge pairs ──
  final Color badgeVmBg;
  final Color badgeVmText;
  final Color badgeFrameBg;
  final Color badgeFrameText;
  final Color badgeDbgBg;
  final Color badgeDbgText;

  // ── Banner pairs ──
  final Color bannerDebugBg;
  final Color bannerDebugText;
  final Color bannerInstrumentationBg;
  final Color bannerInstrumentationText;
  final Color bannerSuccessBg;
  final Color bannerSuccessText;
  final Color bannerWarningBg;
  final Color bannerWarningText;

  // ── Causal graph ──
  final Color effectsBadge;

  // ── Special ──
  final Color fixHintText;
  final Color disclaimerText;
  final Color dimOverlay;
  final Color shadow;
  final Color gripDots;
  final Color checkboxActive;
  final Color triggerBadgeBg;
  final Color guideStepAccent;
  final Color guideTipIcon;
  final Color highlightLabelText;
  final Color highlightDot;
  final Color triggerIconColor;

  // ── AI Chat ──
  final Color aiChatUserBubbleBg;
  final Color aiChatUserBubbleText;

  // ── AI Shimmer (Ask AI link gradient) ──
  final Color aiShimmerStart;
  final Color aiShimmerMid;
  final Color aiShimmerEnd;

  // ── Spacing ──
  final double spacingXxs;
  final double spacingXs;
  final double spacingSm;
  final double spacingMd;
  final double spacingLg;
  final double spacingXl;

  // ── Typography scale ──
  final double fontXxs;
  final double fontXs;
  final double fontSm;
  final double fontMd;
  final double fontBase;
  final double fontLg;
  final double fontXl;
  final double fontXxl;
  final double fontDisplay;

  // ── Border radius scale ──
  final double radiusSm;
  final double radiusMd;
  final double radiusLg;
  final double radiusXl;
  final double radiusXxl;
  final double radiusCard;
  final double radiusFull;

  // ── Lookup helpers ──

  /// Returns the color for a given [IssueCategory].
  Color categoryColor(IssueCategory category) => switch (category) {
    IssueCategory.build => categoryBuild,
    IssueCategory.layout => categoryLayout,
    IssueCategory.paint => categoryPaint,
    IssueCategory.raster => categoryRaster,
    IssueCategory.memory => categoryMemory,
    IssueCategory.channel => categoryChannel,
    IssueCategory.font => categoryFont,
    IssueCategory.network => categoryNetwork,
    IssueCategory.startup => categoryStartup,
  };

  /// Returns the color for a given [IssueConfidence].
  Color confidenceColor(IssueConfidence confidence) => switch (confidence) {
    IssueConfidence.confirmed => confidenceConfirmed,
    IssueConfidence.likely => confidenceLikely,
    IssueConfidence.possible => confidencePossible,
  };

  /// Returns the left-border accent color for a given [ObservationSource].
  Color sourceAccentColor(ObservationSource? source) => switch (source) {
    ObservationSource.vmTimeline => sourceVmTimeline,
    // Measured timing, like the VM timeline; shares its accent.
    ObservationSource.frameTiming => sourceVmTimeline,
    ObservationSource.debugCallback => sourceDebugCallback,
    ObservationSource.debugCallbackAndStructural => sourceDebugCallback,
    ObservationSource.structural => sourceStructural,
    null => sourceNone,
  };

  /// Returns the color for a given [FixEffort].
  Color effortColor(FixEffort effort) => switch (effort) {
    FixEffort.quick => effortQuick,
    FixEffort.medium => effortMedium,
    FixEffort.involved => effortInvolved,
  };

  /// Returns green/amber/red based on [fps] relative to [target].
  Color fpsColor(double fps, {int target = 60}) {
    if (fps >= target * 0.83) return severityOk;
    if (fps >= target * 0.50) return severityWarning;
    return severityCritical;
  }

  /// [fpsColor] for text on the card surfaces: the severity text tokens.
  Color fpsTextColor(double fps, {int target = 60}) {
    if (fps >= target * 0.83) return severityOkText;
    if (fps >= target * 0.50) return severityWarningText;
    return severityCriticalText;
  }

  /// Accent colour of [severity].
  Color severityColor(IssueSeverity severity) => switch (severity) {
    IssueSeverity.critical => severityCritical,
    IssueSeverity.warning => severityWarning,
    IssueSeverity.ok => severityOk,
  };

  /// Severity text token of [severity].
  Color severityTextColor(IssueSeverity severity) => switch (severity) {
    IssueSeverity.critical => severityCriticalText,
    IssueSeverity.warning => severityWarningText,
    IssueSeverity.ok => severityOkText,
  };

  /// Badge fill for [accent]: the accent at [badgeFillAlpha].
  Color badgeFill(Color accent) => accent.withValues(alpha: badgeFillAlpha);

  /// Text colour for a badge filled with [badgeFill] of [accent]: [tinted]
  /// (default [textPrimary]) over a translucent tint; black or white,
  /// whichever contrasts more, over an opaque fill.
  Color badgeTextOn(Color accent, {Color? tinted}) {
    if (badgeFillAlpha < 1) return tinted ?? textPrimary;
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    return contrastRatio(black, accent) >= contrastRatio(white, accent)
        ? black
        : white;
  }

  /// Returns a copy with the specified fields overridden.
  ///
  /// Tip: when overriding badge or banner colors, always set both the `Bg`
  /// and `Text` tokens together (e.g. [badgeVmBg] + [badgeVmText]) to
  /// maintain contrast.
  SleuthThemeData copyWith({
    Brightness? brightness,
    Color? severityCritical,
    Color? severityWarning,
    Color? severityOk,
    Color? severityCriticalText,
    Color? severityWarningText,
    Color? severityOkText,
    Color? categoryBuild,
    Color? categoryLayout,
    Color? categoryPaint,
    Color? categoryRaster,
    Color? categoryMemory,
    Color? categoryChannel,
    Color? categoryFont,
    Color? categoryNetwork,
    Color? categoryStartup,
    Color? confidenceConfirmed,
    Color? confidenceLikely,
    Color? confidencePossible,
    Color? sourceVmTimeline,
    Color? sourceDebugCallback,
    Color? sourceStructural,
    Color? sourceNone,
    Color? effortQuick,
    Color? effortMedium,
    Color? effortInvolved,
    Color? cardBackground,
    Color? pageBackground,
    Color? sectionBackground,
    Color? aboutBackground,
    Color? fixHintBackground,
    Color? border,
    Color? cardDefault,
    Color? cardHighlighted,
    Color? cardJankFlash,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textQuaternary,
    Color? textSubtle,
    Color? badgeVmBg,
    Color? badgeVmText,
    Color? badgeFrameBg,
    Color? badgeFrameText,
    Color? badgeDbgBg,
    Color? badgeDbgText,
    Color? bannerDebugBg,
    Color? bannerDebugText,
    Color? bannerInstrumentationBg,
    Color? bannerInstrumentationText,
    Color? bannerSuccessBg,
    Color? bannerSuccessText,
    Color? bannerWarningBg,
    Color? bannerWarningText,
    Color? effectsBadge,
    Color? fixHintText,
    Color? disclaimerText,
    Color? dimOverlay,
    Color? shadow,
    Color? gripDots,
    Color? checkboxActive,
    Color? triggerBadgeBg,
    Color? guideStepAccent,
    Color? guideTipIcon,
    Color? highlightLabelText,
    Color? highlightDot,
    Color? triggerIconColor,
    double? badgeFillAlpha,
    double? focusRingWidth,
    double? sourceAccentWidth,
    Color? triggerIconOnLightFill,
    Color? aiChatUserBubbleBg,
    Color? aiChatUserBubbleText,
    Color? aiShimmerStart,
    Color? aiShimmerMid,
    Color? aiShimmerEnd,
    double? spacingXxs,
    double? spacingXs,
    double? spacingSm,
    double? spacingMd,
    double? spacingLg,
    double? spacingXl,
    double? fontXxs,
    double? fontXs,
    double? fontSm,
    double? fontMd,
    double? fontBase,
    double? fontLg,
    double? fontXl,
    double? fontXxl,
    double? fontDisplay,
    double? radiusSm,
    double? radiusMd,
    double? radiusLg,
    double? radiusXl,
    double? radiusXxl,
    double? radiusCard,
    double? radiusFull,
  }) {
    return SleuthThemeData(
      brightness: brightness ?? this.brightness,
      severityCritical: severityCritical ?? this.severityCritical,
      severityWarning: severityWarning ?? this.severityWarning,
      severityOk: severityOk ?? this.severityOk,
      severityCriticalText: severityCriticalText ?? this.severityCriticalText,
      severityWarningText: severityWarningText ?? this.severityWarningText,
      severityOkText: severityOkText ?? this.severityOkText,
      categoryBuild: categoryBuild ?? this.categoryBuild,
      categoryLayout: categoryLayout ?? this.categoryLayout,
      categoryPaint: categoryPaint ?? this.categoryPaint,
      categoryRaster: categoryRaster ?? this.categoryRaster,
      categoryMemory: categoryMemory ?? this.categoryMemory,
      categoryChannel: categoryChannel ?? this.categoryChannel,
      categoryFont: categoryFont ?? this.categoryFont,
      categoryNetwork: categoryNetwork ?? this.categoryNetwork,
      categoryStartup: categoryStartup ?? this.categoryStartup,
      confidenceConfirmed: confidenceConfirmed ?? this.confidenceConfirmed,
      confidenceLikely: confidenceLikely ?? this.confidenceLikely,
      confidencePossible: confidencePossible ?? this.confidencePossible,
      sourceVmTimeline: sourceVmTimeline ?? this.sourceVmTimeline,
      sourceDebugCallback: sourceDebugCallback ?? this.sourceDebugCallback,
      sourceStructural: sourceStructural ?? this.sourceStructural,
      sourceNone: sourceNone ?? this.sourceNone,
      effortQuick: effortQuick ?? this.effortQuick,
      effortMedium: effortMedium ?? this.effortMedium,
      effortInvolved: effortInvolved ?? this.effortInvolved,
      cardBackground: cardBackground ?? this.cardBackground,
      pageBackground: pageBackground ?? this.pageBackground,
      sectionBackground: sectionBackground ?? this.sectionBackground,
      aboutBackground: aboutBackground ?? this.aboutBackground,
      fixHintBackground: fixHintBackground ?? this.fixHintBackground,
      border: border ?? this.border,
      cardDefault: cardDefault ?? this.cardDefault,
      cardHighlighted: cardHighlighted ?? this.cardHighlighted,
      cardJankFlash: cardJankFlash ?? this.cardJankFlash,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      textQuaternary: textQuaternary ?? this.textQuaternary,
      textSubtle: textSubtle ?? this.textSubtle,
      badgeVmBg: badgeVmBg ?? this.badgeVmBg,
      badgeVmText: badgeVmText ?? this.badgeVmText,
      badgeFrameBg: badgeFrameBg ?? this.badgeFrameBg,
      badgeFrameText: badgeFrameText ?? this.badgeFrameText,
      badgeDbgBg: badgeDbgBg ?? this.badgeDbgBg,
      badgeDbgText: badgeDbgText ?? this.badgeDbgText,
      bannerDebugBg: bannerDebugBg ?? this.bannerDebugBg,
      bannerDebugText: bannerDebugText ?? this.bannerDebugText,
      bannerInstrumentationBg:
          bannerInstrumentationBg ?? this.bannerInstrumentationBg,
      bannerInstrumentationText:
          bannerInstrumentationText ?? this.bannerInstrumentationText,
      bannerSuccessBg: bannerSuccessBg ?? this.bannerSuccessBg,
      bannerSuccessText: bannerSuccessText ?? this.bannerSuccessText,
      bannerWarningBg: bannerWarningBg ?? this.bannerWarningBg,
      bannerWarningText: bannerWarningText ?? this.bannerWarningText,
      effectsBadge: effectsBadge ?? this.effectsBadge,
      fixHintText: fixHintText ?? this.fixHintText,
      disclaimerText: disclaimerText ?? this.disclaimerText,
      dimOverlay: dimOverlay ?? this.dimOverlay,
      shadow: shadow ?? this.shadow,
      gripDots: gripDots ?? this.gripDots,
      checkboxActive: checkboxActive ?? this.checkboxActive,
      triggerBadgeBg: triggerBadgeBg ?? this.triggerBadgeBg,
      guideStepAccent: guideStepAccent ?? this.guideStepAccent,
      guideTipIcon: guideTipIcon ?? this.guideTipIcon,
      highlightLabelText: highlightLabelText ?? this.highlightLabelText,
      highlightDot: highlightDot ?? this.highlightDot,
      triggerIconColor: triggerIconColor ?? this.triggerIconColor,
      badgeFillAlpha: badgeFillAlpha ?? this.badgeFillAlpha,
      focusRingWidth: focusRingWidth ?? this.focusRingWidth,
      sourceAccentWidth: sourceAccentWidth ?? this.sourceAccentWidth,
      triggerIconOnLightFill:
          triggerIconOnLightFill ?? this.triggerIconOnLightFill,

      aiChatUserBubbleBg: aiChatUserBubbleBg ?? this.aiChatUserBubbleBg,
      aiChatUserBubbleText: aiChatUserBubbleText ?? this.aiChatUserBubbleText,
      aiShimmerStart: aiShimmerStart ?? this.aiShimmerStart,
      aiShimmerMid: aiShimmerMid ?? this.aiShimmerMid,
      aiShimmerEnd: aiShimmerEnd ?? this.aiShimmerEnd,
      spacingXxs: spacingXxs ?? this.spacingXxs,
      spacingXs: spacingXs ?? this.spacingXs,
      spacingSm: spacingSm ?? this.spacingSm,
      spacingMd: spacingMd ?? this.spacingMd,
      spacingLg: spacingLg ?? this.spacingLg,
      spacingXl: spacingXl ?? this.spacingXl,
      fontXxs: fontXxs ?? this.fontXxs,
      fontXs: fontXs ?? this.fontXs,
      fontSm: fontSm ?? this.fontSm,
      fontMd: fontMd ?? this.fontMd,
      fontBase: fontBase ?? this.fontBase,
      fontLg: fontLg ?? this.fontLg,
      fontXl: fontXl ?? this.fontXl,
      fontXxl: fontXxl ?? this.fontXxl,
      fontDisplay: fontDisplay ?? this.fontDisplay,
      radiusSm: radiusSm ?? this.radiusSm,
      radiusMd: radiusMd ?? this.radiusMd,
      radiusLg: radiusLg ?? this.radiusLg,
      radiusXl: radiusXl ?? this.radiusXl,
      radiusXxl: radiusXxl ?? this.radiusXxl,
      radiusCard: radiusCard ?? this.radiusCard,
      radiusFull: radiusFull ?? this.radiusFull,
    );
  }
}

/// Provides [SleuthThemeData] to overlay widgets via the widget tree.
///
/// Package-internal — consumers configure theming via [SleuthConfig.theme],
/// not by placing this widget themselves.
class SleuthTheme extends InheritedWidget {
  const SleuthTheme({super.key, required this.data, required super.child});

  final SleuthThemeData data;

  /// Returns the nearest [SleuthThemeData], or dark defaults if none exists.
  ///
  /// The dark fallback ensures existing tests (which render widgets without
  /// a [SleuthTheme] ancestor) continue to see the same colors.
  static SleuthThemeData of(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<SleuthTheme>()?.data ??
        const SleuthThemeData();
  }

  @override
  bool updateShouldNotify(SleuthTheme oldWidget) =>
      !identical(data, oldWidget.data);
}
