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
class FontLoadingDetector extends BaseDetector
    with DetectorMetadataProvider {
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
  };

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  // Known limitation: does not detect fonts applied via DefaultTextStyle
  // or Theme.textTheme inheritance. Only scans direct Text/RichText styles.
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
    final family = style.fontFamily;
    if (family == null || _systemFonts.contains(family)) return;

    _customFonts.add(family);

    // google_fonts (and similar runtime-loading packages) set
    // fontFamilyFallback so the engine can fall back while the font
    // downloads. Bundled fonts never need this.
    final fallbacks = style.fontFamilyFallback;
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

      _issues.add(PerformanceIssue(
        stableId: 'runtime_font_loading',
        severity: count > 2 ? IssueSeverity.critical : IssueSeverity.warning,
        category: IssueCategory.font,
        confidence: IssueConfidence.possible,
        title: 'Runtime Font Loading: $count '
            'famil${count == 1 ? 'y' : 'ies'}',
        detail: '$count font famil${count == 1 ? 'y' : 'ies'} '
            'appear${count == 1 ? 's' : ''} to be loaded at runtime '
            '(fontFamilyFallback detected): '
            '${families.take(5).join(", ")}.\n'
            'Runtime-loaded fonts trigger HTTP requests during first render, '
            'causing visible text flicker (FOUT/FOIT).',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.structural,
        confidenceReason:
            'Structural scan only — runtime font loading heuristic',
        detectedAt: DateTime.now(),
      ));
    }

    // Note: We can detect custom font usage but can't confirm loading
    // status from the widget tree alone. Flag as informational.
    if (_customFonts.length > maxFamilies) {
      final (hint, effort) = FixHintBuilder.multipleCustomFonts(
        fontCount: _customFonts.length,
        families: _customFonts.toList(),
      );

      _issues.add(PerformanceIssue(
        stableId: 'multiple_custom_fonts',
        severity: IssueSeverity.warning,
        category: IssueCategory.font,
        confidence: IssueConfidence.possible,
        title: 'Multiple Custom Fonts: ${_customFonts.length} families',
        detail: 'Using ${_customFonts.length} custom font families: '
            '${_customFonts.take(5).join(", ")}.\n'
            'Each font adds to download/load time.',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.structural,
        confidenceReason:
            'Structural scan only — font families detected in widget tree',
        detectedAt: DateTime.now(),
      ));
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
        tier: EvidenceTier.unvalidated,
        rationale:
            'Font-load duration threshold and missing-asset-font '
            'heuristic. Not runtime-verified against device-specific font '
            'loading profiles or externally cited.',
      );
}
