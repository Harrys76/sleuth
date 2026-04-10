import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';

/// Bare-minimum custom detector — no heuristics, just tracks enable state.
class _KeyedDetector extends BaseDetector {
  _KeyedDetector({required super.key})
      : super(
          type: DetectorType.custom,
          lifecycle: DetectorLifecycle.structural,
          name: 'Keyed Test Detector',
          description: 'Key gating test fixture',
        );

  final List<PerformanceIssue> _issues = [];
  bool _enabled = true;

  @override
  List<PerformanceIssue> get issues => _issues;
  @override
  List<WidgetHighlight> get highlights => const [];
  @override
  bool get isEnabled => _enabled;
  @override
  set isEnabled(bool v) => _enabled = v;

  @override
  void scanTree(BuildContext context) {}

  @override
  void dispose() => _issues.clear();
}

/// Builds a controller and forces detector initialization so the M6 gating
/// logic in `_initializeDetectors` runs without requiring a live VM client.
SleuthController _makeController({
  required List<BaseDetector> customDetectors,
  required Set<String> disabledCustomDetectorKeys,
}) {
  final controller = SleuthController(
    config: SleuthConfig(
      customDetectors: customDetectors,
      disabledCustomDetectorKeys: disabledCustomDetectorKeys,
      enabledDetectors: const {DetectorType.frameTiming},
    ),
  );
  controller.initializeDetectorsForTest();
  return controller;
}

void main() {
  group('Custom detector key gating (M6)', () {
    test('non-null key NOT in disabled set — enabled', () {
      final detector = _KeyedDetector(key: 'my_rule');
      final controller = _makeController(
        customDetectors: [detector],
        disabledCustomDetectorKeys: const {'some_other_rule'},
      );

      expect(detector.isEnabled, isTrue);
      controller.dispose();
    });

    test('non-null key IN disabled set — disabled at init', () {
      final detector = _KeyedDetector(key: 'my_rule');
      final controller = _makeController(
        customDetectors: [detector],
        disabledCustomDetectorKeys: const {'my_rule'},
      );

      expect(detector.isEnabled, isFalse);
      controller.dispose();
    });

    test('null key is ALWAYS enabled even if disabled set is non-empty', () {
      // A custom detector with key == null does not participate in gating.
      final detector = _KeyedDetector(key: null);
      final controller = _makeController(
        customDetectors: [detector],
        // Even with a non-empty disabled set, null-key detectors are
        // untouched. This is the documented "opt-out of config gating"
        // signal.
        disabledCustomDetectorKeys: const {'anything', 'else'},
      );

      expect(detector.isEnabled, isTrue);
      controller.dispose();
    });

    test('key collision — both detectors with same key get disabled', () {
      final a = _KeyedDetector(key: 'shared');
      final b = _KeyedDetector(key: 'shared');
      final controller = _makeController(
        customDetectors: [a, b],
        disabledCustomDetectorKeys: const {'shared'},
      );

      expect(a.isEnabled, isFalse);
      expect(b.isEnabled, isFalse);
      controller.dispose();
    });

    test('runtime enable overrides init-time config gating', () {
      // Documented semantic: the gate fires exactly once during
      // _initializeDetectors. Runtime flips win after that.
      final detector = _KeyedDetector(key: 'my_rule');
      final controller = _makeController(
        customDetectors: [detector],
        disabledCustomDetectorKeys: const {'my_rule'},
      );
      expect(detector.isEnabled, isFalse);

      // Runtime flip.
      detector.isEnabled = true;
      expect(detector.isEnabled, isTrue);

      controller.dispose();
    });
  });
}
