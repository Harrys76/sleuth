import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' as io;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Three-line discovery file at `$HOME/.sleuth/vm_service_uri_<pid>`
/// (POSIX) or `%USERPROFILE%\.sleuth\vm_service_uri_<pid>` (Windows):
///
/// ```
/// sleuth-discovery-v1
/// <session-uuid>
/// <ws://127.0.0.1:PORT/<auth>=/ws>
/// ```
///
/// URI's `<auth>` path segment is the live VM service credential. Hardening:
/// directory created with mode 0700; file written via tempfile created at
/// 0600 then atomically renamed; pre-existing symlink at the destination
/// is unlinked before rename. Liveness is mtime-based — `Process.killPid`
/// is unsafe (delivers signals).
class DiscoveryFile {
  DiscoveryFile._();

  static const String formatTag = 'sleuth-discovery-v1';
  static const String _dirName = '.sleuth';
  static const String _filePrefix = 'vm_service_uri_';
  static const String _tempSuffix = '.in_progress';
  static final RegExp _sweepFilePattern = RegExp(r'^vm_service_uri_\d+$');
  static const Duration _staleAge = Duration(hours: 24);
  static const int _sweepCap = 50;
  static const Duration _sweepTimeout = Duration(seconds: 1);

  static bool _missingHomeWarned = false;

  /// Test-only directory override. Reads are `kDebugMode`-gated.
  @visibleForTesting
  static String? testDirectoryOverride;

