import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';
import 'package:vm_service/vm_service.dart';

import '../helpers/fake_vm_service.dart';

/// Session start, isolate identity, the GC isolate filter and the
/// Extension subscription, run through the client's real session start.
void main() {
  final clients = <VmServiceClient>[];

  VmServiceClient makeClient({
    String? Function()? resolver,
    void Function(Event)? onGcEvent,
    void Function(Event)? onExtensionEvent,
  }) {
    final client = VmServiceClient(
      ownIsolateIdResolver: resolver,
      onGcEvent: onGcEvent,
      onExtensionEvent: onExtensionEvent,
      onHeapSample: (_) {},
    );
    clients.add(client);
    return client;
  }

  tearDown(() {
    for (final client in clients) {
      client.dispose();
    }
    clients.clear();
  });

  SentinelException collected() => SentinelException.parse('getMemoryUsage', {
    'type': 'Sentinel',
    'kind': 'Collected',
    'valueAsString': '<collected>',
  });

  group('timeline stream list', () {
    test(
      'setTimelineStreams reports whether the VM accepted the list',
      () async {
        final client = makeClient(resolver: () => 'isolates/1');
        expect(
          await client.setTimelineStreams(const ['Dart']),
          isFalse,
          reason: 'no session yet',
        );

        final service = FakeVmService();
        expect(await client.startSessionForTest(service), isTrue);
        expect(await client.setTimelineStreams(const ['Dart']), isTrue);
        expect(service.lastTimelineFlags, ['Dart']);

        service.timelineFlagsError = RPCError('setVMTimelineFlags', 100, 'x');
        expect(
          await client.setTimelineStreams(const ['Dart', 'Embedder', 'GC']),
          isFalse,
        );
        expect(service.lastTimelineFlags, ['Dart']);
      },
    );
  });

  group('session start', () {
    test('sets timeline flags, resolves identity, then subscribes', () async {
      final service = FakeVmService();
      final client = makeClient(resolver: () => 'isolates/1');

      expect(await client.startSessionForTest(service), isTrue);

      // The Timeline stream comes before the poll loop's first read, so
      // no block finishes between that read and the subscription.
      expect(service.calls, [
        'setVMTimelineFlags',
        'getVM',
        'streamListen:Timeline',
        'streamListen:GC',
      ]);
      expect(client.timelineSource, TimelineSource.stream);
      expect(client.isConnected, isTrue);
    });

    test('a client that does not stream never subscribes to the timeline '
        'and polls', () async {
      final service = FakeVmService();
      final client = VmServiceClient(
        ownIsolateIdResolver: () => 'isolates/1',
        streamTimeline: false,
      );
      addTearDown(client.dispose);

      expect(await client.startSessionForTest(service), isTrue);
      expect(service.streamListenCalls, isNot(contains('Timeline')));
      expect(client.timelineSource, TimelineSource.poll);
    });

    test('a VM that refuses the Timeline stream leaves the session '
        'polling', () async {
      final service = FakeVmService()
        ..streamListenErrors['Timeline'] = RPCError('streamListen', 100, 'no');
      final client = makeClient(resolver: () => 'isolates/1');

      expect(await client.startSessionForTest(service), isTrue);
      expect(client.timelineSource, TimelineSource.poll);
      expect(client.isConnected, isTrue);
    });

    test('returns false and commits nothing when the session ends while '
        'getVM is pending', () async {
      final service = FakeVmService(
        isolates: [isolateRef('isolates/1'), isolateRef('isolates/2')],
      )..getVMGate = Completer<void>();
      final client = makeClient(resolver: () => 'isolates/2');

      final started = client.startSessionForTest(service);
      await Future<void>.delayed(Duration.zero);
      client.endSessionForTest();
      service.getVMGate!.complete();

      expect(await started, isFalse);
      expect(client.mainIsolateIdForTest, isNull);
      expect(client.isOwnIsolateVerified, isFalse);
      expect(service.streamListenCalls, isEmpty);
    });

    test('returns false when the client is disposed while getVM is '
        'pending', () async {
      final service = FakeVmService()..getVMGate = Completer<void>();
      final client = makeClient(resolver: () => 'isolates/1');

      final started = client.startSessionForTest(service);
      await Future<void>.delayed(Duration.zero);
      client.dispose();
      service.getVMGate!.complete();

      expect(await started, isFalse);
      expect(client.isOwnIsolateVerified, isFalse);
    });

    test('a new session resolves identity again', () async {
      final client = makeClient(resolver: () => 'isolates/2');
      await client.startSessionForTest(
        FakeVmService(
          isolates: [isolateRef('isolates/1'), isolateRef('isolates/2')],
        ),
      );
      client.endSessionForTest();
      expect(client.isOwnIsolateVerified, isFalse);
      expect(client.mainIsolateIdForTest, isNull);

      final second = FakeVmService(isolates: [isolateRef('isolates/2')]);
      expect(await client.startSessionForTest(second), isTrue);

      expect(second.getVMCallCount, 1);
      expect(client.isOwnIsolateVerified, isTrue);
      expect(client.mainIsolateIdForTest, 'isolates/2');
    });
  });

  group('isolate identity', () {
    test('a resolver id listed by getVM is verified and used by every '
        'isolate-scoped RPC', () async {
      final service = FakeVmService(
        isolates: [isolateRef('isolates/1'), isolateRef('isolates/2')],
      );
      final client = makeClient(resolver: () => 'isolates/2');
      await client.startSessionForTest(service);

      await client.pollTimelineSync();
      await client.getAllocationProfile();
      await client.getCpuSamples(timeOriginUs: 0, timeExtentUs: 1);

      expect(client.isOwnIsolateVerified, isTrue);
      expect(client.mainIsolateIdForTest, 'isolates/2');
      expect(service.isolateRpcCalls, [
        ('getMemoryUsage', 'isolates/2'),
        ('getAllocationProfile', 'isolates/2'),
        ('getCpuSamples', 'isolates/2'),
      ]);
    });

    for (final (label, resolver) in <(String, String? Function())>[
      ('returns null', () => null),
      ('throws', () => throw StateError('no isolate')),
      ('returns an id getVM does not list', () => 'isolates/9'),
    ]) {
      test('a resolver that $label falls back to the first non-system '
          'isolate, unverified', () async {
        final service = FakeVmService(
          isolates: [isolateRef('isolates/1'), isolateRef('isolates/2')],
        );
        final client = makeClient(resolver: resolver);
        await client.startSessionForTest(service);

        expect(client.isOwnIsolateVerified, isFalse);
        expect(client.mainIsolateIdForTest, 'isolates/1');
      });
    }

    test('a Sentinel with a verified id keeps the id without calling '
        'getVM', () async {
      final service = FakeVmService(
        isolates: [isolateRef('isolates/1'), isolateRef('isolates/2')],
      );
      final client = makeClient(resolver: () => 'isolates/2');
      await client.startSessionForTest(service);
      service.isolateRpcThrows = collected();

      await client.pollTimelineSync();
      await client.getAllocationProfile();

      expect(service.getVMCallCount, 1);
      expect(client.mainIsolateIdForTest, 'isolates/2');
      expect(client.isOwnIsolateVerified, isTrue);
    });

    test('a Sentinel on the unverified path re-resolves, and a getVM '
        'failure there leaves the GC filter off', () async {
      final gc = <Event>[];
      final service = FakeVmService(
        isolates: [isolateRef('isolates/1'), isolateRef('isolates/2')],
      );
      final client = makeClient(resolver: () => null, onGcEvent: gc.add);
      await client.startSessionForTest(service);
      service
        ..isolateRpcThrows = collected()
        ..getVMThrows = StateError('VM busy');

      await client.pollTimelineSync();
      service.gcController
        ..add(gcEvent(isolateId: 'isolates/1'))
        ..add(gcEvent(isolateId: 'isolates/2'));

      expect(service.getVMCallCount, 2);
      expect(client.mainIsolateIdForTest, isNull);
      expect(gc, hasLength(2));
    });

    test('ending the session clears the verified id', () async {
      final client = makeClient(resolver: () => 'isolates/1');
      await client.startSessionForTest(FakeVmService());
      expect(client.isOwnIsolateVerified, isTrue);

      client.endSessionForTest();

      expect(client.isOwnIsolateVerified, isFalse);
    });
  });

  group('GC isolate filter', () {
    test('with a verified id, only events from that isolate pass', () async {
      final gc = <Event>[];
      final service = FakeVmService(
        isolates: [isolateRef('isolates/1'), isolateRef('isolates/2')],
      );
      final client = makeClient(
        resolver: () => 'isolates/2',
        onGcEvent: gc.add,
      );
      await client.startSessionForTest(service);

      service.gcController
        ..add(gcEvent(isolateId: 'isolates/1'))
        ..add(gcEvent(isolateId: 'isolates/2', gcType: 'MarkSweep'))
        ..add(gcEvent(isolateId: 'isolates/3', group: 'isolateGroups/2'));

      expect(gc, hasLength(1));
      expect(gc.single.isolate?.id, 'isolates/2');
      expect(gc.single.json?['gcType'], 'MarkSweep');
    });

    test('an event without an isolate ref passes', () async {
      final gc = <Event>[];
      final service = FakeVmService();
      final client = makeClient(
        resolver: () => 'isolates/1',
        onGcEvent: gc.add,
      );
      await client.startSessionForTest(service);

      service.gcController.add(gcEvent());

      expect(gc, hasLength(1));
    });

    test('with an unverified id, every event passes', () async {
      final gc = <Event>[];
      final service = FakeVmService(
        isolates: [isolateRef('isolates/1'), isolateRef('isolates/2')],
      );
      final client = makeClient(resolver: () => null, onGcEvent: gc.add);
      await client.startSessionForTest(service);

      service.gcController
        ..add(gcEvent(isolateId: 'isolates/1'))
        ..add(gcEvent(isolateId: 'isolates/2'));

      expect(gc, hasLength(2));
    });
  });

  group('Extension stream', () {
    test('a client without an Extension callback does not subscribe', () async {
      final service = FakeVmService();
      final client = makeClient(resolver: () => 'isolates/1');
      await client.startSessionForTest(service);

      expect(service.streamListenCalls, isNot(contains('Extension')));
    });

    test('a client with an Extension callback subscribes and forwards '
        'events', () async {
      final received = <Event>[];
      final service = FakeVmService();
      final client = makeClient(
        resolver: () => 'isolates/1',
        onExtensionEvent: received.add,
      );
      await client.startSessionForTest(service);

      service.extensionController.add(
        Event.parse({
          'type': 'Event',
          'kind': 'Extension',
          'timestamp': 0,
          'extensionKind': 'Flutter.Frame',
        })!,
      );

      expect(service.streamListenCalls, contains('Extension'));
      expect(received, hasLength(1));
    });
  });
}
