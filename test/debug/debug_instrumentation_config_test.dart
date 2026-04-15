import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_instrumentation_config.dart';

void main() {
  group('DebugInstrumentationConfig defaults', () {
    test(
        'rebuild/paint attribution + widget build profiling on; layout, '
        'paint, and timeline enrichment off', () {
      // Rationale (v0.15.0 + post-ship drilldown fix):
      // - `rebuildAttribution`, `paintAttribution`, `widgetBuildProfiling`
      //   feed Sleuth's rebuild/paint detectors and the profile-mode
      //   `FlutterTimeline.debugCollect()` drain that powers the Rebuild
      //   Stats drilldown. These are the signals users want on by default.
      // - `layoutProfiling` (`debugProfileLayoutsEnabled`) and
      //   `paintProfiling` (`debugProfilePaintsEnabled`) are DISABLED by
      //   default: no Sleuth detector consumes layout/paint timeline
      //   events, and turning them on only floods the same
      //   `FlutterTimeline` buffer the drilldown reads with
      //   `RenderObject.layout()` / `.paint()` runtime-type strings
      //   (`RenderPadding`, `RenderFlex`, `RenderConstrainedBox`,
      //   `RenderSemanticsAnnotations`, …), burying real widget names.
      //   See `debug_instrumentation_config.dart` for the full reasoning.
      // - `timelineEnrichment` is the heaviest flag and off by default.
      const config = DebugInstrumentationConfig();
      expect(config.rebuildAttribution, isTrue);
      expect(config.paintAttribution, isTrue);
      expect(config.widgetBuildProfiling, isTrue);
      expect(config.layoutProfiling, isFalse);
      expect(config.paintProfiling, isFalse);
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
      final controller = SleuthController(
        config: const SleuthConfig(
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
      final controller = SleuthController(
        config: const SleuthConfig(
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
      final controller = SleuthController(
        config: const SleuthConfig(
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
      // `paintProfiling` is `false` by default (see defaults test above),
      // so this test explicitly enables it to preserve the original
      // intent: verify that `layoutProfiling=false` is honoured in
      // isolation while other sub-flags stay on.
      final controller = SleuthController(
        config: const SleuthConfig(
          enableDeepDebugInstrumentation: true,
          advanced: DebugInstrumentationConfig(
            layoutProfiling: false,
            paintProfiling: true,
          ),
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
      final controller = SleuthController(
        config: const SleuthConfig(
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
      final controller = SleuthController(
        config: const SleuthConfig(
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
      final controller = SleuthController(
        config: const SleuthConfig(
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
