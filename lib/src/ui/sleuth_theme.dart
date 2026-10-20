import 'package:flutter/material.dart' show Brightness, ColorScheme, ThemeData;
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
/// - **Severity graphics** (3, optional): borders, icons and dots
///   ([severityGraphicColor]); the dark default uses the severity fills,
///   the light preset mid-tone shades, the high-contrast presets and
///   [SleuthThemeData.fromColorScheme] the severity text
/// - **Category badges** (9): one per [IssueCategory], `categoryBuild` etc.
/// - **Surfaces** (7, plus the optional card divider): backgrounds, borders
///   and card states
/// - **Text hierarchy** (5): `textPrimary` through `textSubtle`
/// - **Badge pair** (2): `badgeDbgBg` and `badgeDbgText` for the Debug
///   timing tag
/// - **Banner pairs** (6): bg + text for debug, success and warning
/// - **Special** (9): grip dots, guide accents, trigger and highlight
///   colours
/// - **AI chat** (2): the user bubble's fill and text
/// - **Spacing** (6): `spacingXxs` through `spacingXl`
/// - **Typography** (7): `fontXxs` (10) through `fontXl` (16); 10 px is
///   the smallest size the overlay draws
/// - **Border radius** (7): `radiusSm` (4) through `radiusFull` (20)
/// - **Accessibility** (2): `badgeFillAlpha`, `triggerIconOnLightFill`
///
/// ## Presets
///
/// - [SleuthThemeData.new] / [SleuthThemeData.dark] and
///   [SleuthThemeData.light]: the default dark and light themes.
/// - [SleuthThemeData.highContrastDark] and
///   [SleuthThemeData.highContrastLight]: chosen automatically when the
///   platform reports high contrast and no theme is set.
/// - [SleuthThemeData.fromColorScheme] and [SleuthThemeData.fromSeed]:
///   surfaces and text from a Material [ColorScheme]; severity and category
///   colours stay Sleuth's.
///
/// Text tokens meet WCAG AA (4.5:1) on every surface token in all four
/// presets. Badges draw [textPrimary] on a [badgeFillAlpha] tint of their
/// accent with a 1 px accent border; severity badges use the severity text
/// tokens. With opaque fills (`badgeFillAlpha == 1`, the high-contrast
/// presets) badge text is black or white, whichever contrasts more.
///
/// ## Badge and banner pairs
///
/// Tokens like [badgeDbgBg]/[badgeDbgText] are designed as contrast pairs.
/// When overriding, always set both bg and text together to maintain
/// readability.
///
/// ## Design principles
///
/// The [light] constructor inverts surfaces and text while keeping semantic
/// accent colors (severity, category) unchanged — their meaning comes from
/// hue, which should be consistent across themes.
class SleuthThemeData {
  /// Dark theme — matches every original hardcoded color exactly.
  ///
  /// **Palette note:** Several semantic tokens share the same default hex
  /// value (e.g. `severityOk` and `categoryPaint` are both `0xFF10B981`
  /// green). Each token is independently overridable via [copyWith], so
  /// changing one does not affect the others.
  const SleuthThemeData({
    this.brightness = Brightness.dark,

    // ── Severity (also used for FPS) ──
    // Note: the severity palette overlaps with the category colours by
    // design: red/amber/green carries the same meaning everywhere.
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

    // ── Surfaces ──
    this.cardBackground = const Color(0xFF1E1E2E),
    this.pageBackground = const Color(0xFF1E1E2E),
    this.sectionBackground = const Color(0xFF252536),
    this.fixHintBackground = const Color(0xFF1F2937),
    this.border = const Color(0xFF374151),
    this.cardDefault = const Color(0xFF374151),
    this.cardHighlighted = const Color(0xFF1E3A5F),

    // ── Text hierarchy ──
    this.textPrimary = const Color(0xFFFFFFFF),
    this.textSecondary = const Color(0xFFD1D5DB),
    this.textTertiary = const Color(0xFFB4BAC4),
    this.textQuaternary = const Color(0xFFA8AFBA),
    this.textSubtle = const Color(0xFF4B5563),

    // ── Badge pairs ──
    this.badgeDbgBg = const Color(0xFF5B21B6),
    this.badgeDbgText = const Color(0xFFC4B5FD),

    // ── Banner pairs ──
    this.bannerDebugBg = const Color(0xFF92400E),
    this.bannerDebugText = const Color(0xFFFCD34D),
    this.bannerSuccessBg = const Color(0xFF065F46),
    this.bannerSuccessText = const Color(0xFF6EE7B7),
    this.bannerWarningBg = const Color(0xFF78350F),
    this.bannerWarningText = const Color(0xFFFCD34D),

    // ── Special ──
    this.dimOverlay = const Color(0x44000000),
    this.shadow = const Color(0xCC000000),
    this.gripDots = const Color(0xFF9CA3AF),
    this.checkboxActive = const Color(0xFF60A5FA),
    this.triggerBadgeBg = const Color(0xFF1F2937),
    this.guideStepAccent = const Color(0xFF3B82F6),
    this.guideTipIcon = const Color(0xFFF59E0B),
    this.highlightDot = const Color(0xFFFFFFFF),
    this.triggerIconColor = const Color(0xFFFFFFFF),

    // ── Accessibility ──
    this.badgeFillAlpha = 0.15,
    this.triggerIconOnLightFill = const Color(0xFF111827),

    // ── AI Chat ──
    this.aiChatUserBubbleBg = const Color(0xFF2563EB),
    this.aiChatUserBubbleText = const Color(0xFFFFFFFF),

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

    // ── Border radius scale ──
    this.radiusSm = 4,
    this.radiusMd = 6,
    this.radiusLg = 8,
    this.radiusXl = 10,
    this.radiusXxl = 12,
    this.radiusCard = 16,
    this.radiusFull = 20,
    Color? cardDivider,
    // The severity fills, as on dark surfaces they keep 3:1 and read
    // brighter than the pale text shades.
    Color? severityCriticalGraphic = const Color(0xFFEF4444),
    Color? severityWarningGraphic = const Color(0xFFF59E0B),
    Color? severityOkGraphic = const Color(0xFF10B981),
  }) : _cardDivider = cardDivider,
       _severityCriticalGraphic = severityCriticalGraphic,
       _severityWarningGraphic = severityWarningGraphic,
       _severityOkGraphic = severityOkGraphic;

