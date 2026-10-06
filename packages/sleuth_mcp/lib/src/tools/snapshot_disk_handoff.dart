import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../util/owned_process.dart' show OwnedProcessRunner;

/// Whether a process with this pid is running. The startup sweep deletes
/// the handoff files of a sidecar only once its process is gone.
typedef ProcessAliveCheck = Future<bool> Function(int pid);

/// Default [ProcessAliveCheck]. On Linux it reads `/proc/<pid>`; elsewhere
/// on POSIX it runs `ps -p <pid>`, bounded at 2 seconds, which exits 1 when
/// no such process exists. Windows is not checked. Whenever the answer is
/// unclear, the process counts as alive, so its files stay.
Future<bool> defaultProcessAliveCheck(int pid) async {
  if (Platform.isWindows) return true;
  if (Platform.isLinux) return Directory('/proc/$pid').existsSync();
  try {
    final result = await OwnedProcessRunner().run('ps', [
      '-p',
      '$pid',
    ], timeout: const Duration(seconds: 2));
    return result.exitCode != 1;
  } catch (_) {
    return true;
  }
}

/// Writes large snapshot envelopes to a temp file so the MCP response
/// can carry a `{path, sizeBytes, sha256}` pointer instead of inline
/// JSON that would blow the client's per-response token cap.
///
/// Files are tracked in [_written] for cleanup on detach / shutdown and
/// swept by age on each new write.
class SnapshotDiskHandoff {
  SnapshotDiskHandoff({
    Directory? tempDir,
    Duration? maxAge,
    ProcessAliveCheck? isProcessAlive,
  }) : _maxAge = maxAge ?? const Duration(minutes: 30),
       _isProcessAlive = isProcessAlive ?? defaultProcessAliveCheck {
    // Per-process subdir so a concurrent sidecar instance's age-sweep
    // can never delete this instance's in-flight handoff (each instance
    // only sweeps its own dir).
    _baseDir = tempDir ?? Directory.systemTemp;
    _sessionDir = Directory('${_baseDir.path}/$_prefix$pid');
  }

  late final Directory _baseDir;
  late final Directory _sessionDir;
  final Duration _maxAge;
  final ProcessAliveCheck _isProcessAlive;
  final Set<String> _written = <String>{};

  /// Set by [cleanupAll]. Every later [write] fails, so a `get_snapshot`
  /// call still running when the sidecar exits cannot leave a file behind.
  bool _closed = false;

  static const _prefix = 'sleuth_snapshot_';
  static final _processDirName = RegExp(r'^sleuth_snapshot_\d+$');
  final _rng = Random.secure();

  String _uuid() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Serialize [envelope] to a fresh temp file. Returns the handoff
  /// pointer envelope `{path, sizeBytes, sha256}` plus any projection
  /// metadata copied from the inner `data` block. Sweeps aged files
  /// in this instance's own dir first so a long-running session can't
  /// accumulate orphans.
  ///
  /// Throws [StateError] after [cleanupAll], or when the directory or the
  /// file cannot be made owner-only, and [FileSystemException] when the
  /// file cannot be written.
  Future<Map<String, Object?>> write(Map<String, Object?> envelope) async {
    if (_closed) {
      throw StateError(
        'the sidecar is shutting down and already deleted its handoff '
        'files, so it writes no new ones',
      );
    }
    final json = const JsonEncoder().convert(envelope);
    final bytes = utf8.encode(json);

    // The payload can carry sensitive data (e.g. recentRequests[].url with
    // query tokens/IDs), so the dir + file must be owner-only BEFORE any
    // bytes land — verify and fail closed rather than ship a pointer to a
    // world-readable file.
    _ensureSecureDir();
    _sweepAged();
    File file;
    try {
      file = _writeNewFile(bytes);
    } on FileSystemException {
      // Another sidecar's startup sweep removes this directory when it is
      // empty and old, which can happen between the check above and the
      // write. Create it again once.
      if (_sessionDir.existsSync()) rethrow;
      _ensureSecureDir();
      file = _writeNewFile(bytes);
    }
    _chmod600OrFailClosed(file);
    _written.add(file.path);

    final data = envelope['data'];
    final meta = data is Map<String, Object?>
        ? data
        : const <String, Object?>{};

    return <String, Object?>{
      'path': file.path,
      'sizeBytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      if (meta.containsKey('_projectedSections'))
        '_projectedSections': meta['_projectedSections'],
      if (meta.containsKey('_projectionLimits'))
        '_projectionLimits': meta['_projectionLimits'],
      if (meta.containsKey('_projectionApplied'))
        '_projectionApplied': meta['_projectionApplied'],
    };
  }

  /// Writes [bytes] to a new file with a random name in this process's
  /// directory. O_EXCL-style: regenerate on the (cryptographically
  /// improbable) collision rather than overwrite a file we don't own.
  File _writeNewFile(List<int> bytes) {
    var attempts = 0;
    while (true) {
      final file = File('${_sessionDir.path}/${_uuid()}.json');
      if (!file.existsSync()) {
        file.writeAsBytesSync(bytes, flush: true);
        return file;
      }
      if (++attempts > 3) {
        throw StateError('could not allocate a unique snapshot temp path');
      }
    }
  }

  /// Deletes every file this instance wrote, then this process's directory
  /// when nothing else is left in it. Later writes still work. `detach_app`
  /// calls it.
  void deleteFiles() {
    for (final path in _written.toList()) {
      _deleteQuietly(File(path));
    }
    _written.clear();
    _deleteDirIfEmpty(_sessionDir);
  }

