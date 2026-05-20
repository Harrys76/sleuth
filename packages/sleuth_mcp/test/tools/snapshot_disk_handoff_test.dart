import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('SnapshotDiskHandoff', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sleuth_handoff_test_');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    Map<String, Object?> envelope({Map<String, Object?>? data}) => {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'u',
          'data': data ??
              {
                'schemaVersion': 5,
                'currentIssues': <Map<String, Object?>>[],
              },
        };

    test('write returns path/sizeBytes/sha256 matching file contents',
        () async {
      final h = SnapshotDiskHandoff(tempDir: tmp);
      final env = envelope();
      final out = await h.write(env);

      final path = out['path'] as String;
      final file = File(path);
      expect(file.existsSync(), isTrue);
      // Files live in a per-pid subdir under the base temp dir.
      expect(file.parent.parent.path, tmp.path);
      expect(file.parent.path, contains('sleuth_snapshot_'));

      final bytes = file.readAsBytesSync();
      expect(out['sizeBytes'], bytes.length);
      expect(out['sha256'], sha256.convert(bytes).toString());

      // File round-trips back to the original envelope.
      final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      expect(decoded['sessionUuid'], 'u');
    });

    test('projection metadata is copied into the handoff pointer', () async {
      final h = SnapshotDiskHandoff(tempDir: tmp);
      final out = await h.write(envelope(data: {
        'schemaVersion': 5,
        'currentIssues': <Map<String, Object?>>[],
        '_projectedSections': ['currentIssues'],
        '_projectionLimits': {'maxIssueCount': 5},
        '_projectionApplied': 'by_app',
      }));
      expect(out['_projectedSections'], ['currentIssues']);
      expect((out['_projectionLimits'] as Map)['maxIssueCount'], 5);
      expect(out['_projectionApplied'], 'by_app');
    });

    test('cleanupAll deletes every written file', () async {
      final h = SnapshotDiskHandoff(tempDir: tmp);
      final a = (await h.write(envelope()))['path'] as String;
      final b = (await h.write(envelope()))['path'] as String;
      expect(File(a).existsSync(), isTrue);
      expect(File(b).existsSync(), isTrue);
      h.cleanupAll();
      expect(File(a).existsSync(), isFalse);
      expect(File(b).existsSync(), isFalse);
    });

    test('aged files in the session dir are swept on next write', () async {
      final h = SnapshotDiskHandoff(
        tempDir: tmp,
        maxAge: const Duration(minutes: 30),
      );
      // First write establishes the per-pid session dir; back-date it
      // so the next write's sweep treats it as aged.
      final first = (await h.write(envelope()))['path'] as String;
      final sessionDir = File(first).parent;
      File(first).setLastModifiedSync(
          DateTime.now().subtract(const Duration(minutes: 45)));

      await h.write(envelope()); // triggers sweep of the session dir
      expect(File(first).existsSync(), isFalse,
          reason: 'stale handoff older than maxAge must be swept');
      // The dir still exists (fresh write lives there).
      expect(sessionDir.existsSync(), isTrue);
    });

    test('non-.json files in the session dir are NOT swept', () async {
      final h = SnapshotDiskHandoff(tempDir: tmp);
      final first = (await h.write(envelope()))['path'] as String;
      final sessionDir = File(first).parent;
      final keep = File('${sessionDir.path}/keep.txt')..writeAsStringSync('x');
      keep.setLastModifiedSync(
          DateTime.now().subtract(const Duration(hours: 2)));
      await h.write(envelope());
      expect(keep.existsSync(), isTrue,
          reason: 'sweep only removes aged .json handoff files');
    });

    test('POSIX file mode is 0600', () async {
      if (Platform.isWindows) return;
      final h = SnapshotDiskHandoff(tempDir: tmp);
      final path = (await h.write(envelope()))['path'] as String;
      final stat = FileStat.statSync(path);
      // mode & 0x1FF isolates the permission bits.
      expect(stat.mode & 0x1FF, 0x180, // 0600
          reason: 'handoff file must be owner-read/write only');
    });
  });
}