  /// Explicit dark theme — identical to the default constructor.
  ///
  /// Provided for readability when you want to make the dark choice visible:
  /// `SleuthConfig(theme: SleuthThemeData.dark())`.
  const SleuthThemeData.dark() : this();

  /// Light theme for light-background apps.
  ///
  /// Inverts surfaces (dark → white/light gray) and text (white → near-black)
  /// while keeping the severity and category accents identical. Badge and
  /// banner pairs are swapped (dark bg + light text → light bg + dark
  /// text).
  ///
  /// Tokens not overridden here keep their dark-theme values. Among them
  /// [guideStepAccent] fills the guide's step circles, whose numbers are
  /// black or white by contrast ([onColor]), and [guideTipIcon] colours
  /// the guide's tip icons, which sit beside the tip text and carry no
  /// meaning of their own.
  const SleuthThemeData.light()
    : this(
        brightness: Brightness.light,
        // Source accents (deeper, for the light cards)
        // Surfaces
        cardBackground: const Color(0xFFFFFFFF),
        pageBackground: const Color(0xFFF9FAFB),
        sectionBackground: const Color(0xFFF3F4F6),
        fixHintBackground: const Color(0xFFEFF6FF),
        border: const Color(0xFFD1D5DB),
        cardDefault: const Color(0xFFE5E7EB),
        cardHighlighted: const Color(0xFFDBEAFE),
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
        // Borders, icons and dots: one shade lighter than the text, so
        // critical, warning and OK read as red, orange and green.
        severityCriticalGraphic: const Color(0xFFDC2626),
        severityWarningGraphic: const Color(0xFFD97706),
        severityOkGraphic: const Color(0xFF059669),
        // Badge pairs (inverted: light bg, dark text)
        badgeDbgBg: const Color(0xFFEDE9FE),
        badgeDbgText: const Color(0xFF5B21B6),
        // Banner pairs (inverted)
        bannerDebugBg: const Color(0xFFFEF3C7),
        bannerDebugText: const Color(0xFF92400E),
        bannerSuccessBg: const Color(0xFFD1FAE5),
        bannerSuccessText: const Color(0xFF065F46),
        bannerWarningBg: const Color(0xFFFEF3C7),
        bannerWarningText: const Color(0xFF78350F),
        // Special (contrast-appropriate for light bg)
        dimOverlay: const Color(0x22000000),
        shadow: const Color(0x33000000),
        gripDots: const Color(0xFF6B7280),
        checkboxActive: const Color(0xFF2563EB),
        triggerBadgeBg: const Color(0xFFE5E7EB),
      );

