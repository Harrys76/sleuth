import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Outcome of `install` / `remove` against a Claude Code-style MCP config.
enum ConfigWriteOutcome { added, updated, alreadyPresent, removed, notFound }

class ConfigWriteResult {
  ConfigWriteResult({
    required this.outcome,
    required this.configPath,
    this.backupPath,
  });
  final ConfigWriteOutcome outcome;
  final String configPath;
  final String? backupPath;
}

class ConfigWriteException implements Exception {
  ConfigWriteException(this.message);
  final String message;
  @override
  String toString() => 'ConfigWriteException: $message';
}

/// Idempotent JSON merge for Claude Code's `~/.claude.json`
/// `mcpServers.<name>` map. Acquires an OS advisory lock on a sidecar
/// `.lock` file so concurrent installs don't shred the JSON. Writes to
/// `<file>.tmp` then renames so a crash mid-write doesn't leave a
/// half-written config.
class ConfigWriter {
  ConfigWriter(
      {required this.configFile,
      this.lockTimeout = const Duration(seconds: 5)});

  /// The file to read/modify — usually `<home>/.claude.json`.
  final File configFile;
  final Duration lockTimeout;

  /// Lock lives in a local cache dir — advisory locking is unreliable
  /// on userland file-provider filesystems (iCloud Drive, network shares).
  File get _lockFile {
    final cache = Platform.environment['XDG_CACHE_HOME'] ??
        '${Platform.environment['HOME'] ?? Directory.systemTemp.path}/.cache';
    final slug = Uri.encodeComponent(configFile.absolute.path);
    return File('$cache/sleuth_mcp/$slug.lock');
  }

  /// Install (or update) `mcpServers.<name>` to [entry]. Returns
  /// [ConfigWriteOutcome.alreadyPresent] when the existing entry matches
  /// byte-for-byte (no rewrite, no backup churn).
  Future<ConfigWriteResult> install({
    required String name,
    required Map<String, Object?> entry,
  }) async {
    return _withLock(() async {
      final root = await _readRoot();
      final servers = _serversMap(root);
      final existing = servers[name];
      if (existing is Map<String, Object?> && _deepEquals(existing, entry)) {
        return ConfigWriteResult(
          outcome: ConfigWriteOutcome.alreadyPresent,
          configPath: configFile.path,
        );
      }
      final outcome = existing == null
          ? ConfigWriteOutcome.added
          : ConfigWriteOutcome.updated;
      servers[name] = entry;
      root['mcpServers'] = servers;
      final backupPath = await _writeAtomic(root);
      return ConfigWriteResult(
        outcome: outcome,
        configPath: configFile.path,
        backupPath: backupPath,
      );
    });
  }

  Future<ConfigWriteResult> remove({required String name}) async {
    return _withLock(() async {
      if (!await configFile.exists()) {
        return ConfigWriteResult(
          outcome: ConfigWriteOutcome.notFound,
          configPath: configFile.path,
        );
      }
      final root = await _readRoot();
      final servers = _serversMap(root);
      if (!servers.containsKey(name)) {
        return ConfigWriteResult(
          outcome: ConfigWriteOutcome.notFound,
          configPath: configFile.path,
        );
      }
      servers.remove(name);
      root['mcpServers'] = servers;
      final backupPath = await _writeAtomic(root);
      return ConfigWriteResult(
        outcome: ConfigWriteOutcome.removed,
        configPath: configFile.path,
        backupPath: backupPath,
      );
    });
  }

  Future<Map<String, Object?>> _readRoot() async {
    if (!await configFile.exists()) {
      return <String, Object?>{};
    }
    final raw = await configFile.readAsString();
    if (raw.trim().isEmpty) return <String, Object?>{};
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, Object?>) {
      throw ConfigWriteException(
        'config at ${configFile.path} is not a JSON object (got ${decoded.runtimeType}) — refusing to overwrite',
      );
    }
    return Map<String, Object?>.from(decoded);
  }

  Map<String, Object?> _serversMap(Map<String, Object?> root) {
    final raw = root['mcpServers'];
    if (raw == null) return <String, Object?>{};
    if (raw is! Map) {
      throw ConfigWriteException(
        'mcpServers exists but is not an object (got ${raw.runtimeType})',
      );
    }
    return Map<String, Object?>.from(
      raw.map((k, v) => MapEntry(k.toString(), v)),
    );
  }

  Future<String?> _writeAtomic(Map<String, Object?> root) async {
    final encoded = const JsonEncoder.withIndent('  ').convert(root);
    // Resolve symlinks so `.tmp` lands intra-volume; rename stays atomic
    // and iCloud-symlinked configs don't trigger EXDEV.
    final targetPath = await _resolvedTargetPath();
    final targetDir = File(targetPath).parent;
    final basename = targetPath.split(Platform.pathSeparator).last;
    final tmp = File('${targetDir.path}${Platform.pathSeparator}$basename.tmp');
    final bak = File('${targetDir.path}${Platform.pathSeparator}$basename.bak');

    String? backupPath;
    final existing = File(targetPath);
    if (await existing.exists()) {
      await existing.copy(bak.path);
      backupPath = bak.path;
    }
    await tmp.writeAsString('$encoded\n', flush: true);
    await tmp.rename(targetPath);
    return backupPath;
  }

  /// Real on-disk path so `.tmp` lands on the right volume. Falls back
  /// to the original path when the target doesn't exist yet.
  Future<String> _resolvedTargetPath() async {
    if (!await configFile.exists()) return configFile.absolute.path;
    try {
      return await configFile.resolveSymbolicLinks();
    } on FileSystemException {
      return configFile.absolute.path;
    }
  }

  Future<T> _withLock<T>(Future<T> Function() body) async {
    final configParent = configFile.parent;
    if (!await configParent.exists()) {
      await configParent.create(recursive: true);
    }
    final lockParent = _lockFile.parent;
    if (!await lockParent.exists()) {
      await lockParent.create(recursive: true);
    }
    final raf = await _lockFile.open(mode: FileMode.write);
    final deadline = DateTime.now().add(lockTimeout);
    while (true) {
      try {
        await raf.lock(FileLock.exclusive);
        break;
      } on FileSystemException {
        if (DateTime.now().isAfter(deadline)) {
          await raf.close();
          throw ConfigWriteException(
            'could not acquire lock on ${_lockFile.path} within ${lockTimeout.inSeconds}s — another install in progress?',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    try {
      return await body();
    } finally {
      try {
        await raf.unlock();
      } catch (_) {/* ignore */}
      await raf.close();
      try {
        await _lockFile.delete();
      } catch (_) {/* best effort */}
    }
  }

  bool _deepEquals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final k in a.keys) {
        if (!b.containsKey(k)) return false;
        if (!_deepEquals(a[k], b[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }
}
