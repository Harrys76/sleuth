import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'type_name_cache.dart';

/// Reads the blur strength a [BackdropFilter] draws, or null when it is
/// unknown.
///
/// Profile and release builds remove the `toString` overrides of `dart:ui`
/// and `package:flutter` classes (`--delete-tostring-package-uri`), so
/// parsing `ImageFilter.toString()` finds nothing on a device. The private
/// filter classes keep their fields, which this reads through `dynamic`.
/// The class name picks the path before any dynamic read, so an unexpected
/// filter returns null instead of throwing.
///
/// - A blur gives the larger of its two sigmas; a NaN, infinite or
///   negative sigma draws no blur and reads 0.
/// - A color filter adds no blur (sigma 0), so a composition of a blur and
///   a color filter, as `CupertinoPopupSurface` draws, reads as the blur.
/// - A composition of blurs draws one blur of sqrt(a² + b²). Any other
///   part (a matrix, which scales the drawn blur, or an erode, dilate or
///   shader filter) makes the sigma unknown.
/// - `filterConfig` (Flutter 3.41 and later) is read the same way; it does
///   not exist on older SDKs, where `filter` is always set.
double? maxBlurSigma(BackdropFilter widget) {
  // `filter` is nullable from Flutter 3.41 and non-null before; reading it
  // untyped keeps one body valid on every supported SDK.
  final Object? filter = (widget as dynamic).filter;
  if (filter is ui.ImageFilter) return _filterSigma(filter, 0);
  final Object? config;
  try {
    config = (widget as dynamic).filterConfig as Object?;
  } on NoSuchMethodError {
    return null;
  }
  return config == null ? null : maxBlurSigmaOfConfig(config);
}

/// The [maxBlurSigma] path for an `ImageFilterConfig`, by class name.
@visibleForTesting
double? maxBlurSigmaOfConfig(Object config) => _configSigma(config, 0);

const _maxDepth = 8;

String _className(Object value) =>
    baseTypeName(typeNameCache.lookupType(value.runtimeType));

double? _filterSigma(Object filter, int depth) {
  if (depth > _maxDepth) return null;
  try {
    switch (_className(filter)) {
      case '_GaussianBlurImageFilter':
        final f = filter as dynamic;
        return _larger(f.sigmaX as num, f.sigmaY as num);
      case 'ColorFilter':
        return 0;
      case '_ComposeImageFilter':
        final f = filter as dynamic;
        return _composed(
          _filterSigma(f.innerFilter as Object, depth + 1),
          _filterSigma(f.outerFilter as Object, depth + 1),
        );
    }
  } catch (_) {
    // A field the class name promised is missing or has another type,
    // which means the SDK changed.
  }
  return null;
}

double? _configSigma(Object config, int depth) {
  if (depth > _maxDepth) return null;
  try {
    switch (_className(config)) {
      case '_BlurImageFilterConfig':
        final c = config as dynamic;
        return _larger(c.sigmaX as num, c.sigmaY as num);
      case '_ComposeImageFilterConfig':
        final c = config as dynamic;
        return _composed(
          _configSigma(c.inner as Object, depth + 1),
          _configSigma(c.outer as Object, depth + 1),
        );
      case '_DirectImageFilterConfig':
        return _filterSigma((config as dynamic).filter as Object, depth + 1);
    }
  } catch (_) {
    // As above.
  }
  return null;
}

/// A blur's sigma is its larger axis. A NaN, infinite or negative sigma
/// draws no blur (the engine skips such a filter), so it reads 0.
double _larger(num a, num b) {
  double axis(num v) => v.isFinite && v > 0 ? v.toDouble() : 0;
  final x = axis(a);
  final y = axis(b);
  return x > y ? x : y;
}

/// Two blurs applied in turn draw one blur of sqrt(a² + b²). A color
/// filter reads 0 and leaves the other part unchanged.
double? _composed(double? a, double? b) =>
    a == null || b == null ? null : math.sqrt(a * a + b * b);
