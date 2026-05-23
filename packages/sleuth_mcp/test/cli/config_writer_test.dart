import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late File config;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sleuth_mcp_cfg_');
    config = File('${tmp.path}/.claude.json');
  });

  tearDown(() async {
    if (await tmp.exists()) {
      await tmp.delete(recursive: true);
    }
  });

  group('ConfigWriter.install', () {
    test('creates config when none exists, writes entry, no backup', () async {
      final w = ConfigWriter(configFile: config);
      final r = await w.install(
        name: 'sleuth',
        entry: {'command': 'sleuth_mcp', 'args': const <String>[]},
      );
      expect(r.outcome, ConfigWriteOutcome.added);
      expect(r.backupPath, isNull);
      expect(await config.exists(), isTrue);
      final root =
          jsonDecode(await config.readAsString()) as Map<String, Object?>;
      expect(root['mcpServers'], isA<Map<String, Object?>>());
      final servers = root['mcpServers'] as Map<String, Object?>;
      expect(
          (servers['sleuth'] as Map<String, Object?>)['command'], 'sleuth_mcp');
    });

    test('preserves unrelated top-level keys', () async {
      await config.writeAsString(jsonEncode({
        'someOtherKey': 'untouched',
        'mcpServers': {
          'preExisting': {'command': 'other-mcp', 'args': const <String>[]},
        },
      }));
      final w = ConfigWriter(configFile: config);
      final r = await w.install(
        name: 'sleuth',
        entry: {'command': 'sleuth_mcp', 'args': const <String>[]},
      );
      expect(r.outcome, ConfigWriteOutcome.added);
      expect(r.backupPath, isNotNull);
      final root =
          jsonDecode(await config.readAsString()) as Map<String, Object?>;
      expect(root['someOtherKey'], 'untouched');
      final servers = root['mcpServers'] as Map<String, Object?>;
      expect(servers.keys, containsAll(['preExisting', 'sleuth']));
    });

    test('idempotent: byte-equal entry returns alreadyPresent, no write',
        () async {
      final entry = {'command': 'sleuth_mcp', 'args': const <String>[]};
      final w = ConfigWriter(configFile: config);
      await w.install(name: 'sleuth', entry: entry);
      final mtimeBefore = await config.lastModified();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final r = await w.install(name: 'sleuth', entry: entry);
      expect(r.outcome, ConfigWriteOutcome.alreadyPresent);
      final mtimeAfter = await config.lastModified();
      expect(mtimeAfter, mtimeBefore,
          reason: 'idempotent reinstall must not rewrite the file');
    });

    test('updated when entry differs', () async {
      final w = ConfigWriter(configFile: config);
      await w.install(
        name: 'sleuth',
        entry: {'command': 'sleuth_mcp', 'args': const <String>[]},
      );
      final r = await w.install(
        name: 'sleuth',
        entry: {
          'command': 'sleuth_mcp',
          'args': const ['--verbose'],
        },
      );
      expect(r.outcome, ConfigWriteOutcome.updated);
      final root =
          jsonDecode(await config.readAsString()) as Map<String, Object?>;
      final entry = (root['mcpServers'] as Map<String, Object?>)['sleuth']
          as Map<String, Object?>;
      expect(entry['args'], ['--verbose']);
    });

    test('refuses non-object top-level config', () async {
      await config.writeAsString('"a-string-not-an-object"');
      final w = ConfigWriter(configFile: config);
      expect(
        () => w.install(name: 'sleuth', entry: const <String, Object?>{}),
        throwsA(isA<ConfigWriteException>()),
      );
    });

    test('refuses non-object mcpServers field', () async {
      await config.writeAsString(jsonEncode({'mcpServers': 'oops'}));
      final w = ConfigWriter(configFile: config);
      expect(
        () => w.install(name: 'sleuth', entry: const <String, Object?>{}),
        throwsA(isA<ConfigWriteException>()),
      );
    });
  });

  group('ConfigWriter.remove', () {
    test('notFound when config missing', () async {
      final w = ConfigWriter(configFile: config);
      final r = await w.remove(name: 'sleuth');
      expect(r.outcome, ConfigWriteOutcome.notFound);
    });

    test('notFound when entry missing', () async {
      await config.writeAsString(jsonEncode({
        'mcpServers': {
          'other': {'command': 'x', 'args': const <String>[]},
        },
      }));
      final w = ConfigWriter(configFile: config);
      final r = await w.remove(name: 'sleuth');
      expect(r.outcome, ConfigWriteOutcome.notFound);
    });

    test('symlinked configFile writes tmp next to resolved target (no EXDEV)',
        () async {
      // Symlinked target (e.g. iCloud-synced ~/.claude.json) requires
      // `.tmp` on the resolved volume so rename stays intra-volume.
      final realDir = await tmp.createTemp('real-');
      final realConfig = File('${realDir.path}/.claude.json');
      await realConfig.writeAsString('{"mcpServers":{}}');
      final linkDir = await tmp.createTemp('link-');
      final symlink = Link('${linkDir.path}/.claude.json');
      await symlink.create(realConfig.path);

      final w = ConfigWriter(configFile: File(symlink.path));
      final r = await w.install(
        name: 'sleuth',
        entry: {'command': 'sleuth_mcp', 'args': const <String>[]},
      );
      expect(r.outcome, ConfigWriteOutcome.added);
      // Resolved target updated, not a sibling file in the symlink dir.
      final raw = await realConfig.readAsString();
      expect(raw, contains('sleuth_mcp'));
      // No leftover .tmp in either directory.
      expect(File('${realDir.path}/.claude.json.tmp').existsSync(), isFalse);
      expect(File('${linkDir.path}/.claude.json.tmp').existsSync(), isFalse);
    });

    test('removes entry, leaves siblings + backups', () async {
      await config.writeAsString(jsonEncode({
        'mcpServers': {
          'sleuth': {'command': 'sleuth_mcp', 'args': const <String>[]},
          'other': {'command': 'x', 'args': const <String>[]},
        },
      }));
      final w = ConfigWriter(configFile: config);
      final r = await w.remove(name: 'sleuth');
      expect(r.outcome, ConfigWriteOutcome.removed);
      expect(r.backupPath, isNotNull);
      final root =
          jsonDecode(await config.readAsString()) as Map<String, Object?>;
      final servers = root['mcpServers'] as Map<String, Object?>;
      expect(servers.keys, ['other']);
    });
  });
}
