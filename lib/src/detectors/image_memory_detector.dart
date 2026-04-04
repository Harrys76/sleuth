import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

/// Info about a single uncached image found during a scan.
class UncachedImageInfo {
  const UncachedImageInfo({
    required this.sourceName,
    required this.ancestorChain,
  });

  /// Human-readable image source (URL, asset path, file path, or type name).
  final String sourceName;

  /// Ancestor widget chain to help locate the image in code.
  /// e.g. "MyHomePage > Column > Padding > Image"
  final String ancestorChain;
}

/// Detects Image widgets without decode-time resizing (cacheWidth/cacheHeight).
///
/// **Structural Detector** — finds Image widgets that load full-resolution
/// images into memory without downscaling.
class ImageMemoryDetector extends BaseDetector {
  ImageMemoryDetector()
      : super(
          type: DetectorType.imageMemory,
          lifecycle: DetectorLifecycle.structural,
          name: 'Image Memory',
          description: 'Detects Images without cacheWidth/cacheHeight',
        );

  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  final List<UncachedImageInfo> _uncachedImages = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  List<WidgetHighlight> get highlights => List.unmodifiable(_highlights);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Details of each uncached image found in the last scan.
  List<UncachedImageInfo> get uncachedImages =>
      List.unmodifiable(_uncachedImages);

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _uncachedImages.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    if (widget is Image) {
      final provider = widget.image;
      final isResized = provider is ResizeImage;
      if (!isResized) {
        final sourceName = extractSourceName(provider);
        _uncachedImages.add(UncachedImageInfo(
          sourceName: sourceName,
          ancestorChain: buildAncestorChain(element),
        ));
        final ro = element.renderObject;
        if (ro != null) {
          final rect = getGlobalRect(ro);
          if (rect != null) {
            _highlights.add(WidgetHighlight(
              rect: rect,
              widgetName: 'Image',
              severity: IssueSeverity.warning,
              detectorName: 'Image',
              detail: 'Uncached ${_providerTypeName(provider)}: $sourceName\n'
                  'Add cacheWidth/cacheHeight or wrap in ResizeImage',
            ));
          }
        }
      }
    }
  }

  @override
  void finalizeScan() {
    if (_uncachedImages.isNotEmpty) {
      final count = _uncachedImages.length;
      final imageList = _uncachedImages
          .map((img) => '  • ${img.sourceName}\n    in ${img.ancestorChain}')
          .join('\n');

      final (hint, effort) = FixHintBuilder.uncachedImages(count: count);

      _issues.add(PerformanceIssue(
        stableId: 'uncached_images',
        severity: count > 5 ? IssueSeverity.critical : IssueSeverity.warning,
        category: IssueCategory.memory,
        confidence: IssueConfidence.possible,
        title: 'Uncached Images: $count found',
        detail: '$count Image widgets without decode-time resizing. '
            'Full-resolution images are decoded into memory.\n\n$imageList',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
      ));
    }
  }

  static String _providerTypeName(ImageProvider provider) {
    if (provider is NetworkImage) return 'NetworkImage';
    if (provider is AssetImage) return 'AssetImage';
    if (provider is FileImage) return 'FileImage';
    if (provider is MemoryImage) return 'MemoryImage';
    if (provider is ExactAssetImage) return 'ExactAssetImage';
    return provider.runtimeType.toString();
  }

  /// Extract a human-readable name from an ImageProvider.
  static String extractSourceName(ImageProvider provider) {
    if (provider is NetworkImage) return provider.url;
    if (provider is AssetImage) return provider.assetName;
    if (provider is FileImage) return provider.file.path;
    if (provider is MemoryImage) {
      return 'MemoryImage(${provider.bytes.length} bytes)';
    }
    if (provider is ExactAssetImage) return provider.assetName;
    // Fallback: use the runtime type
    return provider.runtimeType.toString();
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _uncachedImages.clear();
  }
}
