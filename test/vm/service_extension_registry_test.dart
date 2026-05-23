import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/vm/service_extension_handlers.dart';
import 'package:sleuth/src/vm/service_extension_registry.dart';

const _config = SleuthConfig(
  treeScanInterval: Duration(seconds: 1),
  enabledDetectors: {DetectorType.frameTiming},
);

class _FakeRegisterFn {
  final Map<
      String,
      Future<developer.ServiceExtensionResponse> Function(
          String method, Map<String, String> args)> bindings = {};
  int callCount = 0;

  void call(
    String name,
    Future<developer.ServiceExtensionResponse> Function(
            String method, Map<String, String> args)
        handler,
  ) {
    callCount++;
    bindings[name] = handler;
  }
}

void main() {
  late _FakeRegisterFn fake;

  setUp(() {
    fake = _FakeRegisterFn();
    ServiceExtensionRegistry.registerFnForTest = fake.call;
    ServiceExtensionRegistry.resetForTest();
  });

  tearDown(() {
    ServiceExtensionRegistry.registerFnForTest = null;
    ServiceExtensionRegistry.resetForTest();
  });

  test('registeredNames exposes the seven canonical ext.sleuth.* names', () {
    expect(ServiceExtensionRegistry.registeredNames, [
      'ext.sleuth.snapshot',
      'ext.sleuth.issues',
      'ext.sleuth.routeHealth',
      'ext.sleuth.explain',
      'ext.sleuth.encyclopedia',
      'ext.sleuth.causalGraph',
      'ext.sleuth.diagnose',
    ]);
  });

  test('registerAll binds each name exactly once on first instance', () {
    final c = SleuthController(config: _config);
    addTearDown(c.dispose);
    ServiceExtensionRegistry(c).registerAll();
    expect(fake.callCount, 7);
    expect(fake.bindings.keys.toSet(),
        ServiceExtensionRegistry.registeredNames.toSet());
    expect(ServiceExtensionRegistry.unboundNames, isEmpty);
  });

  test('partial bind — only unbound names retried on subsequent registerAll',
      () {
    final hostile = _FakeRegisterFn();
    // Hostile environment rejects two specific names. Wrap with a
    // pass-through for the others.
    ServiceExtensionRegistry.registerFnForTest = (name, handler) {
      if (name == 'ext.sleuth.causalGraph' ||
          name == 'ext.sleuth.encyclopedia') {
        throw StateError('name reserved by another package');
      }
      hostile.call(name, handler);
    };

    final a = SleuthController(config: _config);
    addTearDown(a.dispose);
    ServiceExtensionRegistry(a).registerAll();
    // 5 of 7 bound. The two hostile names remain unbound.
    expect(hostile.callCount, 5);
    expect(ServiceExtensionRegistry.unboundNames.toSet(),
        {'ext.sleuth.causalGraph', 'ext.sleuth.encyclopedia'});

    // Hostile environment goes away; subsequent registerAll retries only
    // the missing names.
    ServiceExtensionRegistry.registerFnForTest = hostile.call;
    final b = SleuthController(config: _config);
    addTearDown(b.dispose);
    ServiceExtensionRegistry(b).registerAll();
    expect(hostile.callCount, 7);
    expect(ServiceExtensionRegistry.unboundNames, isEmpty);
  });

  test(
      'singleton guard — second registry on a fresh controller does not '
      're-bind', () {
    final a = SleuthController(config: _config);
    addTearDown(a.dispose);
    ServiceExtensionRegistry(a).registerAll();
    expect(fake.callCount, 7);

    final b = SleuthController(config: _config);
    addTearDown(b.dispose);
    expect(() => ServiceExtensionRegistry(b).registerAll(), returnsNormally);
    // No additional registerExtension calls.
    expect(fake.callCount, 7);
  });

  test('dispatch routes to the active controller via weak ref', () async {
    final a = SleuthController(config: _config);
    addTearDown(a.dispose);
    ServiceExtensionRegistry(a).registerAll();
    final handler = fake.bindings['ext.sleuth.diagnose']!;
    final r = await handler('ext.sleuth.diagnose', const {});
    final payload = jsonDecode(r.result!) as Map<String, dynamic>;
    expect(payload['sessionUuid'], a.sessionUuid);
  });

  test(
      'dispatch swaps to the second controller after a fresh registry '
      'binds', () async {
    final a = SleuthController(config: _config);
    addTearDown(a.dispose);
    ServiceExtensionRegistry(a).registerAll();

    final b = SleuthController(config: _config);
    addTearDown(b.dispose);
    ServiceExtensionRegistry(b).registerAll();

    final handler = fake.bindings['ext.sleuth.diagnose']!;
    final r = await handler('ext.sleuth.diagnose', const {});
    final payload = jsonDecode(r.result!) as Map<String, dynamic>;
    expect(payload['sessionUuid'], b.sessionUuid);
  });

  test('markDisposed short-circuits dispatch to disconnected', () async {
    final a = SleuthController(config: _config);
    addTearDown(a.dispose);
    final registry = ServiceExtensionRegistry(a)..registerAll();
    registry.markDisposed();

    final handler = fake.bindings['ext.sleuth.diagnose']!;
    final r = await handler('ext.sleuth.diagnose', const {});
    final payload = jsonDecode(r.result!) as Map<String, dynamic>;
    expect(payload['disposed'], isTrue);
    expect(payload['connectionMode'], 'disconnected');
    expect(payload['schemaVersion'], kMcpEnvelopeSchemaVersion);
  });

  test('unknown method returns invalidParams error', () async {
    final a = SleuthController(config: _config);
    addTearDown(a.dispose);
    ServiceExtensionRegistry(a).registerAll();
    final handler = fake.bindings['ext.sleuth.diagnose']!;
    final r = await handler('ext.sleuth.does_not_exist', const {});
    expect(r.isError(), isTrue);
    final payload = jsonDecode(r.errorDetail!) as Map<String, dynamic>;
    expect(payload['error'], 'unknown_method');
  });
}
