import 'dart:convert';
import 'dart:io';

import 'package:sleuth/sleuth.dart';

/// Keeps the Sleuth overlay state (trigger position, card geometry,
/// hidden issues, severity filter) in a JSON file, so it survives app
/// restarts.
///
/// Uses the system temp directory to avoid a `path_provider` dependency;
/// the OS may clear it, which only resets the overlay to its defaults. An
/// app would usually store this under its documents or support directory.
class FileSleuthStateStore implements SleuthStateStore {
  FileSleuthStateStore([File? file])
    : _file =
          file ??
          File('${Directory.systemTemp.path}/sleuth_overlay_state.json');

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