  /// High-contrast dark theme.
  ///
  /// The dark theme with tertiary and quaternary text raised to
  /// [textSecondary], stronger borders and the card divider, opaque badge
  /// fills, and severity graphics in the severity text shades. Chosen
  /// automatically when the
  /// platform reports high contrast (`MediaQuery.highContrastOf`, iOS
  /// Increase Contrast) in dark mode and no theme is set; pass it to
  /// `Sleuth.updateTheme` on other platforms.
  const SleuthThemeData.highContrastDark()
    : this(
        textTertiary: const Color(0xFFD1D5DB),
        textQuaternary: const Color(0xFFD1D5DB),
        border: const Color(0xFF9CA3AF),
        cardDivider: const Color(0xFF9CA3AF),
        badgeFillAlpha: 1,
        // Borders, icons and dots take the lighter text shades.
        severityCriticalGraphic: null,
        severityWarningGraphic: null,
        severityOkGraphic: null,
      );

  /// High-contrast light theme. See [SleuthThemeData.highContrastDark].
  const SleuthThemeData.highContrastLight()
    : this(
        brightness: Brightness.light,
        cardBackground: const Color(0xFFFFFFFF),
        pageBackground: const Color(0xFFF9FAFB),
        sectionBackground: const Color(0xFFF3F4F6),
        fixHintBackground: const Color(0xFFEFF6FF),
        border: const Color(0xFF6B7280),
        cardDivider: const Color(0xFF6B7280),
        cardDefault: const Color(0xFFE5E7EB),
        cardHighlighted: const Color(0xFFDBEAFE),
        textPrimary: const Color(0xFF111827),
        textSecondary: const Color(0xFF374151),
        textTertiary: const Color(0xFF374151),
        textQuaternary: const Color(0xFF374151),
        textSubtle: const Color(0xFFD1D5DB),
        severityCriticalText: const Color(0xFF991B1B),
        severityWarningText: const Color(0xFF92400E),
        severityOkText: const Color(0xFF065F46),
        severityCriticalGraphic: null,
        severityWarningGraphic: null,
        severityOkGraphic: null,
        badgeDbgBg: const Color(0xFFEDE9FE),
        badgeDbgText: const Color(0xFF5B21B6),
        bannerDebugBg: const Color(0xFFFEF3C7),
        bannerDebugText: const Color(0xFF92400E),
        bannerSuccessBg: const Color(0xFFD1FAE5),
        bannerSuccessText: const Color(0xFF065F46),
        bannerWarningBg: const Color(0xFFFEF3C7),
        bannerWarningText: const Color(0xFF78350F),
        dimOverlay: const Color(0x22000000),
        shadow: const Color(0x33000000),
        gripDots: const Color(0xFF6B7280),
        checkboxActive: const Color(0xFF2563EB),
        triggerBadgeBg: const Color(0xFFE5E7EB),
        badgeFillAlpha: 1,
      );

