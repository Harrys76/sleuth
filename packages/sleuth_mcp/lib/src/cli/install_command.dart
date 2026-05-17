import 'dart:io';

import 'config_writer.dart';

/// Default MCP server name written under `mcpServers.<name>` in
/// `~/.claude.json`.
const String defaultMcpServerName = 'sleuth';

/// Default executable resolution — when sleuth_mcp is installed via
/// `dart pub global activate sleuth_mcp`, this is the canonical entry.
Map<String, Object?> defaultMcpEntry() => <String, Object?>{
      'command': 'sleuth_mcp',
      'args': <String>[],
    };

/// Resolve target config file. Default: `<home>/.claude.json` for
/// Claude Code. Caller can override (project-local config, tests).
File defaultConfigFile() {
  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home == null || home.isEmpty) {
    throw StateError(
        'cannot resolve home directory — set HOME (or USERPROFILE on Windows)');
  }
  return File('$home/.claude.json');
}

class InstallCommandResult {
  InstallCommandResult({required this.exitCode, required this.message});
  final int exitCode;
  final String message;
}

/// Run the `install` / `uninstall` subcommand. Pure function — caller
/// (the bin entrypoint) prints [InstallCommandResult.message] and
/// `exit`s with [InstallCommandResult.exitCode]. No global state.
Future<InstallCommandResult> runInstallCommand({
  required List<String> args,
  File? configFile,
  String name = defaultMcpServerName,
  Map<String, Object?>? entry,
}) async {
  bool remove = false;
  for (final a in args) {
    if (a == '--remove' || a == '--uninstall') {
      remove = true;
    } else if (a == '--help' || a == '-h') {
      return InstallCommandResult(
        exitCode: 0,
        message: _usage(),
      );
    } else if (a.startsWith('-')) {
      return InstallCommandResult(
        exitCode: 64,
        message: 'unknown flag: $a\n\n${_usage()}',
      );
    }
  }

  final file = configFile ?? defaultConfigFile();
  final writer = ConfigWriter(configFile: file);

  try {
    if (remove) {
      final r = await writer.remove(name: name);
      switch (r.outcome) {
        case ConfigWriteOutcome.removed:
          return InstallCommandResult(
            exitCode: 0,
            message: 'removed mcpServers.$name from ${r.configPath} '
                '(backup: ${r.backupPath})',
          );
        case ConfigWriteOutcome.notFound:
          return InstallCommandResult(
            exitCode: 0,
            message: 'mcpServers.$name not present in ${r.configPath} — '
                'nothing to remove',
          );
        default:
          return InstallCommandResult(
            exitCode: 1,
            message: 'unexpected outcome: ${r.outcome}',
          );
      }
    }

    final r = await writer.install(
      name: name,
      entry: entry ?? defaultMcpEntry(),
    );
    switch (r.outcome) {
      case ConfigWriteOutcome.added:
        return InstallCommandResult(
          exitCode: 0,
          message: 'added mcpServers.$name to ${r.configPath} '
              '(backup: ${r.backupPath ?? "<new file>"})',
        );
      case ConfigWriteOutcome.updated:
        return InstallCommandResult(
          exitCode: 0,
          message: 'updated mcpServers.$name in ${r.configPath} '
              '(backup: ${r.backupPath})',
        );
      case ConfigWriteOutcome.alreadyPresent:
        return InstallCommandResult(
          exitCode: 0,
          message: 'mcpServers.$name already up to date in ${r.configPath}',
        );
      default:
        return InstallCommandResult(
          exitCode: 1,
          message: 'unexpected outcome: ${r.outcome}',
        );
    }
  } on ConfigWriteException catch (e) {
    return InstallCommandResult(exitCode: 1, message: e.message);
  }
}

String _usage() => '''
sleuth_mcp install   register sleuth as an MCP server in ~/.claude.json
sleuth_mcp install --remove   remove the registration
''';