  /// Final cleanup when the sidecar exits: [deleteFiles], and every later
  /// [write] throws [StateError].
  void cleanupAll() {
    _closed = true;
    deleteFiles();
  }

  /// Removes what earlier sidecar processes left in the temp directory. Run
  /// once at startup. Never throws.
  ///
  /// It looks only at `sleuth_snapshot_<pid>` directories with a numeric
  /// pid, never this process's own. Before its first await it removes the
  /// empty ones last modified longer ago than the handoff max age (30
  /// minutes by default). In a non-empty one whose process is gone, which
  /// happens when a sidecar crashed or was killed, it then deletes the
  /// `.json` handoff files older than the max age, and the directory once
  /// it is empty. A directory whose process may still run keeps its files;
  /// on Windows the default check never reports a process as gone.
  Future<void> sweepStaleProcessDirs() async {
    try {
      await _sweepStaleProcessDirs();
    } catch (_) {
      // Best effort: what a failed sweep leaves, the next start sweeps.
    }
  }

  Future<void> _sweepStaleProcessDirs() async {
    final now = DateTime.now();
    final List<FileSystemEntity> entries;
    try {
      entries = _baseDir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    final occupied = <(Directory, int)>[];
    for (final entity in entries) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments.lastWhere(
        (s) => s.isNotEmpty,
        orElse: () => '',
      );
      if (!_processDirName.hasMatch(name)) continue;
      if (entity.path == _sessionDir.path) continue;
      final owner = int.tryParse(name.substring(_prefix.length));
      try {
        if (entity.listSync(followLinks: false).isNotEmpty) {
          if (owner != null) occupied.add((entity, owner));
          continue;
        }
        if (now.difference(entity.statSync().modified) <= _maxAge) continue;
      } on FileSystemException {
        continue;
      }
      _deleteDirIfEmpty(entity);
    }
    for (final (dir, owner) in occupied) {
      bool alive;
      try {
        alive = await _isProcessAlive(owner);
      } catch (_) {
        alive = true;
      }
      if (alive) continue;
      _deleteAgedFiles(dir);
      _deleteDirIfEmpty(dir);
    }
  }

  /// Deletes the `.json` files in [dir] last modified longer ago than the
  /// handoff max age.
  void _deleteAgedFiles(Directory dir) {
    final now = DateTime.now();
    final List<FileSystemEntity> files;
    try {
      files = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entity in files) {
      if (entity is! File || !entity.path.endsWith('.json')) continue;
      try {
        if (now.difference(entity.statSync().modified) > _maxAge) {
          _deleteQuietly(entity);
        }
      } on FileSystemException {
        // Best effort: a file that cannot be read or removed stays.
      }
    }
  }

  /// Deletes [dir] when it exists and holds nothing. A non-recursive
  /// delete fails on a non-empty directory, so a file that lands between
  /// the check and the delete is never removed.
  void _deleteDirIfEmpty(Directory dir) {
    try {
      if (!dir.existsSync()) return;
      if (dir.listSync(followLinks: false).isNotEmpty) return;
      dir.deleteSync();
    } on FileSystemException {
      // Best effort: a directory that cannot be removed stays.
    }
  }

  void _sweepAged() {
    if (!_sessionDir.existsSync()) return;
    final now = DateTime.now();
    final List<FileSystemEntity> entries;
    try {
      entries = _sessionDir.listSync();
    } on FileSystemException {
      return;
    }
    // Own per-pid dir — every `.json` here is this instance's. Safe to
    // sweep by age without a filename prefix check.
    for (final entity in entries) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.json')) continue;
      try {
        if (now.difference(entity.statSync().modified) > _maxAge) {
          _deleteQuietly(entity);
          _written.remove(entity.path);
        }
      } on FileSystemException {
        // ignore — best effort
      }
    }
  }

  /// Create the per-pid dir owner-only (0700) and verify it. On POSIX,
  /// if the mode can't be set + verified, throw — we won't write
  /// sensitive content into a loose dir. On Windows (no POSIX mode) the
  /// dir is created without verification (documented limitation).
  void _ensureSecureDir() {
    if (!_sessionDir.existsSync()) {
      _sessionDir.createSync(recursive: true);
    }
    if (Platform.isWindows) return;
    _chmod(_sessionDir.path, '700');
    final mode = _sessionDir.statSync().mode & 0x1FF;
    if (mode != 0x1C0) {
      throw StateError(
        'the snapshot temp dir is not 0700 (mode=${mode.toRadixString(8)}), '
        'so the sidecar does not write the snapshot, which may hold '
        'sensitive data',
      );
    }
  }

  /// chmod the just-written file to 0600 and verify. On POSIX failure,
  /// delete the file and throw — never return a pointer to a file we
  /// could not lock down. Windows: skip (no POSIX mode).
  void _chmod600OrFailClosed(File file) {
    if (Platform.isWindows) return;
    _chmod(file.path, '600');
    final mode = file.statSync().mode & 0x1FF;
    if (mode != 0x180) {
      _deleteQuietly(file);
      throw StateError(
        'the snapshot temp file is not 0600 '
        '(mode=${mode.toRadixString(8)}), so the sidecar deleted it and '
        'refuses the handoff',
      );
    }
  }

  void _chmod(String path, String mode) {
    try {
      Process.runSync('chmod', [mode, path]);
    } on ProcessException {
      // chmod unavailable (stripped PATH) — the FileStat verify below
      // catches the un-locked-down state and fails closed.
    }
  }

  void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // ignore — best effort
    }
  }
}
