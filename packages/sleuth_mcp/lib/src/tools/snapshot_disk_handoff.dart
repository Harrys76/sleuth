import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Writes large snapshot envelopes to a temp file so the MCP response
/// can carry a `{path, sizeBytes, sha256}` pointer instead of inline
/// JSON that would blow the client's per-response token cap.
///
/// Files are tracked in [_written] for cleanup on detach / shutdown and
/// swept by age on each new write.
class SnapshotDiskHandoff {
  SnapshotDiskHandoff({Directory? tempDir, Duration? maxAge})
    : _maxAge = maxAge ?? const Duration(minutes: 30) {
    // Per-process subdir so a concurrent sidecar instance's age-sweep
    // can never delete this instance's in-flight handoff (each instance
    // only sweeps its own dir).
    _baseDir = tempDir ?? Directory.systemTemp;
    _sessionDir = Directory('${_baseDir.path}/$_prefix$pid');
  }

  late final Directory _baseDir;
  late final Directory _sessionDir;
  final Duration _maxAge;
  final Set<String> _written = <String>{};

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
  Future<Map<String, Object?>> write(Map<String, Object?> envelope) async {
    // The payload can carry sensitive data (e.g. recentRequests[].url with
    // query tokens/IDs), so the dir + file must be owner-only BEFORE any
    // bytes land — verify and fail closed rather than ship a pointer to a
    // world-readable file.
    _ensureSecureDir();
    _sweepAged();

    final json = const JsonEncoder().convert(envelope);
    final bytes = utf8.encode(json);

    // O_EXCL-style: regenerate on the (cryptographically improbable)
    // collision rather than overwrite a file we don't own.
    File file;
    var attempts = 0;
    while (true) {
      file = File('${_sessionDir.path}/${_uuid()}.json');
      if (!file.existsSync()) break;
      if (++attempts > 3) {
        throw StateError('could not allocate a unique snapshot temp path');
      }
    }

    file.writeAsBytesSync(bytes, flush: true);
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

  /// Delete every file this instance wrote, then this process's directory
  /// when nothing else is left in it. Called on detach + shutdown.
  void cleanupAll() {
    for (final path in _written.toList()) {
      _deleteQuietly(File(path));
    }
    _written.clear();
    _deleteDirIfEmpty(_sessionDir);
  }

  /// Removes the empty `sleuth_snapshot_<pid>` directories that earlier
  /// sidecar processes left in the temp directory. Only directories with
  /// this prefix and a numeric pid, never this process's own, only when
  /// empty, and only when last modified longer ago than the handoff max
  /// age (30 minutes by default). Run once at startup. Never throws.
  void sweepStaleProcessDirs() {
    final now = DateTime.now();
    final List<FileSystemEntity> entries;
    try {
      entries = _baseDir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entity in entries) {
      if (entity is! Directory) continue;
      final name = entity.uri.pathSegments.lastWhere(
        (s) => s.isNotEmpty,
        orElse: () => '',
      );
      if (!_processDirName.hasMatch(name)) continue;
      if (entity.path == _sessionDir.path) continue;
      try {
        if (now.difference(entity.statSync().modified) <= _maxAge) continue;
      } on FileSystemException {
        continue;
      }
      _deleteDirIfEmpty(entity);
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
    // Own per-pid dir — every `.json` here is this instance's. Safe to
    // sweep by age without a filename prefix check.
    for (final entity in _sessionDir.listSync()) {
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
        'snapshot temp dir is not 0700 (mode=${mode.toRadixString(8)}); '
        'refusing to write potentially-sensitive snapshot data',
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
        'snapshot temp file is not 0600 (mode=${mode.toRadixString(8)}); '
        'deleted and refusing the handoff',
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
