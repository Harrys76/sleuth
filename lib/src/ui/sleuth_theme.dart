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
/// - **Special** (11): fix hint text, grip dots, guide accents, etc.
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
  const SleuthThemeData({
    // ── Severity (also used for FPS) ──
    this.severityCritical = const Color(0xFFEF4444),
    this.severityWarning = const Color(0xFFF59E0B),
    this.severityOk = const Color(0xFF10B981),

    // ── Category badges ──
    this.categoryBuild = const Color(0xFF3B82F6),
    this.categoryLayout = const Color(0xFFF59E0B),
    this.categoryPaint = const Color(0xFF10B981),
    this.categoryRaster = const Color(0xFFEF4444),
    this.categoryMemory = const Color(0xFF8B5CF6),
    this.categoryChannel = const Color(0xFF06B6D4),
    this.categoryFont = const Color(0xFF6B7280),
    this.categoryNetwork = const Color(0xFFF97316),

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
    this.textTertiary = const Color(0xFF9CA3AF),
    this.textQuaternary = const Color(0xFF6B7280),
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
    this.checkboxActive = const Color(0xFF3B82F6),
    this.triggerBadgeBg = const Color(0xFF1F2937),
    this.guideStepAccent = const Color(0xFF3B82F6),
    this.guideTipIcon = const Color(0xFFF59E0B),
    this.highlightLabelText = const Color(0xFFFFFFFF),
    this.highlightDot = const Color(0xFFFFFFFF),

    // ── AI Chat ──
    this.aiChatUserBubbleBg = const Color(0xFF3B82F6),
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
          textTertiary: const Color(0xFF6B7280),
          textQuaternary: const Color(0xFF9CA3AF),
          textSubtle: const Color(0xFFD1D5DB),
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
          triggerBadgeBg: const Color(0xFFE5E7EB),
        );

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

  /// Returns a copy with the specified fields overridden.
  ///
  /// Tip: when overriding badge or banner colors, always set both the `Bg`
  /// and `Text` tokens together (e.g. [badgeVmBg] + [badgeVmText]) to
  /// maintain contrast.
  SleuthThemeData copyWith({
    Color? severityCritical,
    Color? severityWarning,
    Color? severityOk,
    Color? categoryBuild,
    Color? categoryLayout,
    Color? categoryPaint,
    Color? categoryRaster,
    Color? categoryMemory,
    Color? categoryChannel,
    Color? categoryFont,
    Color? categoryNetwork,
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
  }) {
    return SleuthThemeData(
      severityCritical: severityCritical ?? this.severityCritical,
      severityWarning: severityWarning ?? this.severityWarning,
      severityOk: severityOk ?? this.severityOk,
      categoryBuild: categoryBuild ?? this.categoryBuild,
      categoryLayout: categoryLayout ?? this.categoryLayout,
      categoryPaint: categoryPaint ?? this.categoryPaint,
      categoryRaster: categoryRaster ?? this.categoryRaster,
      categoryMemory: categoryMemory ?? this.categoryMemory,
      categoryChannel: categoryChannel ?? this.categoryChannel,
      categoryFont: categoryFont ?? this.categoryFont,
      categoryNetwork: categoryNetwork ?? this.categoryNetwork,
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
    );
  }
}

/// Provides [SleuthThemeData] to overlay widgets via the widget tree.
///
/// Package-internal — consumers configure theming via [SleuthConfig.theme],
/// not by placing this widget themselves.
class SleuthTheme extends InheritedWidget {
  const SleuthTheme({
    super.key,
    required this.data,
    required super.child,
  });

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
