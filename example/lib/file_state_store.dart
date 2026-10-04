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

  @override
  Future<String?> read() async =>
      await _file.exists() ? _file.readAsString() : null;

  @override
  Future<void> write(String json) async {
    // Write then rename, so a crash mid-write never leaves half a file.
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(json, flush: true);
    await tmp.rename(_file.path);
  }
}
