import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';

/// Detects unloaded custom fonts in use.
///
/// **Structural Detector** — flags Text/RichText using non-system fonts
/// that may not be loaded, causing invisible text or layout shifts.
class FontLoadingDetector extends BaseDetector {
  FontLoadingDetector()
      : super(
          type: DetectorType.fontLoading,
          lifecycle: DetectorLifecycle.structural,
          name: 'Font Loading',
          description: 'Detects unloaded fonts in use',
        );

  final List<PerformanceIssue> _issues = [];
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

  @override
  void scanTree(BuildContext context) {
    if (!_isEnabled) return;
    _issues.clear();

    final customFonts = <String>{};

    void visitor(Element element) {
      final widget = element.widget;

      if (widget is Text && widget.style?.fontFamily != null) {
        final family = widget.style!.fontFamily!;
        if (!_systemFonts.contains(family)) {
          customFonts.add(family);
        }
      }

      if (widget is RichText) {
        final style = widget.text.style;
        if (style?.fontFamily != null) {
          final family = style!.fontFamily!;
          if (!_systemFonts.contains(family)) {
            customFonts.add(family);
          }
        }
      }

      element.visitChildren(visitor);
    }

    try {
      context.visitChildElements(visitor);
    } catch (_) {}

    // Note: We can detect custom font usage but can't confirm loading
    // status from the widget tree alone. Flag as informational.
    if (customFonts.length > 3) {
      _issues.add(PerformanceIssue(
        stableId: 'multiple_custom_fonts',
        severity: IssueSeverity.warning,
        category: IssueCategory.font,
        confidence: IssueConfidence.possible,
        title: 'Multiple Custom Fonts: ${customFonts.length} families',
        detail: 'Using ${customFonts.length} custom font families: '
            '${customFonts.take(5).join(", ")}.\n'
            'Each font adds to download/load time.',
        fixHint: 'Limit custom fonts to 2-3 families max. '
            'Pre-load fonts using FontLoader or ensure they\'re '
            'bundled in pubspec.yaml.',
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
      ));
    }
  }

  @override
  void dispose() => _issues.clear();
}
