import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/widget_watchdog.dart';

void main() {
  group('FrameVerdict topFunctions', () {
    const sampleAttribution = CpuAttribution(
      functionName: 'build',
      className: 'MyWidget',
      libraryUri: 'package:app/w.dart',
      percentage: 42.5,
    );

    FrameVerdict makeVerdict({List<CpuAttribution>? topFunctions}) =>
        FrameVerdict(
          frameNumber: 1,
          totalFrameTime: const Duration(milliseconds: 32),
          uiThreadTime: const Duration(milliseconds: 28),
          rasterThreadTime: const Duration(milliseconds: 4),
          suspectedPhase: PipelinePhase.build,
          reason: 'Build phase dominant',
          topFunctions: topFunctions,
        );

    test('toJson includes topFunctions when non-null', () {
      final verdict = makeVerdict(topFunctions: [sampleAttribution]);
      final json = verdict.toJson();

      expect(json.containsKey('topFunctions'), isTrue);
      final list = json['topFunctions'] as List;
      expect(list, hasLength(1));
      expect((list[0] as Map)['functionName'], 'build');
      expect((list[0] as Map)['className'], 'MyWidget');
    });

    test('toJson omits topFunctions when null', () {
      final verdict = makeVerdict();
      final json = verdict.toJson();
      expect(json.containsKey('topFunctions'), isFalse);
    });

    test('toJson omits topFunctions when empty', () {
      final verdict = makeVerdict(topFunctions: []);
      final json = verdict.toJson();
      expect(json.containsKey('topFunctions'), isFalse);
    });

    test('fromJson parses topFunctions', () {
      final original = makeVerdict(topFunctions: [sampleAttribution]);
      final json = original.toJson();
      final restored = FrameVerdict.fromJson(json);

      expect(restored.topFunctions, isNotNull);
      expect(restored.topFunctions, hasLength(1));
      expect(restored.topFunctions![0].functionName, 'build');
      expect(restored.topFunctions![0].className, 'MyWidget');
      expect(restored.topFunctions![0].percentage, closeTo(42.5, 0.1));
    });

    test('fromJson handles missing topFunctions as null', () {
      final verdict = makeVerdict();
      final json = verdict.toJson();
      final restored = FrameVerdict.fromJson(json);
      expect(restored.topFunctions, isNull);
    });

    test('withTopFunctions creates copy with attribution', () {
      final original = makeVerdict();
      expect(original.topFunctions, isNull);

      final enriched = original.withTopFunctions([sampleAttribution]);
      expect(enriched.topFunctions, hasLength(1));
      expect(enriched.topFunctions![0].displayName, 'MyWidget.build');

      // Original unchanged
      expect(original.topFunctions, isNull);

      // Other fields preserved
      expect(enriched.frameNumber, original.frameNumber);
      expect(enriched.totalFrameTime, original.totalFrameTime);
      expect(enriched.suspectedPhase, original.suspectedPhase);
      expect(enriched.reason, original.reason);
      expect(enriched.isFullMode, original.isFullMode);
      expect(enriched.isCorrelated, original.isCorrelated);
    });
  });
}
