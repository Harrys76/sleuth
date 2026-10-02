import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

/// One decoded image whose pixels exceed what its display box needs.
class UncachedImageInfo {
  const UncachedImageInfo({
    required this.sourceName,
    required this.ancestorChain,
    this.decodedWidth = 0,
    this.decodedHeight = 0,
    this.displayedWidth = 0,
    this.displayedHeight = 0,
    this.devicePixelRatio = 1,
    this.ratio = 0,
    this.wastedBytes = 0,
  });

  /// Human-readable image source (URL, asset path, file path, or type name).
  final String sourceName;

  /// Ancestor widget chain to help locate the image in code.
  /// e.g. "MyHomePage > Column > Padding > Image"
  final String ancestorChain;

  /// Decoded image size in physical pixels.
  final int decodedWidth;
  final int decodedHeight;

  /// Display box size in logical pixels.
  final double displayedWidth;
  final double displayedHeight;

  /// Device pixel ratio the display box renders at.
  final double devicePixelRatio;

  /// `min(decodedW / neededW, decodedH / neededH)`, where needed is the
  /// display box in physical pixels.
  final double ratio;

  /// RGBA bytes decoded beyond what the display box needs.
  final int wastedBytes;
}

/// Detects images decoded at a larger resolution than they are shown.
///
/// **Structural Detector** — pairs each [Image] with the [RawImage] it
/// builds, reads the decoded `ui.Image` size, the render box size, and the
/// device pixel ratio, and reports images whose decode is well above the
/// physical pixels the box needs. Only the decoded dimensions are read;
/// the `ui.Image` itself is never kept.
class ImageMemoryDetector extends BaseDetector with DetectorMetadataProvider {
  ImageMemoryDetector({
    this.oversizeRatio = 1.5,
    this.minWastedBytes = 1 << 20,
    this.criticalWastedBytes = 16 << 20,
  }) : super(
         type: DetectorType.imageMemory,
         lifecycle: DetectorLifecycle.structural,
         name: 'Image Memory',
         description: 'Detects images decoded larger than they are displayed',
       );

  /// An image qualifies when its decode is at least this many times the
  /// needed physical pixels on its smaller axis.
  final double oversizeRatio;

  /// The issue emits when qualifying images waste at least this many bytes
  /// in total.
  final int minWastedBytes;

  /// Critical severity at or above this many wasted bytes in total.
  final int criticalWastedBytes;

  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  final List<UncachedImageInfo> _uncachedImages = [];
  final List<({Rect rect, RenderObject renderObject, String detail})>
  _pendingHighlights = [];