  /// Maps a Material [ColorScheme] onto the overlay's surfaces and text.
  ///
  /// `surface` → [pageBackground], `surfaceContainer` → [cardBackground]
  /// (opaque), `surfaceContainerHigh` → [sectionBackground],
  /// `surfaceContainerHighest` → [cardDefault], `onSurface` →
  /// [textPrimary], `onSurfaceVariant` → [textSecondary] and
  /// [textTertiary], `outline` → [textQuaternary], `outlineVariant` →
  /// [border] and [cardDivider], `primary` → [checkboxActive], [guideStepAccent] and
  /// [aiChatUserBubbleBg], `onPrimary` → [aiChatUserBubbleText],
  /// `primaryContainer` → [cardHighlighted]. Every other token, including
  /// the severity and category colours, comes from [SleuthThemeData.dark] or
  /// [SleuthThemeData.light], whichever matches the brightness of
  /// `scheme.surface` (which also sets [brightness]).
  ///
  /// Every pair the overlay draws on a surface is checked: text and
  /// severity text at 4.5:1 (on [cardBackground], also blended over a black
  /// and a white host for a custom translucent card) and badges over their
  /// tint. The text group (primary to quaternary) is tried in order: the
  /// scheme's, the scheme's with `onSurfaceVariant` for [textQuaternary],
  /// then the preset's. With each, a scheme surface that fails takes the
  /// preset's value instead, and the group is kept only when every pair
  /// then passes, so a surface and the text drawn on it fall back
  /// together. The preset text always passes on the preset surfaces.
  /// [checkboxActive] falls back to the preset's, then to [textPrimary];
  /// the chat bubble pair falls back to the preset's when `onPrimary` on
  /// `primary` is below 4.5:1.
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
    final textGroups = <List<Color>>[
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
      [
        base.textPrimary,
        base.textSecondary,
        base.textTertiary,
        base.textQuaternary,
      ],
    ];
    for (final text in textGroups) {
      final surfaces = <_SchemeSurface, Color>{
        _SchemeSurface.page: scheme.surface,
        _SchemeSurface.card: scheme.surfaceContainer.withAlpha(0xFF),
        _SchemeSurface.section: scheme.surfaceContainerHigh,
        _SchemeSurface.cardDefault: scheme.surfaceContainerHighest,
        _SchemeSurface.highlighted: scheme.primaryContainer,
      };
      SleuthThemeData build() => base.copyWith(
        brightness: brightness,
        // A scheme's tinted surfaces can take the light preset's
        // mid-tone graphics below 3:1; the text shades hold on any of them.
        severityCriticalGraphic: base.severityCriticalText,
        severityWarningGraphic: base.severityWarningText,
        severityOkGraphic: base.severityOkText,
        pageBackground: surfaces[_SchemeSurface.page],
        cardBackground: surfaces[_SchemeSurface.card],
        sectionBackground: surfaces[_SchemeSurface.section],
        cardDefault: surfaces[_SchemeSurface.cardDefault],
        cardHighlighted: surfaces[_SchemeSurface.highlighted],
        border: scheme.outlineVariant,
        cardDivider: scheme.outlineVariant,
        textPrimary: text[0],
        textSecondary: text[1],
        textTertiary: text[2],
        textQuaternary: text[3],
        guideStepAccent: scheme.primary,
      );
      var theme = build();
      var failing = theme._unreadableSurfaces();
      // A pair on a preset surface (the about and fix-hint boxes, the
      // trigger badge) fails: only other text can fix it.
      if (failing.contains(null)) continue;
      if (failing.isNotEmpty) {
        for (final surface in failing) {
          surfaces[surface!] = base._surface(surface);
        }
        theme = build();
        failing = theme._unreadableSurfaces();
        if (failing.isNotEmpty) continue;
      }
      return theme._withSchemeAccents(scheme, base);
    }
    // Not reached: the preset text passes on every preset surface.
    return base.copyWith(brightness: brightness);
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

