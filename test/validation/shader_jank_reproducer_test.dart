// Hermetic reproducer for `ShaderJankDetector`.
//
// Feeds shader-compile `'X'` events through `TimelineParser.parse()`
// into the detector and asserts emission at the duration boundary.
// Exercises three shader-name variants accepted by the parser's
// `_shaderNames` allowlist (`ShaderCompilation` + `Pipeline::Create` +
// casing variant) so a Flutter engine rename to any one accepted form
// still trips the detector. Impeller-zero suppression pinned by an
// empty-poll sequence that must not produce any issue.

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import 'package:sleuth/src/detectors/shader_jank_detector.dart';

import '_helpers/vm_reproducer_harness.dart';

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
        final events = [
          buildEvent(name: 'ShaderCompilation', ph: 'X', dur: 99000, ts: 1000),
        ];
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

      test('100ms shader DOES emit shader_compilation (inclusive threshold)',
          () {
        final events = [
          buildEvent(name: 'ShaderCompilation', ph: 'X', dur: 100000, ts: 1000),
        ];
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

      test('101ms shader emits shader_compilation', () {
        final events = [
          buildEvent(name: 'ShaderCompilation', ph: 'X', dur: 101000, ts: 1000),
        ];
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
        final events = [
          buildEvent(name: 'ShaderCompilation', ph: 'X', dur: 200000, ts: 1000),
        ];
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

    group('name variants accepted by parser allowlist', () {
      test('`Pipeline::Create` classifies as shader', () {
        final events = [
          buildEvent(name: 'Pipeline::Create', ph: 'X', dur: 150000, ts: 1000),
        ];
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

      test('lowercase `shadercompilation` classifies as shader', () {
        final events = [
          buildEvent(name: 'shadercompilation', ph: 'X', dur: 150000, ts: 1000),
        ];
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
    });

    group('Impeller-zero suppression', () {
      test('four consecutive empty polls clear any prior issue', () {
        final triggerEvents = [
          buildEvent(name: 'ShaderCompilation', ph: 'X', dur: 150000, ts: 1000),
        ];
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

    group('negative control', () {
      test('disabled detector never emits shader_compilation', () {
        detector.isEnabled = false;
        final events = [
          buildEvent(name: 'ShaderCompilation', ph: 'X', dur: 500000, ts: 1000),
        ];
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
