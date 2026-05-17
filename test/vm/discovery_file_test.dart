import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sleuth/src/vm/discovery_file.dart';

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('sleuth_discovery_test_');
    DiscoveryFile.testDirectoryOverride = tmpDir.path;
    DiscoveryFile.resetMissingHomeWarnedForTest();
  });

  tearDown(() {
    DiscoveryFile.testDirectoryOverride = null;
    if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
  });

  group('DiscoveryFile lifecycle', () {
    test('write → read three-line content with format tag', () async {
      final path = await DiscoveryFile.write(
        webSocketUri: Uri.parse('ws://127.0.0.1:55555/abc=/ws'),
        pid: 9999,
        sessionUuid: 'session-uuid-1',
      );
      expect(path, isNotNull);
      final file = File(path!);
      expect(file.existsSync(), isTrue);
      final lines = file.readAsStringSync().split('\n');
      expect(lines[0], DiscoveryFile.formatTag);
      expect(lines[1], 'session-uuid-1');
      expect(lines[2], 'ws://127.0.0.1:55555/abc=/ws');
    });

    test('write is idempotent — overwrites prior content', () async {
      await DiscoveryFile.write(
        webSocketUri: Uri.parse('ws://127.0.0.1:1/ws'),
        pid: 1234,
        sessionUuid: 'u1',
      );
      final path = await DiscoveryFile.write(
        webSocketUri: Uri.parse('ws://127.0.0.1:2/ws'),
        pid: 1234,
        sessionUuid: 'u2',
      );
      final lines = File(path!).readAsStringSync().split('\n');
      expect(lines[1], 'u2');
      expect(lines[2], 'ws://127.0.0.1:2/ws');
    });

    test('delete removes the file for the given pid', () async {
      await DiscoveryFile.write(
        webSocketUri: Uri.parse('ws://127.0.0.1:3/ws'),
        pid: 4321,
        sessionUuid: 'u',
      );
      final path = p.join(tmpDir.path, 'vm_service_uri_4321');
      expect(File(path).existsSync(), isTrue);
      DiscoveryFile.delete(4321);
      expect(File(path).existsSync(), isFalse);
    });

    test('delete on missing file is a no-op (does not throw)', () {
      expect(() => DiscoveryFile.delete(424242), returnsNormally);
    });
  });

  group('sweep — current pid protection', () {
    test('stale sweep leaves current-pid file alone even when older than 24h',
        () async {
      final selfPath = p.join(tmpDir.path, 'vm_service_uri_$pid');
      File(selfPath).writeAsStringSync('self');
      File(selfPath).setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 25)),
      );
      await DiscoveryFile.sweepNow();
      expect(File(selfPath).existsSync(), isTrue);
    });

    test('cap-overflow sweep never deletes current-pid file', () async {
      final selfPath = p.join(tmpDir.path, 'vm_service_uri_$pid');
      File(selfPath).writeAsStringSync('self');
      // Self has the oldest mtime — the natural cap-deletion candidate.
      File(selfPath).setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 12)),
      );
      // Add 60 fresher entries to push survivors above the 50 cap.
      for (var i = 0; i < 60; i++) {
        final path = p.join(
            tmpDir.path, 'vm_service_uri_2${i.toString().padLeft(5, '0')}');
        File(path).writeAsStringSync('x');
        File(path).setLastModifiedSync(
          DateTime.now().subtract(Duration(seconds: 60 - i)),
        );
      }
      await DiscoveryFile.sweepNow();
      expect(File(selfPath).existsSync(), isTrue,
          reason: 'sweep must never delete the live session file');
    });
  });

  group('sweep', () {
    test('removes files older than 24 h', () async {
      final stalePath = p.join(tmpDir.path, 'vm_service_uri_1');
      final freshPath = p.join(tmpDir.path, 'vm_service_uri_2');
      File(stalePath).writeAsStringSync('stale');
      File(freshPath).writeAsStringSync('fresh');
      File(stalePath).setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 25)),
      );

      await DiscoveryFile.sweepNow();

      expect(File(stalePath).existsSync(), isFalse);
      expect(File(freshPath).existsSync(), isTrue);
    });

    test('cap drops oldest survivors beyond 50', () async {
      for (var i = 0; i < 55; i++) {
        final path = p.join(tmpDir.path, 'vm_service_uri_$i');
        File(path).writeAsStringSync('x');
        // Stagger mtimes so cap deletes the lowest indices deterministically.
        File(path).setLastModifiedSync(
          DateTime.now().subtract(Duration(seconds: 55 - i)),
        );
      }
      await DiscoveryFile.sweepNow();
      var survivors = 0;
      for (final f in tmpDir.listSync()) {
        if (f is File && p.basename(f.path).startsWith('vm_service_uri_')) {
          survivors++;
        }
      }
      expect(survivors, 50);
      // Lowest indices (oldest mtimes) deleted.
      expect(
          File(p.join(tmpDir.path, 'vm_service_uri_0')).existsSync(), isFalse);
      expect(
          File(p.join(tmpDir.path, 'vm_service_uri_4')).existsSync(), isFalse);
      expect(
          File(p.join(tmpDir.path, 'vm_service_uri_54')).existsSync(), isTrue);
    });

    test('ignores entries that do not match the prefix', () async {
      File(p.join(tmpDir.path, 'unrelated.txt')).writeAsStringSync('ignore me');
      await DiscoveryFile.sweepNow();
      expect(File(p.join(tmpDir.path, 'unrelated.txt')).existsSync(), isTrue);
    });

    test('in-progress tempfiles (.vm_service_uri_*.in_progress) survive sweep',
        () async {
      final tempPath = p.join(tmpDir.path, '.vm_service_uri_12345.in_progress');
      File(tempPath).writeAsStringSync('partial');
      File(tempPath).setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 48)),
      );
      await DiscoveryFile.sweepNow();
      expect(File(tempPath).existsSync(), isTrue,
          reason:
              'sweep regex must not match the leading-dot in-progress tempfile');
    });
  });

  group('POSIX file mode', () {
    test('file is mode 0600 after write', () async {
      if (Platform.isWindows) return;
      final path = await DiscoveryFile.write(
        webSocketUri: Uri.parse('ws://127.0.0.1:7/ws'),
        pid: 7777,
        sessionUuid: 'u',
      );
      expect(path, isNotNull);
      final mode = File(path!).statSync().mode & 0x1ff;
      expect(mode, 0x180); // 0o600
    });
  });
}
