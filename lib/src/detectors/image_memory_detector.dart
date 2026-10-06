import 'dart:math' as math;
import 'dart:ui' as ui;

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
    this.widgetCount = 1,
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

  /// Number of widgets showing this one decode. The display fields
  /// describe the largest of them; [ratio] and [wastedBytes] are measured
  /// against the largest needed size on each axis.
  final int widgetCount;
}

/// One measured `Image` → `RawImage` pair of the current scan. The
/// decoded image is held only until [ImageMemoryDetector.finalizeScan].
typedef _MeasuredUse = ({
  ui.Image decoded,
  ImageProvider provider,
  Element imageElement,
  RenderBox renderBox,
  double width,
  double height,
  double dpr,
});

/// Detects images decoded at a larger resolution than they are shown.
///
/// **Structural Detector** — pairs each [Image] with the [RawImage] it
/// builds, reads the decoded `ui.Image` size, the render box size, and the
/// device pixel ratio, and reports images whose decode is well above the
/// physical pixels the box needs. Widgets showing the same decode (one
/// image cache entry, so `ui.Image.isCloneOf`) count it once, against
/// the largest size any of them needs. The `ui.Image` handles are held
/// only for the scan that reads them.
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

  /// Pairs measured in the current scan, grouped by decode at its end.
  final List<_MeasuredUse> _uses = [];

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

  /// Oversized decodes found in the last scan, one entry per decode
  /// however many widgets show it, before the total-bytes gate.
  List<UncachedImageInfo> get uncachedImages =>
      List.unmodifiable(_uncachedImages);

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _uncachedImages.clear();
    _pendingHighlights.clear();
    _imageFrames.clear();
    _uses.clear();
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
      // Paired once measured; a RawImage that cannot be measured yet (no
      // decode, no layout, no device pixel ratio) leaves the pair open.
      if (_measure(frame.image, element, widget)) {
        _imageFrames.last = (image: frame.image, paired: true);
      }
    }
  }

  @override
  void afterElement(Element element) {
    if (_imageFrames.isNotEmpty &&
        identical(_imageFrames.last.image, element)) {
      _imageFrames.removeLast();
    }
  }

  /// Records the pair for [finalizeScan]. Returns false when the pair
  /// cannot be measured yet; true when it was recorded or is skipped by
  /// rule.
  bool _measure(Element imageElement, Element rawElement, RawImage raw) {
    final provider = (imageElement.widget as Image).image;
    if (provider is ResizeImage) return true;
    // Resizing the decode would change what is shown, not only its
    // resolution: an unscaled crop, a nine-patch, or a tiled image.
    if (raw.fit == BoxFit.none ||
        raw.centerSlice != null ||
        raw.repeat != ImageRepeat.noRepeat) {
      return true;
    }
    final decoded = raw.image;
    if (decoded == null) return false;

    final ro = rawElement.renderObject;
    if (ro is! RenderBox || !ro.hasSize) return false;
    final size = ro.size;
    if (size.width <= 0 || size.height <= 0) return false;

    final dpr = _devicePixelRatio(rawElement, ro);
    if (dpr == null || dpr <= 0) return false;
    _uses.add((
      decoded: decoded,
      provider: provider,
      imageElement: imageElement,
      renderBox: ro,
      width: size.width,
      height: size.height,
      dpr: dpr,
    ));
    return true;
  }

  /// Groups the scan's pairs by decode and records each decode whose
  /// size is at least [oversizeRatio] times the largest needed size of
  /// its widgets.
  void _evaluateUses() {
    final groups = <List<_MeasuredUse>>[];
    for (final use in _uses) {
      final group = groups
          .where((g) => g.first.decoded.isCloneOf(use.decoded))
          .firstOrNull;
      if (group == null) {
        groups.add([use]);
      } else {
        group.add(use);
      }
    }
    for (final group in groups) {
      final decodedW = group.first.decoded.width;
      final decodedH = group.first.decoded.height;
      var neededW = 0.0;
      var neededH = 0.0;
      var largest = group.first;
      for (final use in group) {
        neededW = math.max(neededW, use.width * use.dpr);
        neededH = math.max(neededH, use.height * use.dpr);
        if (use.width * use.height * use.dpr * use.dpr >
            largest.width * largest.height * largest.dpr * largest.dpr) {
          largest = use;
        }
      }
      final ratio = math.min(decodedW / neededW, decodedH / neededH);
      if (ratio < oversizeRatio) continue;
      final wastedBytes = ((decodedW * decodedH - neededW * neededH) * 4)
          .round();
      final first = group.first;
      final sourceName = extractSourceName(first.provider);
      _uncachedImages.add(
        UncachedImageInfo(
          sourceName: sourceName,
          ancestorChain: buildAncestorChain(first.imageElement),
          decodedWidth: decodedW,
          decodedHeight: decodedH,
          displayedWidth: largest.width,
          displayedHeight: largest.height,
          devicePixelRatio: largest.dpr,
          ratio: ratio,
          wastedBytes: wastedBytes,
          widgetCount: group.length,
        ),
      );
      for (final use in group) {
        final rect = getGlobalRect(use.renderBox);
        if (rect == null) continue;
        final useRatio = math.min(
          decodedW / (use.width * use.dpr),
          decodedH / (use.height * use.dpr),
        );
        _pendingHighlights.add((
          rect: rect,
          renderObject: use.renderBox,
          detail:
              '${_providerTypeName(use.provider)}: $sourceName\n'
              'Decoded ${decodedW}x$decodedH px for '
              '${_dp(use.width)}x${_dp(use.height)} dp @ ${_dp(use.dpr)}x '
              '(${useRatio.toStringAsFixed(1)}x)',
        ));
      }
    }
    _uses.clear();
  }

  /// Device pixel ratio for [element], read without registering a
  /// dependency: the nearest [MediaQuery], else the render tree's root
  /// [RenderView]; null when neither is reachable.
  static double? _devicePixelRatio(Element element, RenderObject ro) {
    final mq = element.getInheritedWidgetOfExactType<MediaQuery>();
    if (mq != null) return mq.data.devicePixelRatio;
    RenderObject? current = ro;
    while (current != null) {
      if (current is RenderView) return current.flutterView.devicePixelRatio;
      current = current.parent;
    }
    return null;
  }

  @override
  void finalizeScan() {
    _imageFrames.clear();
    _evaluateUses();
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
    final widgetCount = _uncachedImages.fold<int>(
      0,
      (sum, img) => sum + img.widgetCount,
    );
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
              '@ ${_dp(img.devicePixelRatio)}x'
              '${img.widgetCount > 1 ? '; shown by ${img.widgetCount} widgets' : ''}'
              '\n    in ${img.ancestorChain}',
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
            '$count image${count == 1 ? ' was' : 's were'} decoded at '
            'least ${oversizeRatio.toStringAsFixed(1)} times the physical '
            'pixels their display box needs'
            '${widgetCount > count ? ' (shown by $widgetCount widgets)' : ''}'
            '. This wastes about ${_mb(totalWasted)} MB of decoded memory.'
            '\n\n$imageList',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.structural,
        confidenceReason:
            'Measured decoded size against display size. The widget may '
            'still grow later',
        extraTraceArgs: {
          'imageCount': '$count',
          'widgetCount': '$widgetCount',
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
    _uses.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hermetic reproducer decodes real PNGs (engine-encoded test images '
        'through Image.memory and precacheImage) at explicit device pixel '
        'ratios and pins the measured rule. Each Image pairs once with the '
        'first RawImage it can measure. Widgets that show one decode '
        '(ui.Image.isCloneOf) count it once, against the largest needed '
        'size on each axis. A decode qualifies when '
        '`min(decodedW / (boxW * dpr), decodedH / (boxH * dpr)) >= 1.5`. '
        'The issue emits when the qualifying decodes waste at least 1 MiB '
        'of RGBA bytes in total, and it is critical at 16 MiB or more. The '
        'reproducer pins these as silent: a single 400 px image at 100 dp '
        'and 2x (480 KB), ratio 1.4 at any count, a BoxFit.cover crop '
        'whose smaller axis matches, BoxFit.none, centerSlice, repeat, '
        'ResizeImage providers, and an image not yet decoded (absence, '
        'then presence after decode). The device pixel ratio comes from '
        'the nearest MediaQuery without a dependency, else from the root '
        'RenderView. With neither, the pair is not measured. BoxDecoration '
        'images are not reported, because their decoded image is private '
        'to the painter and cannot be measured. Confidence is likely. '
        'Decode and display are measured, but a widget may grow later. No '
        'profile-mode capture verifies it at runtime yet.',
    reproducerPath: 'test/validation/image_memory_reproducer_test.dart',
    coveredStableIds: {'uncached_images'},
  );
}
