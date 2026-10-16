import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/utils/blur_sigma.dart';

// Stand-ins for the private `ImageFilterConfig` classes of Flutter 3.41 and
// later, which the 3.32 floor cannot reference. Same class and field names;
// the example app tests the real classes on the 3.47 lane.
class _BlurImageFilterConfig {
  const _BlurImageFilterConfig(this.sigmaX, this.sigmaY);
  final double sigmaX;
  final double sigmaY;
}

class _ComposeImageFilterConfig {
  const _ComposeImageFilterConfig(this.outer, this.inner);
  final Object outer;
  final Object inner;
}

class _DirectImageFilterConfig {
  const _DirectImageFilterConfig(this.filter);
  final ui.ImageFilter filter;
}

void main() {
  double? sigmaOf(ui.ImageFilter filter) =>
      maxBlurSigma(BackdropFilter(filter: filter, child: const SizedBox()));

  final scale = ui.ImageFilter.matrix(
    Float64List.fromList(<double>[
      1.2, 0, 0, 0, //
      0, 1.2, 0, 0, //
      0, 0, 1, 0, //
      0, 0, 0, 1, //
    ]),
  );

  group('ImageFilter', () {
    test('a blur gives its larger sigma', () {
      expect(sigmaOf(ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2)), 2.0);
      expect(sigmaOf(ui.ImageFilter.blur(sigmaX: 3, sigmaY: 7)), 7.0);
    });

    test('a composition of blurs draws sqrt(a² + b²), in both orders', () {
      final weak = ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1);
      final strong = ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2);
      expect(
        sigmaOf(ui.ImageFilter.compose(outer: weak, inner: strong)),
        closeTo(math.sqrt(5), 1e-9),
      );
      expect(
        sigmaOf(ui.ImageFilter.compose(outer: strong, inner: weak)),
        closeTo(math.sqrt(5), 1e-9),
      );
      expect(
        sigmaOf(
          ui.ImageFilter.compose(
            outer: weak,
            inner: ui.ImageFilter.compose(
              outer: strong,
              inner: ui.ImageFilter.blur(sigmaX: 9, sigmaY: 4),
            ),
          ),
        ),
        closeTo(math.sqrt(1 + 4 + 81), 1e-9),
      );
    });

    test('a NaN, infinite or negative sigma draws no blur', () {
      expect(
        sigmaOf(ui.ImageFilter.blur(sigmaX: double.nan, sigmaY: 20)),
        20.0,
      );
      expect(
        sigmaOf(ui.ImageFilter.blur(sigmaX: 20, sigmaY: double.nan)),
        20.0,
      );
      expect(
        sigmaOf(
          ui.ImageFilter.blur(sigmaX: double.infinity, sigmaY: double.nan),
        ),
        0.0,
      );
      expect(sigmaOf(ui.ImageFilter.blur(sigmaX: -5, sigmaY: -5)), 0.0);
    });

    test('a matrix in a composition makes the sigma unknown', () {
      final blur = ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20);
      expect(
        sigmaOf(ui.ImageFilter.compose(outer: blur, inner: scale)),
        isNull,
      );
      expect(
        sigmaOf(ui.ImageFilter.compose(outer: scale, inner: blur)),
        isNull,
      );
      expect(sigmaOf(scale), isNull);
    });

    test('a color filter adds no blur, alone or composed with a blur', () {
      const tint = ui.ColorFilter.mode(Color(0x80000000), BlendMode.srcOver);
      expect(sigmaOf(tint), 0.0);
      expect(
        sigmaOf(
          ui.ImageFilter.compose(
            outer: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
            inner: tint,
          ),
        ),
        30.0,
      );
    });
  });

  group('ImageFilterConfig shapes (by class name)', () {
    test('blur, compose and direct', () {
      expect(maxBlurSigmaOfConfig(const _BlurImageFilterConfig(1.5, 3)), 3.0);
      expect(
        maxBlurSigmaOfConfig(
          const _ComposeImageFilterConfig(
            _BlurImageFilterConfig(1, 1),
            _BlurImageFilterConfig(2, 2),
          ),
        ),
        closeTo(math.sqrt(5), 1e-9),
      );
      expect(
        maxBlurSigmaOfConfig(
          _DirectImageFilterConfig(ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5)),
        ),
        5.0,
      );
      expect(
        maxBlurSigmaOfConfig(
          _ComposeImageFilterConfig(
            const _BlurImageFilterConfig(1, 1),
            _DirectImageFilterConfig(scale),
          ),
        ),
        isNull,
      );
    });

    test('an unknown class is unknown, without throwing', () {
      expect(maxBlurSigmaOfConfig(Object()), isNull);
      expect(maxBlurSigmaOfConfig('_BlurImageFilterConfig'), isNull);
    });
  });
}