  /// Whether this is a dark or a light theme: the presets set it to match
  /// their surfaces and [SleuthThemeData.fromColorScheme] to the scheme's
  /// surface. Descriptive only; the overlay reads nothing from it. The
  /// header toggle icon follows the stored theme mode, and the
  /// high-contrast preset is picked from that mode or the platform
  /// brightness.
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

  // ── Surfaces ──
  final Color cardBackground;
  final Color pageBackground;
  final Color sectionBackground;
  final Color fixHintBackground;
  final Color border;
  final Color cardDefault;
  final Color cardHighlighted;

  /// Line between the card's sections. In the dark preset [border] equals
  /// [cardDefault], so a divider drawn in [border] vanishes against a
  /// card; this token stays visible. When not set it is 0xFF4B5563 for a
  /// dark [brightness] and 0xFFB4BAC4 for a light one.
  Color get cardDivider =>
      _cardDivider ??
      (brightness == Brightness.dark
          ? const Color(0xFF4B5563)
          : const Color(0xFFB4BAC4));
  final Color? _cardDivider;

  // ── Text hierarchy ──
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final Color textQuaternary;
  final Color textSubtle;

  // ── Badge pairs ──

  /// Fill of the Debug timing tag on timing issues in debug runs.
  final Color badgeDbgBg;

  /// Text of the Debug timing tag, on [badgeDbgBg].
  final Color badgeDbgText;

  // ── Banner pairs ──
  final Color bannerDebugBg;
  final Color bannerDebugText;
  final Color bannerSuccessBg;
  final Color bannerSuccessText;
  final Color bannerWarningBg;
  final Color bannerWarningText;

  // ── Special ──

  final Color dimOverlay;
  final Color shadow;
  final Color gripDots;
  final Color checkboxActive;
  final Color triggerBadgeBg;
  final Color guideStepAccent;
  final Color guideTipIcon;

  final Color highlightDot;
  final Color triggerIconColor;

  // ── AI Chat ──
  final Color aiChatUserBubbleBg;
  final Color aiChatUserBubbleText;

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

  /// Colour of [severity] for borders, icons and dots, which need 3:1
  /// against the card where text needs 4.5:1. The dark default uses the
  /// severity fills and the light preset mid-tone shades, as its text
  /// shades are too dark to tell red from orange; without one set, the
  /// severity text colour.
  Color severityGraphicColor(IssueSeverity severity) =>
      switch (severity) {
        IssueSeverity.critical => _severityCriticalGraphic,
        IssueSeverity.warning => _severityWarningGraphic,
        IssueSeverity.ok => _severityOkGraphic,
      } ??
      severityTextColor(severity);
  final Color? _severityCriticalGraphic;
  final Color? _severityWarningGraphic;
  final Color? _severityOkGraphic;

  /// Badge fill for [accent]: the accent at [badgeFillAlpha].
  Color badgeFill(Color accent) => accent.withValues(alpha: badgeFillAlpha);

  /// Text colour for a badge filled with [badgeFill] of [accent]: [tinted]
  /// (default [textPrimary]) over a translucent tint; black or white,
  /// whichever contrasts more, over an opaque fill.
  Color badgeTextOn(Color accent, {Color? tinted}) {
    if (badgeFillAlpha < 1) return tinted ?? textPrimary;
    return onColor(accent);
  }

  /// Black or white, whichever contrasts more with the opaque [fill]
  /// (at least 4.58:1 for any colour).
  static Color onColor(Color fill) {
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    return contrastRatio(black, fill) >= contrastRatio(white, fill)
        ? black
        : white;
  }

  /// This theme's value for [surface].
  Color _surface(_SchemeSurface surface) => switch (surface) {
    _SchemeSurface.page => pageBackground,
    _SchemeSurface.card => cardBackground,
    _SchemeSurface.section => sectionBackground,
    _SchemeSurface.cardDefault => cardDefault,
    _SchemeSurface.highlighted => cardHighlighted,
  };

