// Hermetic reproducer for `ShaderJankDetector`.
//
// Feeds pipeline/shader builds through `TimelineParser.parse()` into the
// detector in the shapes the engine emits: `TRACE_EVENT` begin/end pairs
// (`B` with args, arg-less `E`) for Impeller Vulkan's
// `PipelineVK::Create` and for Skia events tagged `devtoolsTag: shaders`.
// Frame-pipeline events (`PipelineItem`) and the one-shot
// `CreateShaderLibrary` must stay silent. Impeller Metal emits no
// pipeline events, pinned by an empty timeline.

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import 'package:sleuth/src/detectors/shader_jank_detector.dart';

import '_helpers/vm_reproducer_harness.dart';

/// Begin/end pair as the engine's `TRACE_EVENT` scopes emit it: a `B`
/// carrying [args] and an arg-less `E` on the same thread.
List<TimelineEvent> pipelineBuild({
  String name = 'PipelineVK::Create',
  required int dur,
  required int ts,
  Map<String, String>? args,
}) => [
  buildEvent(name: name, ph: 'B', ts: ts, cat: 'Embedder', args: args),
  buildEvent(name: name, ph: 'E', ts: ts + dur, cat: 'Embedder'),
];

void main() {
  group('ShaderJankDetector reproducer', () {
    late ShaderJankDetector detector;

    setUp(() {
      detector = ShaderJankDetector();
      detector.vmConnected = true;
    });

    const emptyShape = (
      buildEventCount: 0,
      buildScopeCount: 0,
      layoutCount: 0,
      paintCount: 0,
      rasterCount: 0,
      shaderCount: 0,
      channelCount: 0,
      gcCount: 0,
      phaseEventCount: 0,
    );

    group('duration boundary triad (threshold 100ms)', () {
      test('99ms shader does NOT emit shader_compilation', () {
        final events = [...pipelineBuild(dur: 99000, ts: 1000)];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 1,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));
        detector.processTimelineData(parsed);
        expect(detector.issues, isEmpty);
      });

      test(
        '100ms shader DOES emit shader_compilation (inclusive threshold)',
        () {
          final events = [...pipelineBuild(dur: 100000, ts: 1000)];
          final parsed = parseAndAssertShape(events, (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 1,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 1,
          ));
          detector.processTimelineData(parsed);
          expect(detector.issues, hasLength(1));
          expect(detector.issues.first.stableId, 'shader_compilation');
        },
      );

      test('101ms shader emits shader_compilation', () {
        final events = [...pipelineBuild(dur: 101000, ts: 1000)];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 1,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));
        detector.processTimelineData(parsed);
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'shader_compilation');
      });

      test('200ms shader escalates to critical (2× threshold)', () {
        final events = [...pipelineBuild(dur: 200000, ts: 1000)];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 1,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));
        detector.processTimelineData(parsed);
        expect(detector.issues.first.stableId, 'shader_compilation');
        expect(detector.issues.first.severity.name, 'critical');
      });
    });

    group('engine event shapes', () {
      test('PipelineVK::Create 120ms emits warning', () {
        final parsed =
            parseAndAssertShape(pipelineBuild(dur: 120000, ts: 1000), (
              buildEventCount: 0,
              buildScopeCount: 0,
              layoutCount: 0,
              paintCount: 0,
              rasterCount: 0,
              shaderCount: 1,
              channelCount: 0,
              gcCount: 0,
              phaseEventCount: 1,
            ));
        detector.processTimelineData(parsed);
        expect(detector.issues, hasStableId('shader_compilation'));
        expect(detector.issues.single.severity.name, 'warning');
      });

      test('PipelineVK::Create 250ms emits critical', () {
        final parsed =
            parseAndAssertShape(pipelineBuild(dur: 250000, ts: 1000), (
              buildEventCount: 0,
              buildScopeCount: 0,
              layoutCount: 0,
              paintCount: 0,
              rasterCount: 0,
              shaderCount: 1,
              channelCount: 0,
              gcCount: 0,
              phaseEventCount: 1,
            ));
        detector.processTimelineData(parsed);
        expect(detector.issues, hasStableId('shader_compilation'));
        expect(detector.issues.single.severity.name, 'critical');
      });

      test('CreateComputePipeline 150ms emits', () {
        final parsed = parseAndAssertShape(
          pipelineBuild(name: 'CreateComputePipeline', dur: 150000, ts: 1000),
          (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 1,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 1,
          ),
        );
        detector.processTimelineData(parsed);
        expect(detector.issues, hasStableId('shader_compilation'));
      });

      test('Skia devtoolsTag: shaders pair 150ms emits', () {
        final parsed = parseAndAssertShape(
          pipelineBuild(
            name: 'GrGLProgramBuilder::finalize',
            dur: 150000,
            ts: 1000,
            args: {'devtoolsTag': 'shaders'},
          ),
          (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 1,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 1,
          ),
        );
        detector.processTimelineData(parsed);
        expect(detector.issues, hasStableId('shader_compilation'));
      });

      test('PipelineItem 500ms is silent', () {
        final parsed = parseAndAssertShape(
          pipelineBuild(name: 'PipelineItem', dur: 500000, ts: 1000),
          emptyShape,
        );
        detector.processTimelineData(parsed);
        expect(detector.issues, lacksStableId('shader_compilation'));
      });

      test('CreateShaderLibrary 300ms is silent', () {
        final parsed = parseAndAssertShape(
          pipelineBuild(name: 'CreateShaderLibrary', dur: 300000, ts: 1000),
          emptyShape,
        );
        detector.processTimelineData(parsed);
        expect(detector.issues, lacksStableId('shader_compilation'));
      });

      test('Impeller Metal: empty timeline is silent', () {
        final parsed = parseAndAssertShape(<TimelineEvent>[], emptyShape);
        detector.processTimelineData(parsed);
        expect(detector.issues, isEmpty);
      });
    });

    group('Impeller-zero suppression', () {
      test('four consecutive empty polls clear any prior issue', () {
        final triggerEvents = [...pipelineBuild(dur: 150000, ts: 1000)];
        detector.processTimelineData(
          parseAndAssertShape(triggerEvents, (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 1,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 1,
          )),
        );
        expect(detector.issues, hasLength(1));

        for (var i = 0; i < 4; i++) {
          detector.processTimelineData(
            parseAndAssertShape(<TimelineEvent>[], emptyShape),
          );
        }
        expect(detector.issues, isEmpty);
      });
    });

    group('shaderWarmupContext attribution', () {
      // Mocked app-start clock pinned at t=0; tests place shader events at
      // explicit timestamps relative to app-start to exercise each context.
      late ShaderJankDetector attrDetector;

      setUp(() {
        attrDetector = ShaderJankDetector(
          coldStartShaderWindowSeconds: 5,
          shaderKeyframeWindowMs: 100,
          appStartMonotonicUsForTest: () => 0,
        );
        attrDetector.vmConnected = true;
      });

      test('cold_start: shader at +2s within 5s window', () {
        // Synthetic shader event at ts=2_000_000 µs (2 s). app-start = 0.
        // 2_000_000 - 0 = 2_000_000 < 5_000_000 → cold_start.
        final events = [...pipelineBuild(dur: 150000, ts: 2000000)];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 1,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));
        attrDetector.processTimelineData(parsed);
        expect(attrDetector.issues, hasLength(1));
        expect(
          attrDetector.issues.first.extraTraceArgs?['shaderWarmupContext'],
          'cold_start',
        );
      });

      test(
        'hot_path: shader at +10s past cold-start window, no nearby build',
        () {
          // Shader at ts=10_000_000 µs (10 s). 10s > 5s → not cold_start.
          // No build events → not keyframe → fallback hot_path.
          final events = [...pipelineBuild(dur: 150000, ts: 10000000)];
          final parsed = parseAndAssertShape(events, (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 1,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 1,
          ));
          attrDetector.processTimelineData(parsed);
          expect(attrDetector.issues, hasLength(1));
          expect(
            attrDetector.issues.first.extraTraceArgs?['shaderWarmupContext'],
            'hot_path',
          );
        },
      );

      test('keyframe: shader at +10s with build event 50ms before', () {
        // Build at ts=9_950_000 µs, shader at ts=10_000_000 µs.
        // shader - build = 50_000 µs (50 ms) < 100 ms keyframe window.
        // Causal direction (build before shader) satisfied.
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 5000, ts: 9950000),
          ...pipelineBuild(dur: 150000, ts: 10000000),
        ];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 1,
          buildScopeCount: 1,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 1,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 2,
        ));
        attrDetector.processTimelineData(parsed);
        expect(attrDetector.issues, hasLength(1));
        expect(
          attrDetector.issues.first.extraTraceArgs?['shaderWarmupContext'],
          'keyframe',
        );
      });

      test(
        'hot_path: shader event timestamp BEFORE app-start (negative delta)',
        () {
          // VM ring-buffer replay or late `Sleuth.init` can surface shader
          // events with timestamps BEFORE the captured app-start. Without
          // the `deltaUs >= 0` guard, `negative < window` would trivially
          // satisfy the cold_start branch. Pin the guard.
          final earlyStartDetector = ShaderJankDetector(
            coldStartShaderWindowSeconds: 5,
            shaderKeyframeWindowMs: 100,
            appStartMonotonicUsForTest: () => 10000000, // app-start = 10 s
          );
          earlyStartDetector.vmConnected = true;
          // Shader at ts=9_000_000 µs (1 s BEFORE captured app-start).
          final events = [...pipelineBuild(dur: 150000, ts: 9000000)];
          final parsed = parseAndAssertShape(events, (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 1,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 1,
          ));
          earlyStartDetector.processTimelineData(parsed);
          expect(earlyStartDetector.issues, hasLength(1));
          expect(
            earlyStartDetector
                .issues
                .first
                .extraTraceArgs?['shaderWarmupContext'],
            'hot_path',
            reason: 'negative delta must NOT satisfy cold_start branch.',
          );
        },
      );

      test('hot_path: build event 200ms before shader is OUTSIDE window', () {
        // Build at ts=9_800_000 µs, shader at ts=10_000_000 µs.
        // shader - build = 200_000 µs (200 ms) >= 100 ms window → not keyframe.
        // Negative control: confirms keyframe window is bounded, not catch-all.
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 5000, ts: 9800000),
          ...pipelineBuild(dur: 150000, ts: 10000000),
        ];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 1,
          buildScopeCount: 1,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 1,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 2,
        ));
        attrDetector.processTimelineData(parsed);
        expect(attrDetector.issues, hasLength(1));
        expect(
          attrDetector.issues.first.extraTraceArgs?['shaderWarmupContext'],
          'hot_path',
        );
      });

      test(
        'cold_start: shader event timestamp EXACTLY at app-start (delta == 0 inclusive boundary)',
        () {
          // app-start = 0 (group setUp). Shader at ts=0 → delta = 0.
          // Pins inclusive lower bound of `deltaUs >= 0 && deltaUs < window`.
          // Companion to the negative-delta test above: together they pin
          // both sides of the `>= 0` guard.
          final events = [...pipelineBuild(dur: 150000, ts: 0)];
          final parsed = parseAndAssertShape(events, (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 1,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 1,
          ));
          attrDetector.processTimelineData(parsed);
          expect(attrDetector.issues, hasLength(1));
          expect(
            attrDetector.issues.first.extraTraceArgs?['shaderWarmupContext'],
            'cold_start',
            reason:
                'delta == 0 must satisfy cold_start branch (inclusive lower bound).',
          );
        },
      );
    });

    group('negative control', () {
      test('disabled detector never emits shader_compilation', () {
        detector.isEnabled = false;
        final events = [...pipelineBuild(dur: 500000, ts: 1000)];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 1,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));
        detector.processTimelineData(parsed);
        expect(detector.issues, lacksStableId('shader_compilation'));
      });
    });
  });
}
