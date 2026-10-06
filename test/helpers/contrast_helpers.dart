import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:sleuth/src/ui/sleuth_theme.dart';

/// WCAG 2 relative luminance of [c] (alpha ignored).
double relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// WCAG 2 contrast ratio of [a] and [b], 1 to 21.
double wcagContrast(Color a, Color b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// [fg] painted over the opaque [bg].
Color composite(Color fg, Color bg) => Color.alphaBlend(fg, bg);

/// Every token of [t] by field name. `theme token map covers every field`
/// keeps it in step with `sleuth_theme.dart`.
Map<String, Object> themeTokens(SleuthThemeData t) => {
  'brightness': t.brightness,
  'severityCriticalText': t.severityCriticalText,
  'severityWarningText': t.severityWarningText,
  'severityOkText': t.severityOkText,
  'badgeFillAlpha': t.badgeFillAlpha,
  'focusRingWidth': t.focusRingWidth,
  'sourceAccentWidth': t.sourceAccentWidth,
  'triggerIconOnLightFill': t.triggerIconOnLightFill,
  'severityCritical': t.severityCritical,
  'severityWarning': t.severityWarning,
  'severityOk': t.severityOk,
  'categoryBuild': t.categoryBuild,
  'categoryLayout': t.categoryLayout,
  'categoryPaint': t.categoryPaint,
  'categoryRaster': t.categoryRaster,
  'categoryMemory': t.categoryMemory,
  'categoryChannel': t.categoryChannel,
  'categoryFont': t.categoryFont,
  'categoryNetwork': t.categoryNetwork,
  'categoryStartup': t.categoryStartup,
  'confidenceConfirmed': t.confidenceConfirmed,
  'confidenceLikely': t.confidenceLikely,
  'confidencePossible': t.confidencePossible,
  'sourceVmTimeline': t.sourceVmTimeline,
  'sourceDebugCallback': t.sourceDebugCallback,
  'sourceStructural': t.sourceStructural,
  'sourceNone': t.sourceNone,
  'effortQuick': t.effortQuick,
  'effortMedium': t.effortMedium,
  'effortInvolved': t.effortInvolved,
  'cardBackground': t.cardBackground,
  'pageBackground': t.pageBackground,
  'sectionBackground': t.sectionBackground,
  'aboutBackground': t.aboutBackground,
  'fixHintBackground': t.fixHintBackground,
  'border': t.border,
  'cardDefault': t.cardDefault,
  'cardHighlighted': t.cardHighlighted,
  'cardJankFlash': t.cardJankFlash,
  'textPrimary': t.textPrimary,
  'textSecondary': t.textSecondary,
  'textTertiary': t.textTertiary,
  'textQuaternary': t.textQuaternary,
  'textSubtle': t.textSubtle,
  'badgeVmBg': t.badgeVmBg,
  'badgeVmText': t.badgeVmText,
  'badgeFrameBg': t.badgeFrameBg,
  'badgeFrameText': t.badgeFrameText,
  'badgeDbgBg': t.badgeDbgBg,
  'badgeDbgText': t.badgeDbgText,
  'bannerDebugBg': t.bannerDebugBg,
  'bannerDebugText': t.bannerDebugText,
  'bannerInstrumentationBg': t.bannerInstrumentationBg,
  'bannerInstrumentationText': t.bannerInstrumentationText,
  'bannerSuccessBg': t.bannerSuccessBg,
  'bannerSuccessText': t.bannerSuccessText,
  'bannerWarningBg': t.bannerWarningBg,
  'bannerWarningText': t.bannerWarningText,
  'effectsBadge': t.effectsBadge,
  'fixHintText': t.fixHintText,
  'disclaimerText': t.disclaimerText,
  'dimOverlay': t.dimOverlay,
  'shadow': t.shadow,
  'gripDots': t.gripDots,
  'checkboxActive': t.checkboxActive,
  'triggerBadgeBg': t.triggerBadgeBg,
  'guideStepAccent': t.guideStepAccent,
  'guideTipIcon': t.guideTipIcon,
  'highlightLabelText': t.highlightLabelText,
  'highlightDot': t.highlightDot,
  'triggerIconColor': t.triggerIconColor,
  'aiChatUserBubbleBg': t.aiChatUserBubbleBg,
  'aiChatUserBubbleText': t.aiChatUserBubbleText,
  'aiShimmerStart': t.aiShimmerStart,
  'aiShimmerMid': t.aiShimmerMid,
  'aiShimmerEnd': t.aiShimmerEnd,
  'spacingXxs': t.spacingXxs,
  'spacingXs': t.spacingXs,
  'spacingSm': t.spacingSm,
  'spacingMd': t.spacingMd,
  'spacingLg': t.spacingLg,
  'spacingXl': t.spacingXl,
  'fontXxs': t.fontXxs,
  'fontXs': t.fontXs,
  'fontSm': t.fontSm,
  'fontMd': t.fontMd,
  'fontBase': t.fontBase,
  'fontLg': t.fontLg,
  'fontXl': t.fontXl,
  'fontXxl': t.fontXxl,
  'fontDisplay': t.fontDisplay,
  'radiusSm': t.radiusSm,
  'radiusMd': t.radiusMd,
  'radiusLg': t.radiusLg,
  'radiusXl': t.radiusXl,
  'radiusXxl': t.radiusXxl,
  'radiusCard': t.radiusCard,
  'radiusFull': t.radiusFull,
};
