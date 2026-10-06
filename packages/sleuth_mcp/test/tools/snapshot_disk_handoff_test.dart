import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/snapshot_disk_handoff.dart'
    show defaultProcessAliveCheck;
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
      'data':
          data ??
          {'schemaVersion': 5, 'currentIssues': <Map<String, Object?>>[]},
    };

    test(
      'write returns path/sizeBytes/sha256 matching file contents',
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
      },
    );

    test('projection metadata is copied into the handoff pointer', () async {
      final h = SnapshotDiskHandoff(tempDir: tmp);
      final out = await h.write(
        envelope(
          data: {
            'schemaVersion': 5,
            'currentIssues': <Map<String, Object?>>[],
            '_projectedSections': ['currentIssues'],
            '_projectionLimits': {'maxIssueCount': 5},
            '_projectionApplied': 'by_app',
          },
        ),
      );
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
        DateTime.now().subtract(const Duration(minutes: 45)),
      );

      await h.write(envelope()); // triggers sweep of the session dir
      expect(
        File(first).existsSync(),
        isFalse,
        reason: 'stale handoff older than maxAge must be swept',
      );
      // The dir still exists (fresh write lives there).
      expect(sessionDir.existsSync(), isTrue);
    });

    test('non-.json files in the session dir are NOT swept', () async {
      final h = SnapshotDiskHandoff(tempDir: tmp);
      final first = (await h.write(envelope()))['path'] as String;
      final sessionDir = File(first).parent;
      final keep = File('${sessionDir.path}/keep.txt')..writeAsStringSync('x');
      keep.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      await h.write(envelope());
      expect(
        keep.existsSync(),
        isTrue,
        reason: 'sweep only removes aged .json handoff files',
      );
    });

    test('deleteFiles removes the process directory once it is empty, and a '
        'later write creates it again', () async {
      final h = SnapshotDiskHandoff(tempDir: tmp);
      final path = (await h.write(envelope()))['path'] as String;
      final sessionDir = File(path).parent;
      h.deleteFiles();
      expect(File(path).existsSync(), isFalse);
      expect(sessionDir.existsSync(), isFalse);
      final again = (await h.write(envelope()))['path'] as String;
      expect(File(again).existsSync(), isTrue);
    });

    test('cleanupAll removes the process directory once it is empty', () async {
      final h = SnapshotDiskHandoff(tempDir: tmp);
      final path = (await h.write(envelope()))['path'] as String;
      final sessionDir = File(path).parent;
      h.cleanupAll();
      expect(sessionDir.existsSync(), isFalse);
    });

    test('a write after cleanupAll fails and leaves no file, so a call still '
        'running at exit cannot write after the exit cleanup', () async {
      final h = SnapshotDiskHandoff(tempDir: tmp);
      h.cleanupAll();
      await expectLater(
        h.write(envelope()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('shutting down'),
          ),
        ),
      );
      expect(tmp.listSync(), isEmpty);
    });

    test('cleanupAll keeps the process directory when something else is in '
        'it', () async {
      final h = SnapshotDiskHandoff(tempDir: tmp);
      final path = (await h.write(envelope()))['path'] as String;
      final sessionDir = File(path).parent;
      final other = File('${sessionDir.path}/keep.txt')..writeAsStringSync('x');
      h.cleanupAll();
      expect(File(path).existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      expect(sessionDir.existsSync(), isTrue);
    });

    test('cleanupAll without a write leaves the temp dir alone', () {
      SnapshotDiskHandoff(tempDir: tmp).cleanupAll();
      expect(tmp.existsSync(), isTrue);
      expect(tmp.listSync(), isEmpty);
    });

    group('sweepStaleProcessDirs', () {
      // Back-dates [dir] with `touch -t`; Dart cannot set a directory's
      // modification time.
      void age(Directory dir) {
        final result = Process.runSync('touch', [
          '-t',
          '202001010000',
          dir.path,
        ]);
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      Directory make(String name, {bool old = true, bool empty = true}) {
        final dir = Directory('${tmp.path}/$name')..createSync();
        if (!empty) File('${dir.path}/a.json').writeAsStringSync('{}');
        if (old) age(dir);
        return dir;
      }

      test(
        'removes only old, empty sleuth_snapshot_<pid> dirs of other processes',
        () async {
          final oldEmpty = make('sleuth_snapshot_99999901');
          final oldFull = make('sleuth_snapshot_99999902', empty: false);
          final fresh = make('sleuth_snapshot_99999903', old: false);
          final otherName = make('sleuth_snapshot_abc');
          final otherPrefix = make('not_sleuth_99999904');
          final own = make('sleuth_snapshot_$pid');
          final looseFile = File('${tmp.path}/sleuth_snapshot_99999905')
            ..writeAsStringSync('x');

          final sweep = SnapshotDiskHandoff(
            tempDir: tmp,
            isProcessAlive: (_) async => true,
          ).sweepStaleProcessDirs();
          // The empty directories go before the first await, so the startup
          // call, which does not await the sweep, still removes them.
          expect(oldEmpty.existsSync(), isFalse);
          await sweep;

          expect(oldEmpty.existsSync(), isFalse);
          expect(
            oldFull.existsSync(),
            isTrue,
            reason: 'keeps the files of a process that may still run',
          );
          expect(fresh.existsSync(), isTrue, reason: 'younger than 30 min');
          expect(otherName.existsSync(), isTrue, reason: 'pid must be numeric');
          expect(otherPrefix.existsSync(), isTrue, reason: 'not our prefix');
          expect(
            own.existsSync(),
            isTrue,
            reason: 'this process keeps its dir',
          );
          expect(looseFile.existsSync(), isTrue);
        },
        testOn: '!windows',
      );

      test('a missing temp dir is not an error', () async {
        final gone = Directory('${tmp.path}/missing');
        await expectLater(
          SnapshotDiskHandoff(tempDir: gone).sweepStaleProcessDirs(),
          completes,
        );
      });

      /// Writes `<name>` into [dir], last modified [age] ago.
      File handoffFile(Directory dir, String name, Duration age) =>
          File('${dir.path}/$name')
            ..writeAsStringSync('{}')
            ..setLastModifiedSync(DateTime.now().subtract(age));

      test('deletes the aged handoff files of a sidecar whose process is '
          'gone, then its directory', () async {
        final crashed = Directory('${tmp.path}/sleuth_snapshot_99999906')
          ..createSync();
        final stale = handoffFile(
          crashed,
          'a.json',
          const Duration(minutes: 45),
        );
        final checked = <int>[];

        await SnapshotDiskHandoff(
          tempDir: tmp,
          isProcessAlive: (owner) async {
            checked.add(owner);
            return false;
          },
        ).sweepStaleProcessDirs();

        expect(checked, [99999906]);
        expect(stale.existsSync(), isFalse);
        expect(crashed.existsSync(), isFalse);
      });

      test('keeps young files and other files of a process that is gone, and '
          'the directory with them', () async {
        final crashed = Directory('${tmp.path}/sleuth_snapshot_99999907')
          ..createSync();
        final stale = handoffFile(
          crashed,
          'old.json',
          const Duration(minutes: 45),
        );
        final young = handoffFile(
          crashed,
          'new.json',
          const Duration(minutes: 5),
        );
        final other = handoffFile(
          crashed,
          'keep.txt',
          const Duration(hours: 2),
        );

        await SnapshotDiskHandoff(
          tempDir: tmp,
          isProcessAlive: (_) async => false,
        ).sweepStaleProcessDirs();

        expect(stale.existsSync(), isFalse);
        expect(young.existsSync(), isTrue);
        expect(other.existsSync(), isTrue);
        expect(crashed.existsSync(), isTrue);
      });

      test('keeps every file of a process that still runs', () async {
        final live = Directory('${tmp.path}/sleuth_snapshot_99999908')
          ..createSync();
        final old = handoffFile(live, 'a.json', const Duration(hours: 3));

        await SnapshotDiskHandoff(
          tempDir: tmp,
          isProcessAlive: (_) async => true,
        ).sweepStaleProcessDirs();

        expect(old.existsSync(), isTrue);
        expect(live.existsSync(), isTrue);
      });

      test('a liveness check that throws keeps the files', () async {
        final unknown = Directory('${tmp.path}/sleuth_snapshot_99999909')
          ..createSync();
        final old = handoffFile(unknown, 'a.json', const Duration(hours: 3));

        await SnapshotDiskHandoff(
          tempDir: tmp,
          isProcessAlive: (_) async => throw StateError('no ps'),
        ).sweepStaleProcessDirs();

        expect(old.existsSync(), isTrue);
      });

      test('the default liveness check sees this process and not a pid that '
          'cannot exist', () async {
        expect(await defaultProcessAliveCheck(pid), isTrue);
        // Above the largest pid Linux and macOS hand out.
        expect(await defaultProcessAliveCheck(99999910), isFalse);
      }, testOn: '!windows');
    });

    test('POSIX file mode is 0600', () async {
      if (Platform.isWindows) return;
      final h = SnapshotDiskHandoff(tempDir: tmp);
      final path = (await h.write(envelope()))['path'] as String;
      final stat = FileStat.statSync(path);
      // mode & 0x1FF isolates the permission bits.
      expect(
        stat.mode & 0x1FF,
        0x180, // 0600
        reason: 'handoff file must be owner-read/write only',
      );
    });
  });
}