  /// Image elements entered and not yet left, innermost last. Each pairs
  /// with the first [RawImage] below it, once.
  final List<({Element image, bool paired})> _imageFrames = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  List<WidgetHighlight> get highlights => List.unmodifiable(_highlights);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Oversized images found in the last scan, before the total-bytes gate.
  List<UncachedImageInfo> get uncachedImages =>
      List.unmodifiable(_uncachedImages);

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _uncachedImages.clear();
    _pendingHighlights.clear();
    _imageFrames.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;
    if (widget is Image) {
      _imageFrames.add((image: element, paired: false));
      return;
    }
    if (widget is RawImage && _imageFrames.isNotEmpty) {
      final frame = _imageFrames.last;
      if (frame.paired) return;
      _imageFrames.last = (image: frame.image, paired: true);
      _measure(frame.image, element, widget);
    }
  }

  @override
  void afterElement(Element element) {
    if (_imageFrames.isNotEmpty &&
        identical(_imageFrames.last.image, element)) {
      _imageFrames.removeLast();
    }
  }

  void _measure(Element imageElement, Element rawElement, RawImage raw) {
    final provider = (imageElement.widget as Image).image;
    if (provider is ResizeImage) return;
    // Resizing the decode would change what is shown, not only its
    // resolution: an unscaled crop, a nine-patch, or a tiled image.
    if (raw.fit == BoxFit.none ||
        raw.centerSlice != null ||
        raw.repeat != ImageRepeat.noRepeat) {
      return;
    }
    final decoded = raw.image;
    if (decoded == null) return;
    final decodedW = decoded.width;
    final decodedH = decoded.height;

    final ro = rawElement.renderObject;
    if (ro is! RenderBox || !ro.hasSize) return;
    final size = ro.size;
    if (size.width <= 0 || size.height <= 0) return;

    final dpr = _devicePixelRatio(rawElement, ro);
    final neededW = size.width * dpr;
    final neededH = size.height * dpr;
    final ratio = math.min(decodedW / neededW, decodedH / neededH);
    if (ratio < oversizeRatio) return;
    final wastedBytes = ((decodedW * decodedH - neededW * neededH) * 4).round();

    final sourceName = extractSourceName(provider);
    _uncachedImages.add(
      UncachedImageInfo(
        sourceName: sourceName,
        ancestorChain: buildAncestorChain(imageElement),
        decodedWidth: decodedW,
        decodedHeight: decodedH,
        displayedWidth: size.width,
        displayedHeight: size.height,
        devicePixelRatio: dpr,
        ratio: ratio,
        wastedBytes: wastedBytes,
      ),
    );
    final rect = getGlobalRect(ro);
    if (rect != null) {
      _pendingHighlights.add((
        rect: rect,
        renderObject: ro,
        detail:
            '${_providerTypeName(provider)}: $sourceName\n'
            'Decoded ${decodedW}x$decodedH px for '
            '${_dp(size.width)}x${_dp(size.height)} dp @ ${_dp(dpr)}x '
            '(${ratio.toStringAsFixed(1)}x)',
      ));
    }
  }

  /// Device pixel ratio for [element], read without registering a
  /// dependency: the nearest [MediaQuery], else the render tree's root
  /// [RenderView].
  static double _devicePixelRatio(Element element, RenderObject ro) {
    final mq = element.getInheritedWidgetOfExactType<MediaQuery>();
    if (mq != null) return mq.data.devicePixelRatio;
    RenderObject? current = ro;
    while (current != null) {
      if (current is RenderView) return current.flutterView.devicePixelRatio;
      current = current.parent;
    }
    return 1.0;
  }

  @override
  void finalizeScan() {
    _imageFrames.clear();
    if (_uncachedImages.isEmpty) {
      _pendingHighlights.clear();
      return;
    }
    final totalWasted = _uncachedImages.fold<int>(
      0,
      (sum, img) => sum + img.wastedBytes,
    );
    if (totalWasted < minWastedBytes) {
      _pendingHighlights.clear();
      return;
    }

    final count = _uncachedImages.length;
    final worstRatio = _uncachedImages.map((img) => img.ratio).reduce(math.max);
    final severity = totalWasted >= criticalWastedBytes
        ? IssueSeverity.critical
        : IssueSeverity.warning;
    final top = [..._uncachedImages]
      ..sort((a, b) => b.wastedBytes.compareTo(a.wastedBytes));
    final imageList = top
        .take(5)
        .map(
          (img) =>
              '  • ${img.sourceName}: decoded '
              '${img.decodedWidth}×${img.decodedHeight} px, shown at '
              '${_dp(img.displayedWidth)}×${_dp(img.displayedHeight)} dp '
              '@ ${_dp(img.devicePixelRatio)}x\n    in ${img.ancestorChain}',
        )
        .join('\n');

    final (hint, effort) = FixHintBuilder.uncachedImages(count: count);

    _issues.add(
      PerformanceIssue(
        stableId: 'uncached_images',
        severity: severity,
        category: IssueCategory.memory,
        confidence: IssueConfidence.likely,
        title:
            'Oversized Images: $count decoded above display size '
            '(worst ${worstRatio.toStringAsFixed(1)}×, '
            '~${_mb(totalWasted)} MB wasted)',
        detail:
            '$count image${count == 1 ? '' : 's'} decoded at least '
            '${oversizeRatio.toStringAsFixed(1)}× the physical pixels '
            'their display box needs, wasting ~${_mb(totalWasted)} MB of '
            'decoded memory.\n\n$imageList',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.structural,
        confidenceReason:
            'Measured decoded size against display size; the widget may '
            'still grow later',
        extraTraceArgs: {
          'imageCount': '$count',
          'worstRatio': worstRatio.toStringAsFixed(2),
          'wastedBytes': '$totalWasted',
        },
        detectedAt: DateTime.now(),
      ),
    );
    for (final h in _pendingHighlights) {
      _highlights.add(
        WidgetHighlight(
          rect: h.rect,
          renderObject: h.renderObject,
          widgetName: 'Image',
          severity: severity,
          detectorName: 'Image',
          detail: h.detail,
        ),
      );
    }
    _pendingHighlights.clear();
  }

  static String _dp(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  static String _mb(int bytes) => (bytes / (1 << 20)).toStringAsFixed(1);

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
    _pendingHighlights.clear();
    _imageFrames.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hermetic reproducer decodes real PNGs (engine-encoded test images '
        'through Image.memory + precacheImage) at explicit device pixel '
        'ratios and pins the measured rule: each Image pairs once with the '
        'first RawImage it builds; an image qualifies when '
        'min(decodedW / (boxW × dpr), decodedH / (boxH × dpr)) >= 1.5; the '
        'issue emits when the qualifying images waste >= 1 MiB of RGBA '
        'bytes in total and is critical at >= 16 MiB. Pinned silent: a '
        'single 400 px image at 100 dp @ 2x (480 KB), ratio 1.4 at any '
        'count, a BoxFit.cover crop whose smaller axis matches, '
        'BoxFit.none, centerSlice, repeat, ResizeImage providers, and an '
        'image not yet decoded (absence, then presence after decode). '
        'Device pixel ratio comes from the nearest MediaQuery without a '
        'dependency, else the root RenderView. BoxDecoration images are '
        'not reported: their decoded image is private to the painter, so '
        'no measurement is possible. Confidence is likely: decode and '
        'display are measured, but a widget may legitimately grow later. '
        'Not yet runtime-verified on a profile-mode capture.',
    reproducerPath: 'test/validation/image_memory_reproducer_test.dart',
    coveredStableIds: {'uncached_images'},
  );
}