  /// Surfaces with a pair below its minimum, as checked by
  /// [SleuthThemeData.fromColorScheme]; null stands for a pair on a
  /// surface the scheme does not set.
  Set<_SchemeSurface?> _unreadableSurfaces() {
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    final failing = <_SchemeSurface?>{};
    void check(_SchemeSurface? on, Color fg, Color bg, [double min = 4.5]) {
      if (contrastRatio(fg, bg) < min) failing.add(on);
    }

    final texts = [
      textPrimary,
      textSecondary,
      textTertiary,
      textQuaternary,
      severityCriticalText,
      severityWarningText,
      severityOkText,
    ];
    final cardOverBlack = Color.alphaBlend(cardBackground, black);
    final cardOverWhite = Color.alphaBlend(cardBackground, white);
    final surfaces = <(_SchemeSurface?, Color)>[
      (_SchemeSurface.page, pageBackground),
      (_SchemeSurface.card, cardOverBlack),
      (_SchemeSurface.card, cardOverWhite),
      (_SchemeSurface.section, sectionBackground),
      (_SchemeSurface.cardDefault, cardDefault),
      (_SchemeSurface.highlighted, cardHighlighted),
      (null, fixHintBackground),
    ];
    for (final (on, bg) in surfaces) {
      for (final fg in texts) {
        check(on, fg, bg);
      }
    }
    // Trigger: the issue count, the FPS number and its warm-up dash.
    for (final fg in [textPrimary, textTertiary, ...texts.skip(4)]) {
      check(null, fg, triggerBadgeBg);
    }
    // Severity badges: severity text over the severity tint.
    for (final severity in IssueSeverity.values) {
      final accent = severityColor(severity);
      final fg = badgeTextOn(accent, tinted: severityTextColor(severity));
      for (final (on, bg) in [
        (_SchemeSurface.cardDefault, cardDefault),
        (_SchemeSurface.highlighted, cardHighlighted),
        (_SchemeSurface.card, cardOverBlack),
      ]) {
        check(on, fg, Color.alphaBlend(badgeFill(accent), bg));
      }
    }
    // Category badges.
    for (final c in IssueCategory.values) {
      final accent = categoryColor(c);
      for (final (on, bg) in <(_SchemeSurface?, Color)>[
        (_SchemeSurface.cardDefault, cardDefault),
        (_SchemeSurface.highlighted, cardHighlighted),
        (null, fixHintBackground),
      ]) {
        check(on, badgeTextOn(accent), Color.alphaBlend(badgeFill(accent), bg));
      }
    }
    // Rebuild-stats icons on the build-tinted banner.
    for (final bg in [cardOverBlack, cardOverWhite]) {
      final banner = Color.alphaBlend(categoryBuild.withValues(alpha: 0.1), bg);
      check(_SchemeSurface.card, textSecondary, banner, 3);
    }
    return failing;
  }

  /// This theme with the scheme's [checkboxActive] and chat bubble pair
  /// where they are readable on its surfaces, else [preset]'s, else
  /// [textPrimary] for [checkboxActive].
  SleuthThemeData _withSchemeAccents(
    ColorScheme scheme,
    SleuthThemeData preset,
  ) {
    const black = Color(0xFF000000);
    const white = Color(0xFFFFFFFF);
    bool readable(Color c) =>
        contrastRatio(c, pageBackground) >= 4.5 &&
        contrastRatio(c, Color.alphaBlend(cardBackground, black)) >= 4.5 &&
        contrastRatio(c, Color.alphaBlend(cardBackground, white)) >= 4.5 &&
        contrastRatio(c, cardDefault) >= 3;
    final bubble = contrastRatio(scheme.onPrimary, scheme.primary) >= 4.5;
    return copyWith(
      checkboxActive: [
        scheme.primary,
        preset.checkboxActive,
      ].firstWhere(readable, orElse: () => textPrimary),
      aiChatUserBubbleBg: bubble ? scheme.primary : preset.aiChatUserBubbleBg,
      aiChatUserBubbleText: bubble
          ? scheme.onPrimary
          : preset.aiChatUserBubbleText,
    );
  }