  /// Write the discovery file for the current process via tempfile +
  /// atomic rename. Returns the absolute path on success, `null` if the
  /// home directory is unresolved or [shouldCommit] vetoes the rename.
  /// Sweep races a [_sweepTimeout] so a slow home doesn't block.
  static Future<String?> write({
    required Uri webSocketUri,
    required int pid,
    required String sessionUuid,
    bool Function()? shouldCommit,
  }) async {
    final dir = _resolveDirectory();
    if (dir == null) return null;
    try {
      final dirEntity = io.Directory(dir);
      if (!await dirEntity.exists()) {
        await dirEntity.create(recursive: true);
      }
      await _chmod700(dir);
    } catch (e, st) {
      developer.log(
        'DiscoveryFile: could not create $dir',
        error: e,
        stackTrace: st,
      );
      return null;
    }

    unawaited(
      Future.any<void>([
        _sweep(dir),
        Future.delayed(_sweepTimeout),
      ]).catchError((Object e, StackTrace st) {
        developer.log(
          'DiscoveryFile: sweep failed (non-fatal)',
          error: e,
          stackTrace: st,
        );
      }),
    );

    final destPath = p.join(dir, '$_filePrefix$pid');
    final tempPath = p.join(dir, '.$_filePrefix$pid$_tempSuffix');
    final content = '$formatTag\n$sessionUuid\n${webSocketUri.toString()}\n';
    try {
      // Create tempfile at 0600 BEFORE writing URI content (POSIX); on
      // Windows the home directory ACL handles privacy.
      await _createPrivateFile(tempPath);
      final tempFile = io.File(tempPath);
      await tempFile.writeAsString(content, flush: true);

      // Veto point — caller can abort the rename if state changed mid-write.
      if (shouldCommit != null && !shouldCommit()) {
        try {
          await tempFile.delete();
        } catch (_) {/* best effort */}
        return null;
      }

      // Unlink a pre-existing symlink at the destination so the rename
      // doesn't redirect the URI through it.
      try {
        final destStat = io.FileSystemEntity.typeSync(
          destPath,
          followLinks: false,
        );
        if (destStat == io.FileSystemEntityType.link) {
          await io.Link(destPath).delete();
        }
      } catch (_) {/* best effort */}

      await tempFile.rename(destPath);
      return destPath;
    } catch (e, st) {
      developer.log(
        'DiscoveryFile: write failed at $destPath',
        error: e,
        stackTrace: st,
      );
      // Clean up the tempfile if it's still around.
      try {
        final tmp = io.File(tempPath);
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {/* best effort */}
      return null;
    }
  }

  /// Delete the discovery file for [pid] if present.
  static void delete(int pid) {
    final dir = _resolveDirectory();
    if (dir == null) return;
    final path = p.join(dir, '$_filePrefix$pid');
    try {
      final file = io.File(path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {
      // Best effort.
    }
  }

  /// Run the stale-file sweep. Exposed for tests; production callers go
  /// through [write], which races a 1s timeout against this.
  @visibleForTesting
  static Future<void> sweepNow() async {
    final dir = _resolveDirectory();
    if (dir == null) return;
    await _sweep(dir);
  }

  static String? _resolveDirectory() {
    if (kDebugMode && testDirectoryOverride != null) {
      return testDirectoryOverride;
    }
    final home = io.Platform.environment['HOME'] ??
        io.Platform.environment['USERPROFILE'];
    if (home == null || home.isEmpty) {
      if (!_missingHomeWarned) {
        _missingHomeWarned = true;
        developer.log(
          'DiscoveryFile: HOME / USERPROFILE not set — MCP sidecar must '
          'use --uri to connect.',
        );
      }
      return null;
    }
    return p.join(home, _dirName);
  }

  static Future<void> _sweep(String dir) async {
    // Timeout race flips this so destructive deletes short-circuit.
    final cancelled = _CancellationFlag();
    scheduleMicrotask(() async {
      await Future.delayed(_sweepTimeout);
      cancelled.value = true;
    });

    final entity = io.Directory(dir);
    if (!entity.existsSync()) return;
    final stream = entity.list(followLinks: false);
    final entries = <io.File>[];
    await for (final e in stream) {
      if (cancelled.value) return;
      if (e is! io.File) continue;
      if (!_sweepFilePattern.hasMatch(p.basename(e.path))) continue;
      entries.add(e);
    }
    if (entries.isEmpty) return;

    final selfName = '$_filePrefix${io.pid}';
    final now = DateTime.now();
    final survivors = <io.File>[];
    for (final f in entries) {
      if (cancelled.value) return;
      try {
        final stat = await f.stat();
        if (now.difference(stat.modified) >= _staleAge) {
          // Self file may be aged but is still live; the sidecar's UUID
          // cross-check is the second line of defense.
          if (p.basename(f.path) == selfName) {
            survivors.add(f);
            continue;
          }
          if (cancelled.value) return;
          try {
            await f.delete();
          } catch (_) {/* best effort */}
        } else {
          survivors.add(f);
        }
      } catch (_) {
        // Skip entries we can't stat (e.g. concurrently unlinked).
      }
    }

    if (survivors.length <= _sweepCap) return;

    // Cap-overflow deletion must never touch the current pid's file.
    final deletable =
        survivors.where((f) => p.basename(f.path) != selfName).toList();
    if (deletable.length <= _sweepCap) return;
    final stats = <io.File, DateTime>{};
    for (final f in deletable) {
      try {
        stats[f] = (await f.stat()).modified;
      } catch (_) {
        stats[f] = DateTime.fromMillisecondsSinceEpoch(0);
      }
    }
    deletable.sort((a, b) => stats[a]!.compareTo(stats[b]!));
    final overflow = deletable.length - _sweepCap;
    for (var i = 0; i < overflow; i++) {
      if (cancelled.value) return;
      try {
        await deletable[i].delete();
      } catch (_) {/* best effort */}
    }
  }

  /// Create an empty file at [path] mode 0600 (POSIX via `install`),
  /// or touch (Windows) where the parent ACL handles privacy.
  static Future<void> _createPrivateFile(String path) async {
    if (io.Platform.isWindows) {
      final f = io.File(path);
      if (!f.existsSync()) {
        await f.writeAsString('');
      }
      return;
    }
    try {
      final result = await io.Process.run(
        'install',
        ['-m', '600', '/dev/null', path],
      );
      if (result.exitCode == 0) return;
    } catch (_) {/* fall through */}
    // Fallback: write then chmod. Parent dir is 0700, so the race is bounded.
    final f = io.File(path);
    await f.writeAsString('');
    try {
      await io.Process.run('chmod', ['600', path]);
    } catch (_) {/* best effort */}
  }

  static Future<void> _chmod700(String dir) async {
    if (io.Platform.isWindows) return;
    try {
      await io.Process.run('chmod', ['700', dir]);
    } catch (_) {/* best effort */}
  }

  @visibleForTesting
  static void resetMissingHomeWarnedForTest() {
    _missingHomeWarned = false;
  }
}

class _CancellationFlag {
  bool value = false;
}
