import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';

/// Detects unloaded custom fonts in use.
///
/// **Structural Detector** — flags Text/RichText using non-system fonts
/// that may not be loaded, causing invisible text or layout shifts.
class FontLoadingDetector extends BaseDetector with DetectorMetadataProvider {
  FontLoadingDetector({this.maxFamilies = 3})
    : super(
        type: DetectorType.fontLoading,
        lifecycle: DetectorLifecycle.structural,
        name: 'Font Loading',
        description: 'Detects unloaded fonts in use',
      );

  final int maxFamilies;
  final List<PerformanceIssue> _issues = [];
  final Set<String> _customFonts = {};
  final Set<String> _runtimeLoadedFamilies = {};
  bool _isEnabled = true;

  // Common system fonts that don't need loading
  static const _systemFonts = {
    'Roboto',
    '.SF UI Text',
    '.SF UI Display',
    '.SF Pro Text',
    '.SF Pro Display',
    'San Francisco',
    'Helvetica',
    'Arial',
    'sans-serif',
    'serif',
    'monospace',
    'Courier',
    'Courier New',
    'Times',
    'Times New Roman',
    // Platform families Material typography resolves to.
    'CupertinoSystemText',
    'CupertinoSystemDisplay',
    '.AppleSystemUIFont',
    'Segoe UI',
    // Icon fonts bundled with the SDK / cupertino_icons.
    'MaterialIcons',
    'CupertinoIcons',
  };

  static final _packagePrefix = RegExp(r'^packages/[^/]+/');
  static final _variantSuffix = RegExp(r'^(.+)_[A-Za-z0-9]+$');

  /// Canonical family name: strips a `packages/<pkg>/` prefix, and folds a
  /// google_fonts-style `<Family>_<variant>` name back to `<Family>` when
  /// the first fallback names that family.
  static String _normalizeFamily(String family, List<String>? fallbacks) {
    final unprefixed = family.replaceFirst(_packagePrefix, '');
    final match = _variantSuffix.firstMatch(unprefixed);
    if (match != null &&
        fallbacks != null &&
        fallbacks.isNotEmpty &&
        fallbacks.first == match.group(1)) {
      return match.group(1)!;
    }
    return unprefixed;
  }

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  // Scans direct Text.style / RichText.text.style. Inherited fonts
  // (DefaultTextStyle, Theme.textTheme) ARE covered via Text's internal
  // RichText materialisation: `Text.build()` wraps its child in a
  // `RichText` whose `TextSpan.style` has the inherited DefaultTextStyle
  // merged in, so `checkElement` observes the inherited family on the
  // RichText branch. Verified by font_loading_reproducer_test.dart.
  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _customFonts.clear();
    _runtimeLoadedFamilies.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    if (widget is Text && widget.style?.fontFamily != null) {
      _checkStyle(widget.style!);
    }

    if (widget is RichText) {
      final style = widget.text.style;
      if (style?.fontFamily != null) {
        _checkStyle(style!);
      }
    }
  }

  void _checkStyle(TextStyle style) {
    final rawFamily = style.fontFamily;
    if (rawFamily == null) return;
    final fallbacks = style.fontFamilyFallback;
    final family = _normalizeFamily(rawFamily, fallbacks);
    if (_systemFonts.contains(family)) return;

    _customFonts.add(family);

    // google_fonts (and similar runtime-loading packages) set
    // fontFamilyFallback so the engine can fall back while the font
    // downloads. Bundled fonts never need this.
    if (fallbacks != null && fallbacks.isNotEmpty) {
      _runtimeLoadedFamilies.add(family);
    }
  }

  @override
  void finalizeScan() {
    // Runtime-loaded fonts (e.g. google_fonts) — higher confidence because
    // fontFamilyFallback is a heuristic signal — google_fonts and similar
    // runtime-loading packages set it, but apps with intentional fallback
    // chains may trigger false positives.  Use `possible` confidence.
    if (_runtimeLoadedFamilies.isNotEmpty) {
      final count = _runtimeLoadedFamilies.length;
      final families = _runtimeLoadedFamilies.toList();
      final (hint, effort) = FixHintBuilder.runtimeFontLoading(
        fontCount: count,
        families: families,
      );

      _issues.add(
        PerformanceIssue(
          stableId: 'runtime_font_loading',
          // The fallback heuristic cannot see whether the font is already
          // cached, so the family count never escalates past warning.
          severity: IssueSeverity.warning,
          category: IssueCategory.font,
          confidence: IssueConfidence.possible,
          title:
              'Runtime Font Loading: $count '
              'famil${count == 1 ? 'y' : 'ies'}',
          detail:
              '$count font famil${count == 1 ? 'y' : 'ies'} '
              'appear${count == 1 ? 's' : ''} to be loaded at runtime, '
              'because fontFamilyFallback is set: '
              '${families.take(5).join(", ")}.\n'
              'Fonts loaded at runtime send HTTP requests during the first '
              'render, and the text visibly flickers (FOUT/FOIT).',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.structural,
          confidenceReason:
              'Structural scan only, using a runtime font loading heuristic',
          detectedAt: DateTime.now(),
        ),
      );
    }

    // Note: We can detect custom font usage but can't confirm loading
    // status from the widget tree alone. Flag as informational.
    if (_customFonts.length > maxFamilies) {
      final (hint, effort) = FixHintBuilder.multipleCustomFonts(
        fontCount: _customFonts.length,
        families: _customFonts.toList(),
      );

      _issues.add(
        PerformanceIssue(
          stableId: 'multiple_custom_fonts',
          severity: IssueSeverity.warning,
          category: IssueCategory.font,
          confidence: IssueConfidence.possible,
          title: 'Multiple Custom Fonts: ${_customFonts.length} families',
          detail:
              'The app uses ${_customFonts.length} custom font families: '
              '${_customFonts.take(5).join(", ")}.\n'
              'Each font adds download and load time.',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.structural,
          confidenceReason:
              'Structural scan only. The scan found font families in the '
              'widget tree',
          detectedAt: DateTime.now(),
        ),
      );
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _customFonts.clear();
    _runtimeLoadedFamilies.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hermetic reproducer pins `runtime_font_loading` (a custom '
        '`fontFamily` with a non-empty `fontFamilyFallback`, exercised on '
        'both the Text and RichText paths) and `multiple_custom_fonts` '
        '(distinct-family count above `maxFamilies`, strict-greater). '
        'System-font suppression, silence without a fallback and '
        'duplicate-family dedup are pinned as negative controls. The '
        'detector normalises families (it strips the package prefix and '
        'folds google_fonts `<Family>_<variant>` to `<Family>`) and ignores '
        'platform system families. Runtime loading is always warning. No '
        'device-specific font-load profile verifies it at runtime yet.',
    reproducerPath: 'test/validation/font_loading_reproducer_test.dart',
    coveredStableIds: {'runtime_font_loading', 'multiple_custom_fonts'},
  );
}
