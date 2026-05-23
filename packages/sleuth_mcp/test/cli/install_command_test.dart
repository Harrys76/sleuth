import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File config;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sleuth_mcp_cli_');
    config = File('${tmp.path}/.claude.json');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  test('install (fresh) writes default entry, exit 0', () async {
    final r = await runInstallCommand(args: const [], configFile: config);
    expect(r.exitCode, 0);
    expect(r.message, contains('added mcpServers.sleuth'));
    final root =
        jsonDecode(await config.readAsString()) as Map<String, Object?>;
    final entry = (root['mcpServers'] as Map<String, Object?>)['sleuth']
        as Map<String, Object?>;
    expect(entry['command'], 'sleuth_mcp');
  });

  test('install (re-run) is idempotent — exit 0 + alreadyPresent', () async {
    await runInstallCommand(args: const [], configFile: config);
    final r = await runInstallCommand(args: const [], configFile: config);
    expect(r.exitCode, 0);
    expect(r.message, contains('already up to date'));
  });

  test('install --remove on present entry → exit 0', () async {
    await runInstallCommand(args: const [], configFile: config);
    final r = await runInstallCommand(
      args: const ['--remove'],
      configFile: config,
    );
    expect(r.exitCode, 0);
    expect(r.message, contains('removed mcpServers.sleuth'));
  });

  test('install --remove when missing → exit 0 with "nothing to remove"',
      () async {
    final r = await runInstallCommand(
      args: const ['--remove'],
      configFile: config,
    );
    expect(r.exitCode, 0);
    expect(r.message, contains('nothing to remove'));
  });

  test('install --help → exit 0 with usage', () async {
    final r = await runInstallCommand(
      args: const ['--help'],
      configFile: config,
    );
    expect(r.exitCode, 0);
    expect(r.message, contains('sleuth_mcp install'));
  });

  test('unknown flag → exit 64', () async {
    final r = await runInstallCommand(
      args: const ['--banana'],
      configFile: config,
    );
    expect(r.exitCode, 64);
    expect(r.message, contains('unknown flag'));
  });

  test('non-JSON-object config surfaces ConfigWriteException → exit 1',
      () async {
    await config.writeAsString('"not an object"');
    final r = await runInstallCommand(args: const [], configFile: config);
    expect(r.exitCode, 1);
    expect(r.message, contains('not a JSON object'));
  });

  test('custom entry overrides default', () async {
    final r = await runInstallCommand(
      args: const [],
      configFile: config,
      entry: {'command': '/abs/path/sleuth_mcp', 'args': const <String>[]},
    );
    expect(r.exitCode, 0);
    final root =
        jsonDecode(await config.readAsString()) as Map<String, Object?>;
    final entry = (root['mcpServers'] as Map<String, Object?>)['sleuth']
        as Map<String, Object?>;
    expect(entry['command'], '/abs/path/sleuth_mcp');
  });
}