  /// Returns a copy with the specified fields overridden.
  ///
  /// Tip: when overriding badge or banner colors, always set both the `Bg`
  /// and `Text` tokens together (e.g. [bannerDebugBg] + [bannerDebugText]) to
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
    Color? cardBackground,
    Color? cardDivider,
    Color? severityCriticalGraphic,
    Color? severityWarningGraphic,
    Color? severityOkGraphic,
    Color? pageBackground,
    Color? sectionBackground,
    Color? fixHintBackground,
    Color? border,
    Color? cardDefault,
    Color? cardHighlighted,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? textQuaternary,
    Color? textSubtle,
    Color? badgeDbgBg,
    Color? badgeDbgText,
    Color? bannerDebugBg,
    Color? bannerDebugText,
    Color? bannerSuccessBg,
    Color? bannerSuccessText,
    Color? bannerWarningBg,
    Color? bannerWarningText,
    Color? dimOverlay,
    Color? shadow,
    Color? gripDots,
    Color? checkboxActive,
    Color? triggerBadgeBg,
    Color? guideStepAccent,
    Color? guideTipIcon,
    Color? highlightDot,
    Color? triggerIconColor,
    double? badgeFillAlpha,
    Color? triggerIconOnLightFill,
    Color? aiChatUserBubbleBg,
    Color? aiChatUserBubbleText,
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
      cardBackground: cardBackground ?? this.cardBackground,
      cardDivider: cardDivider ?? _cardDivider,
      severityCriticalGraphic:
          severityCriticalGraphic ?? _severityCriticalGraphic,
      severityWarningGraphic: severityWarningGraphic ?? _severityWarningGraphic,
      severityOkGraphic: severityOkGraphic ?? _severityOkGraphic,
      pageBackground: pageBackground ?? this.pageBackground,
      sectionBackground: sectionBackground ?? this.sectionBackground,
      fixHintBackground: fixHintBackground ?? this.fixHintBackground,
      border: border ?? this.border,
      cardDefault: cardDefault ?? this.cardDefault,
      cardHighlighted: cardHighlighted ?? this.cardHighlighted,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      textQuaternary: textQuaternary ?? this.textQuaternary,
      textSubtle: textSubtle ?? this.textSubtle,
      badgeDbgBg: badgeDbgBg ?? this.badgeDbgBg,
      badgeDbgText: badgeDbgText ?? this.badgeDbgText,
      bannerDebugBg: bannerDebugBg ?? this.bannerDebugBg,
      bannerDebugText: bannerDebugText ?? this.bannerDebugText,
      bannerSuccessBg: bannerSuccessBg ?? this.bannerSuccessBg,
      bannerSuccessText: bannerSuccessText ?? this.bannerSuccessText,
      bannerWarningBg: bannerWarningBg ?? this.bannerWarningBg,
      bannerWarningText: bannerWarningText ?? this.bannerWarningText,
      dimOverlay: dimOverlay ?? this.dimOverlay,
      shadow: shadow ?? this.shadow,
      gripDots: gripDots ?? this.gripDots,
      checkboxActive: checkboxActive ?? this.checkboxActive,
      triggerBadgeBg: triggerBadgeBg ?? this.triggerBadgeBg,
      guideStepAccent: guideStepAccent ?? this.guideStepAccent,
      guideTipIcon: guideTipIcon ?? this.guideTipIcon,
      highlightDot: highlightDot ?? this.highlightDot,
      triggerIconColor: triggerIconColor ?? this.triggerIconColor,
      badgeFillAlpha: badgeFillAlpha ?? this.badgeFillAlpha,
      triggerIconOnLightFill:
          triggerIconOnLightFill ?? this.triggerIconOnLightFill,

      aiChatUserBubbleBg: aiChatUserBubbleBg ?? this.aiChatUserBubbleBg,
      aiChatUserBubbleText: aiChatUserBubbleText ?? this.aiChatUserBubbleText,
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

/// A surface [SleuthThemeData.fromColorScheme] takes from the scheme.
enum _SchemeSurface { page, card, section, cardDefault, highlighted }

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
