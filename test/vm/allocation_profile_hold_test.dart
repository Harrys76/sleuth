import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';

import '../helpers/fake_vm_service.dart';

/// `VmServiceClient`'s allocation-profile hold and drain, run through the
/// client's real session start.
void main() {
  final clients = <VmServiceClient>[];
  final gates = <Completer<void>>[];

  VmServiceClient makeClient() {
    final client = VmServiceClient(
      ownIsolateIdResolver: () => 'isolates/1',
      onHeapSample: (_) {},
    );
    clients.add(client);
    return client;
  }

  Future<(VmServiceClient, FakeVmService)> startedClient() async {
    final service = FakeVmService();
    final client = makeClient();
    expect(await client.startSessionForTest(service), isTrue);
    return (client, service);
  }

  Completer<void> holdOpen(FakeVmService service) {
    final gate = Completer<void>();
    gates.add(gate);
    service.allocationProfileGate = gate;
    return gate;
  }

  int profileRequests(FakeVmService service) => service.isolateRpcCalls
      .where((c) => c.$1 == 'getAllocationProfile')
      .length;

  tearDown(() {
    for (final gate in gates) {
      if (!gate.isCompleted) gate.complete();
    }
    gates.clear();
    for (final client in clients) {
      client.dispose();
    }
    clients.clear();
  });

  group('hold', () {
    test('a held read returns null without a request; release restores '
        'reads', () async {
      final (client, service) = await startedClient();

      client.holdAllocationProfileReads();
      expect(client.allocationProfileReadsHeld, isTrue);
      expect(await client.getAllocationProfile(), isNull);
      expect(profileRequests(service), 0);

      client.releaseAllocationProfileReads();
      expect(client.allocationProfileReadsHeld, isFalse);
      expect(await client.getAllocationProfile(), isNotNull);
      expect(profileRequests(service), 1);
    });

    test('holds nest, and an extra release does nothing', () async {
      final (client, service) = await startedClient();

      client
        ..holdAllocationProfileReads()
        ..holdAllocationProfileReads()
        ..releaseAllocationProfileReads();
      expect(client.allocationProfileReadsHeld, isTrue);
      expect(await client.getAllocationProfile(), isNull);

      client
        ..releaseAllocationProfileReads()
        ..releaseAllocationProfileReads();
      expect(client.allocationProfileReadsHeld, isFalse);
      client.holdAllocationProfileReads();
      expect(client.allocationProfileReadsHeld, isTrue);
      expect(profileRequests(service), 0);
    });

    test('a hold outlives a session change', () async {
      final (client, _) = await startedClient();
      client.holdAllocationProfileReads();
      client.endSessionForTest();

      final service = FakeVmService();
      expect(await client.startSessionForTest(service), isTrue);
      expect(await client.getAllocationProfile(), isNull);
      expect(profileRequests(service), 0);
    });
  });

  group('drain', () {
    test('returns true at once with nothing in flight', () async {
      final (client, _) = await startedClient();
      expect(await client.drainAllocationProfileReads(), isTrue);
    });

    test('waits for a request whose caller timed out until the VM '
        'answers', () async {
      final (client, service) = await startedClient();
      final gate = holdOpen(service);

      final read = await client.getAllocationProfile(
        timeout: const Duration(milliseconds: 10),
      );
      expect(read, isNull, reason: 'the caller timed out');
      expect(client.allocationProfileReadsInFlight, 1);

      var drained = false;
      final drain = client
          .drainAllocationProfileReads(
            timeout: const Duration(seconds: 2),
            pollInterval: const Duration(milliseconds: 5),
          )
          .then((value) => drained = value);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(drained, isFalse, reason: 'the VM has not answered yet');

      gate.complete();
      await drain;
      expect(drained, isTrue);
      expect(client.allocationProfileReadsInFlight, 0);
    });

    test('returns false when the timeout passes first', () async {
      final (client, service) = await startedClient();
      holdOpen(service);
      unawaited(
        client.getAllocationProfile(timeout: const Duration(milliseconds: 10)),
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        await client.drainAllocationProfileReads(
          timeout: const Duration(milliseconds: 40),
          pollInterval: const Duration(milliseconds: 5),
        ),
        isFalse,
      );
      expect(client.allocationProfileReadsInFlight, 1);
    });

    test('returns false when the session ends while waiting, although the '
        'new session holds no request', () async {
      final (client, service) = await startedClient();
      holdOpen(service);
      unawaited(
        client.getAllocationProfile(timeout: const Duration(milliseconds: 10)),
      );
      await Future<void>.delayed(Duration.zero);

      final drain = client.drainAllocationProfileReads(
        timeout: const Duration(seconds: 2),
        pollInterval: const Duration(milliseconds: 5),
      );
      client.endSessionForTest();
      expect(client.allocationProfileReadsInFlight, 0);
      expect(await drain, isFalse);
    });

    test('returns false without a session', () async {
      final client = makeClient();
      expect(await client.drainAllocationProfileReads(), isFalse);
    });
  });
}
