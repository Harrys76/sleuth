import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/debug/debug_instrumentation_config.dart';

void main() {
  group('DebugInstrumentationConfig defaults', () {
    test('all true except timelineEnrichment', () {
      const config = DebugInstrumentationConfig();
      expect(config.rebuildAttribution, isTrue);
      expect(config.paintAttribution, isTrue);
      expect(config.widgetBuildProfiling, isTrue);
      expect(config.layoutProfiling, isTrue);
      expect(config.paintProfiling, isTrue);
      expect(config.timelineEnrichment, isFalse);
    });
  });

  group('parent-switch precedence', () {
    setUp(() {
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    tearDown(() {
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    test('enableDebugCallbacks=false ignores advanced rebuildAttribution', () {
      final controller = WatchdogController(
        config: const WatchdogConfig(
          enableDebugCallbacks: false,
          advanced: DebugInstrumentationConfig(rebuildAttribution: true),
        ),
      );
      controller.initializeDetectorsForTest();

      expect(controller.isDebugCallbacksActive, isFalse);

      controller.dispose();
    });

    test(
        'enableDeepDebugInstrumentation=false ignores advanced layoutProfiling',
        () {
      final controller = WatchdogController(
        config: const WatchdogConfig(
          enableDeepDebugInstrumentation: false,
          advanced: DebugInstrumentationConfig(layoutProfiling: true),
        ),
      );
      controller.initializeDetectorsForTest();

      expect(controller.isDeepInstrumentationActive, isFalse);

      controller.dispose();
    });
  });

  group('selective install via advanced config', () {
    setUp(() {
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    tearDown(() {
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    test('paintAttribution=false → rebuild active, paint not', () {
      final controller = WatchdogController(
        config: const WatchdogConfig(
          enableDebugCallbacks: true,
          advanced: DebugInstrumentationConfig(paintAttribution: false),
        ),
      );
      controller.initializeDetectorsForTest();

      expect(controller.isDebugCallbacksActive, isTrue);
      assert(() {
        expect(debugOnRebuildDirtyWidget, isNotNull);
        expect(debugOnProfilePaint, isNull);
        return true;
      }());

      controller.dispose();
    });

    test('layoutProfiling=false → builds and paints enabled, layout not', () {
      final controller = WatchdogController(
        config: const WatchdogConfig(
          enableDeepDebugInstrumentation: true,
          advanced: DebugInstrumentationConfig(layoutProfiling: false),
        ),
      );
      controller.initializeDetectorsForTest();

      expect(controller.isDeepInstrumentationActive, isTrue);
      assert(() {
        expect(debugProfileBuildsEnabledUserWidgets, isTrue);
        expect(debugProfilePaintsEnabled, isTrue);
        expect(debugProfileLayoutsEnabled, isFalse);
        return true;
      }());

      controller.dispose();
    });
  });

  group('independent parents', () {
    setUp(() {
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    tearDown(() {
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    test('callbacks=false + deep=true → no coordinator, heavy flags active',
        () {
      final controller = WatchdogController(
        config: const WatchdogConfig(
          enableDebugCallbacks: false,
          enableDeepDebugInstrumentation: true,
        ),
      );
      controller.initializeDetectorsForTest();

      expect(controller.isDebugCallbacksActive, isFalse);
      expect(controller.isDeepInstrumentationActive, isTrue);

      controller.dispose();
    });

    test('callbacks=true + deep=false → coordinator installed, no heavy flags',
        () {
      final controller = WatchdogController(
        config: const WatchdogConfig(
          enableDebugCallbacks: true,
          enableDeepDebugInstrumentation: false,
        ),
      );
      controller.initializeDetectorsForTest();

      expect(controller.isDebugCallbacksActive, isTrue);
      expect(controller.isDeepInstrumentationActive, isFalse);

      controller.dispose();
    });
  });

  group('all sub-flags off', () {
    setUp(() {
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    tearDown(() {
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    test(
        'deep=true but all sub-flags false → isDeepInstrumentationActive=false',
        () {
      final controller = WatchdogController(
        config: const WatchdogConfig(
          enableDeepDebugInstrumentation: true,
          advanced: DebugInstrumentationConfig(
            widgetBuildProfiling: false,
            layoutProfiling: false,
            paintProfiling: false,
            timelineEnrichment: false,
          ),
        ),
      );
      controller.initializeDetectorsForTest();

      expect(controller.isDeepInstrumentationActive, isFalse);

      controller.dispose();
    });
  });
}
