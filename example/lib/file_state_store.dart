import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sleuth/sleuth.dart';

/// Keeps the Sleuth overlay state (trigger position, card geometry,
/// hidden issues, severity filter) in a JSON file, so it survives app
/// restarts and new installs of the app.
///
/// The file goes in the directory [overlayStateDirectory] picks, to avoid
/// a `path_provider` dependency. An app would usually ask `path_provider`
/// for its application support directory.
class FileSleuthStateStore implements SleuthStateStore {
  FileSleuthStateStore([File? file])
    : _file = file ?? File('${_defaultDirectory.path}/$_fileName');

  static const _fileName = 'sleuth_overlay_state.json';

  static Directory get _defaultDirectory =>
      overlayStateDirectory(Directory.systemTemp, Platform.operatingSystem);

  final File _file;

  /// Writes started, numbering each write's temp file.
  int _started = 0;

  /// The newest write whose file replaced the saved one.
  int _promoted = 0;

  /// Renames run one at a time, in order.
  Future<void> _renames = Future<void>.value();

  @override
  Future<String?> read() async {
    if (!await _file.exists()) return null;
    // Decoded here rather than by readAsString, which reports bad bytes as
    // a file system error: a read error turns saving off for the session,
    // while contents that are not UTF-8 are just unreadable, so the
    // overlay starts from defaults and the next change replaces them.
    final bytes = await _file.readAsBytes();
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(String json) async {
    // Each write fills its own temp file, then renames it over the saved
    // one, so a crash mid-write never leaves half a file. The controller
    // gives up on a write after a few seconds but cannot cancel it; with
    // a shared temp file a stalled write and the next one could interleave.
    // Renames are queued, and one older than the newest promoted write is
    // dropped, so a late write never replaces newer state.
    final sequence = ++_started;
    await _file.parent.create(recursive: true);
    final tmp = File('${_file.path}.$sequence.tmp');
    await tmp.writeAsString(json, flush: true);
    final rename = _renames.then((_) async {
      if (sequence < _promoted) {
        await tmp.delete();
        return;
      }
      _promoted = sequence;
      await tmp.rename(_file.path);
    });
    _renames = rename.catchError((Object _) {});
    await rename;
  }
}

/// The directory [FileSleuthStateStore] keeps its file in by default, from
/// the system temp directory [temp] on [operatingSystem]
/// (`Platform.operatingSystem`).
///
/// On Android the temp directory is the app's `code_cache`, which every
/// install of a new build empties, and on iOS it is the container's `tmp`,
/// which the OS empties when it needs space. The file goes beside them in
/// the app's own `files` and `Library/Application Support` directories.
/// Elsewhere, or when the temp directory is not where these layouts put
/// it, the temp directory itself is used.
@visibleForTesting
Directory overlayStateDirectory(Directory temp, String operatingSystem) {
  final segments = temp.uri.pathSegments.where((s) => s.isNotEmpty);
  final name = segments.isEmpty ? null : segments.last;
  final app = temp.parent.path;
  return switch ((operatingSystem, name)) {
    ('android', 'code_cache') => Directory('$app/files'),
    ('ios', 'tmp') => Directory('$app/Library/Application Support'),
    _ => temp,
  };
}
