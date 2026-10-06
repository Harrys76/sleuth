import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show debugProfilePlatformChannels;
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';

void main() {
  setUp(() => debugProfilePlatformChannels = false);
  tearDown(() => debugProfilePlatformChannels = false);

  group('profilePlatformChannels', () {
    testWidgets('defaults: flag stays false and no stats timer is left', (
      tester,
    ) async {
      addTearDown(() => debugProfilePlatformChannels = false);
      // MaterialApp's Title sends SystemChrome.setApplicationSwitcherDescription;
      // with the flag on, that send would start the framework's 1 s stats
      // timer and fail this test as a pending timer.
      await tester.pumpWidget(
        Sleuth.track(child: const MaterialApp(home: Scaffold())),
      );
      expect(debugProfilePlatformChannels, isFalse);
      // No pump past 1 s: a stats timer would still be pending here.
      await tester.pumpWidget(const SizedBox());
      expect(debugProfilePlatformChannels, isFalse);
    });

    testWidgets('opted in without a VM connection: flag stays false', (
      tester,
    ) async {
      addTearDown(() => debugProfilePlatformChannels = false);
      await tester.pumpWidget(
        Sleuth.track(
          config: const SleuthConfig(profilePlatformChannels: true),
          child: const MaterialApp(home: Scaffold()),
        ),
      );
      expect(debugProfilePlatformChannels, isFalse);
      // No pump past 1 s: a stats timer would still be pending here.
      await tester.pumpWidget(const SizedBox());
      expect(debugProfilePlatformChannels, isFalse);
    });

    test('detector setup and vmConnectedForTest do not set the flag', () {
      addTearDown(() => debugProfilePlatformChannels = false);
      final controller = SleuthController(
        config: const SleuthConfig(profilePlatformChannels: true),
      );
      controller.initializeDetectorsForTest();
      controller.vmConnectedForTest = true;
      expect(debugProfilePlatformChannels, isFalse);
      controller.dispose();
      expect(debugProfilePlatformChannels, isFalse);
    });

    test('opted in: VM connect sets the flag, dispose restores it', () {
      addTearDown(() => debugProfilePlatformChannels = false);
      final controller = SleuthController(
        config: const SleuthConfig(profilePlatformChannels: true),
      );
      controller.initializeDetectorsForTest();
      controller.onVmConnectionChangedForTest(true);
      expect(debugProfilePlatformChannels, isTrue);
      controller.dispose();
      expect(debugProfilePlatformChannels, isFalse);
    });

    test('default config: VM connect leaves the flag false', () {
      addTearDown(() => debugProfilePlatformChannels = false);
      final controller = SleuthController();
      controller.initializeDetectorsForTest();
      controller.onVmConnectionChangedForTest(true);
      expect(debugProfilePlatformChannels, isFalse);
      controller.dispose();
    });

    test('opted in with platformChannel disabled: flag stays false', () {
      addTearDown(() => debugProfilePlatformChannels = false);
      final controller = SleuthController(
        config: const SleuthConfig(
          profilePlatformChannels: true,
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      controller.onVmConnectionChangedForTest(true);
      expect(debugProfilePlatformChannels, isFalse);
      controller.dispose();
    });

    test('flag set externally before connect is left on after dispose', () {
      addTearDown(() => debugProfilePlatformChannels = false);
      debugProfilePlatformChannels = true;
      final controller = SleuthController(
        config: const SleuthConfig(profilePlatformChannels: true),
      );
      controller.initializeDetectorsForTest();
      controller.onVmConnectionChangedForTest(true);
      controller.dispose();
      expect(debugProfilePlatformChannels, isTrue);
    });

    test('flag cleared externally after connect stays cleared on dispose', () {
      addTearDown(() => debugProfilePlatformChannels = false);
      final controller = SleuthController(
        config: const SleuthConfig(profilePlatformChannels: true),
      );
      controller.initializeDetectorsForTest();
      controller.onVmConnectionChangedForTest(true);
      expect(debugProfilePlatformChannels, isTrue);
      debugProfilePlatformChannels = false;
      controller.dispose();
      expect(debugProfilePlatformChannels, isFalse);
    });

    test('reconnect after disconnect does not stack state', () {
      addTearDown(() => debugProfilePlatformChannels = false);
      final controller = SleuthController(
        config: const SleuthConfig(profilePlatformChannels: true),
      );
      controller.initializeDetectorsForTest();
      controller.onVmConnectionChangedForTest(true);
      controller.onVmConnectionChangedForTest(false);
      controller.onVmConnectionChangedForTest(true);
      expect(debugProfilePlatformChannels, isTrue);
      controller.dispose();
      expect(debugProfilePlatformChannels, isFalse);
    });
  });
}
