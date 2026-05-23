import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/vm/service_extension_registry.dart';

const _config = SleuthConfig(
  treeScanInterval: Duration(seconds: 1),
  enabledDetectors: {DetectorType.frameTiming},
);

class _CapturingRegisterFn {
  final Map<
      String,
      Future<developer.ServiceExtensionResponse> Function(
          String method, Map<String, String> args)> bindings = {};

  void call(
    String name,
    Future<developer.ServiceExtensionResponse> Function(
            String method, Map<String, String> args)
        handler,
  ) {
    bindings[name] = handler;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CapturingRegisterFn fake;

  setUp(() {
    fake = _CapturingRegisterFn();
    ServiceExtensionRegistry.registerFnForTest = fake.call;
    ServiceExtensionRegistry.resetForTest();
  });

  tearDown(() {
    ServiceExtensionRegistry.registerFnForTest = null;
    ServiceExtensionRegistry.resetForTest();
  });

  test(
      'initialize() constructs the registry and registers all seven '
      'extension names', () async {
    final c = SleuthController(config: _config);
    addTearDown(c.dispose);
    await c.initialize();
    expect(c.initializedAt, isNotNull);
    expect(fake.bindings.keys.toSet(),
        ServiceExtensionRegistry.registeredNames.toSet());
  });

  test(
      'dispose() calls markDisposed — dispatch returns disconnected '
      'envelope after teardown', () async {
    final c = SleuthController(config: _config);
    await c.initialize();
    final handler = fake.bindings['ext.sleuth.diagnose']!;
    c.dispose();
    final r = await handler('ext.sleuth.diagnose', const {});
    final payload = jsonDecode(r.result!) as Map<String, dynamic>;
    expect(payload['disposed'], isTrue);
    expect(payload['connectionMode'], 'disconnected');
  });

  test(
      'serial controller setup — second initialize() does not throw on '
      'duplicate registration', () async {
    final a = SleuthController(config: _config);
    await a.initialize();
    a.dispose();

    final b = SleuthController(config: _config);
    addTearDown(b.dispose);
    await expectLater(b.initialize(), completes);

    final handler = fake.bindings['ext.sleuth.diagnose']!;
    final r = await handler('ext.sleuth.diagnose', const {});
    final payload = jsonDecode(r.result!) as Map<String, dynamic>;
    expect(payload['sessionUuid'], b.sessionUuid);
  });
}
