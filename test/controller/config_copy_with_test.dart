import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

void main() {
  group('SleuthConfig.copyWith', () {
    test('returns identical config when no fields overridden', () {
      const original = SleuthConfig();
      final copy = original.copyWith();

      expect(copy.theme, original.theme);
      expect(copy.fpsTarget, original.fpsTarget);
      expect(copy.rebuildThreshold, original.rebuildThreshold);
      expect(copy.maxListChildren, original.maxListChildren);
      expect(copy.maxGlobalKeys, original.maxGlobalKeys);
      expect(copy.platformChannelLimit, original.platformChannelLimit);
      expect(copy.treeScanInterval, original.treeScanInterval);
      expect(copy.adaptiveScanEnabled, original.adaptiveScanEnabled);
      expect(copy.enabledDetectors, original.enabledDetectors);
      expect(copy.captureBufferCapacity, original.captureBufferCapacity);
      expect(copy.enableDebugCallbacks, original.enableDebugCallbacks);
      expect(
        copy.enableDeepDebugInstrumentation,
        original.enableDeepDebugInstrumentation,
      );
      expect(copy.maxTrackedTypes, original.maxTrackedTypes);
      expect(copy.advanced, original.advanced);
      expect(copy.enableNetworkMonitoring, original.enableNetworkMonitoring);
      expect(copy.slowRequestThresholdMs, original.slowRequestThresholdMs);
      expect(copy.requestFrequencyLimit, original.requestFrequencyLimit);
      expect(
        copy.largeResponseThresholdBytes,
        original.largeResponseThresholdBytes,
      );
      expect(copy.networkExcludePatterns, original.networkExcludePatterns);
      expect(copy.memoryWarmupDurationMs, original.memoryWarmupDurationMs);
      expect(
        copy.frameTimingWarmupFrameCount,
        original.frameTimingWarmupFrameCount,
      );
      expect(
        copy.platformChannelDurationThresholdMs,
        original.platformChannelDurationThresholdMs,
      );
      expect(copy.suppressedIssues, original.suppressedIssues);
      expect(copy.customDetectors, original.customDetectors);
      expect(
        copy.disabledCustomDetectorKeys,
        original.disabledCustomDetectorKeys,
      );
      expect(copy.thresholds, original.thresholds);
      expect(copy.aiChat, original.aiChat);
      expect(copy.showDebugModeBanner, original.showDebugModeBanner);
      expect(copy.triggerButtonAlignment, original.triggerButtonAlignment);
      expect(copy.triggerButtonOffset, original.triggerButtonOffset);
      expect(copy.routeIgnorePatterns, original.routeIgnorePatterns);
      expect(copy.routeHistoryCapacity, original.routeHistoryCapacity);
    });

    test('overrides non-nullable int fields', () {
      const original = SleuthConfig();
      final copy = original.copyWith(
        fpsTarget: 120,
        rebuildThreshold: 20,
        maxListChildren: 100,
        maxGlobalKeys: 50,
        platformChannelLimit: 40,
      );

      expect(copy.fpsTarget, 120);
      expect(copy.rebuildThreshold, 20);
      expect(copy.maxListChildren, 100);
      expect(copy.maxGlobalKeys, 50);
      expect(copy.platformChannelLimit, 40);
    });

    test('overrides Duration and bool fields', () {
      const original = SleuthConfig();
      final copy = original.copyWith(
        treeScanInterval: const Duration(seconds: 5),
        adaptiveScanEnabled: false,
        enableDebugCallbacks: true,
        enableDeepDebugInstrumentation: true,
        enableNetworkMonitoring: false,
        showDebugModeBanner: false,
      );

      expect(copy.treeScanInterval, const Duration(seconds: 5));
      expect(copy.adaptiveScanEnabled, isFalse);
      expect(copy.enableDebugCallbacks, isTrue);
      expect(copy.enableDeepDebugInstrumentation, isTrue);
      expect(copy.enableNetworkMonitoring, isFalse);
      expect(copy.showDebugModeBanner, isFalse);
    });

    test('overrides Set and List fields', () {
      const original = SleuthConfig();
      final copy = original.copyWith(
        enabledDetectors: {DetectorType.frameTiming, DetectorType.rebuild},
        suppressedIssues: {'opacity_zero', 'rebuild_debug_*'},
        disabledCustomDetectorKeys: {'my_detector'},
      );

      expect(copy.enabledDetectors, {
        DetectorType.frameTiming,
        DetectorType.rebuild,
      });
      expect(copy.suppressedIssues, {'opacity_zero', 'rebuild_debug_*'});
      expect(copy.disabledCustomDetectorKeys, {'my_detector'});
    });

    test('overrides Alignment and Offset fields', () {
      const original = SleuthConfig();
      final copy = original.copyWith(
        triggerButtonAlignment: Alignment.bottomLeft,
        triggerButtonOffset: const Offset(8, 32),
      );

      expect(copy.triggerButtonAlignment, Alignment.bottomLeft);
      expect(copy.triggerButtonOffset, const Offset(8, 32));
    });

    group('nullable field sentinel pattern', () {
      test('theme: set non-null value', () {
        const original = SleuthConfig();
        expect(original.theme, isNull);
        final copy = original.copyWith(theme: const SleuthThemeData.light());
        expect(copy.theme, isNotNull);
      });

      test('theme: set to null explicitly', () {
        final original = const SleuthConfig(theme: SleuthThemeData.light());
        expect(original.theme, isNotNull);
        final copy = original.copyWith(theme: null);
        expect(copy.theme, isNull);
      });

      test('theme: omitted preserves original', () {
        final original = const SleuthConfig(theme: SleuthThemeData.light());
        final copy = original.copyWith();
        expect(copy.theme, isNotNull);
      });

      test('networkExcludePatterns: set, null, and omit', () {
        const original = SleuthConfig();
        expect(original.networkExcludePatterns, isNull);

        // Set non-null
        final withPatterns = original.copyWith(
          networkExcludePatterns: ['/analytics'],
        );
        expect(withPatterns.networkExcludePatterns, ['/analytics']);

        // Set to null explicitly
        final cleared = withPatterns.copyWith(networkExcludePatterns: null);
        expect(cleared.networkExcludePatterns, isNull);

        // Omit preserves
        final preserved = withPatterns.copyWith();
        expect(preserved.networkExcludePatterns, ['/analytics']);
      });

      test('aiChat: set, null, and omit', () {
        const original = SleuthConfig();
        expect(original.aiChat, isNull);

        final adapter = AiChatAdapter.openAi(
          apiKey: 'test',
          baseUrl: 'http://localhost',
        );

        final withChat = original.copyWith(aiChat: adapter);
        expect(withChat.aiChat, isNotNull);

        final cleared = withChat.copyWith(aiChat: null);
        expect(cleared.aiChat, isNull);

        final preserved = withChat.copyWith();
        expect(preserved.aiChat, isNotNull);
      });
    });

    test('works with presets', () {
      final minimal = SleuthConfig.minimal();
      final copy = minimal.copyWith(fpsTarget: 90);
      expect(copy.fpsTarget, 90);
      // Preserved from minimal
      expect(copy.enableNetworkMonitoring, isFalse);
      expect(copy.enableDebugCallbacks, isFalse);
    });

    test('overrides route config fields', () {
      const original = SleuthConfig();
      final copy = original.copyWith(
        routeIgnorePatterns: {'/dialog*', '/splash'},
        routeHistoryCapacity: 10,
      );

      expect(copy.routeIgnorePatterns, {'/dialog*', '/splash'});
      expect(copy.routeHistoryCapacity, 10);
    });

    test('assertion validation still fires on invalid values', () {
      const original = SleuthConfig();
      expect(
        () => original.copyWith(fpsTarget: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => original.copyWith(rebuildThreshold: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => original.copyWith(maxListChildren: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => original.copyWith(captureBufferCapacity: -1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => original.copyWith(routeHistoryCapacity: 0),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
