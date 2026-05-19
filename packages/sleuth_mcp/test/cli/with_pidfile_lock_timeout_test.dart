import 'dart:async';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

/// Orphan-cleanup contract on [withPidfileLock]: timeout after spawn
/// but before pidfile write must SIGKILL the registered child + delete
/// the pidfile so a follow-up attach isn't blocked by an orphan iproxy.
void main() {
  group('withPidfileLock timeout cleanup', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sleuth_pidlock_test_');
    });

    tearDown(() async {
      if (tmp.existsSync()) {
        await tmp.delete(recursive: true);
      }
    });

    test('timeout after registered spawn kills child and removes pidfile',
        () async {
      final pidfile = pidfileForSession(
        directory: tmp.path,
        udid: 'UDID-TIMEOUT',
        hostPort: 12345,
      );

      Process? captured;
      try {
        await withPidfileLock<void>(
          pidfile,
          (guard) async {
            // Spawn a long-running child the way iproxy would, then
            // register it so the lock owns reap-on-timeout.
            final p = await Process.start('sh', ['-c', 'sleep 5']);
            captured = p;
            guard.registerSpawn(p, pidfile);
            // Block past the lock's deadline without ever writing the
            // pidfile — simulates the "spawn-then-hang" hot zone.
            await Future<void>.delayed(const Duration(seconds: 2));
          },
          timeout: const Duration(milliseconds: 200),
        );
        fail('expected TimeoutException');
      } on TimeoutException {
        // expected
      }

      // Pidfile must be gone — placeholder or partial write removed.
      expect(pidfile.existsSync(), isFalse,
          reason: 'pidfile must be deleted on timeout cleanup');

      // Registered child must be SIGKILLed — wait for exit (Process is
      // not detached, so exitCode is available).
      final child = captured;
      expect(child, isNotNull,
          reason: 'body must have spawned a child before the timeout');
      final exitCode = await child!.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          fail('orphan iproxy proxy was not killed on lock timeout — leak');
        },
      );
      // SIGKILL on POSIX surfaces as a negative exit code (-9) via the
      // Dart Process API.
      expect(exitCode < 0 || exitCode == 137, isTrue,
          reason: 'child must be terminated by SIGKILL on timeout '
              '(exitCode=$exitCode)');
    });

    test(
        'happy path: body completes before timeout, pidfile and child '
        'survive', () async {
      final pidfile = pidfileForSession(
        directory: tmp.path,
        udid: 'UDID-HAPPY',
        hostPort: 12347,
      );

      Process? captured;
      await withPidfileLock<void>(
        pidfile,
        (guard) async {
          final p = await Process.start('sh', ['-c', 'sleep 30']);
          captured = p;
          guard.registerSpawn(p, pidfile);
          pidfile.writeAsStringSync('${p.pid}\n', flush: true);
        },
        timeout: const Duration(seconds: 5),
      );

      // Pidfile retained — happy path doesn't trigger the cleanup branch.
      expect(pidfile.existsSync(), isTrue);
      expect(int.parse(pidfile.readAsStringSync().trim()), captured!.pid);

      // Cleanup test artefact: kill the long-running child we spawned.
      captured!.kill(ProcessSignal.sigkill);
      await captured!.exitCode;
      pidfile.deleteSync();
    });
  });
}
