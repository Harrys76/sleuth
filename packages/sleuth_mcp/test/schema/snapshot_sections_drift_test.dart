@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

/// The sidecar package root: the directory holding a `pubspec.yaml` named
/// `sleuth_mcp` and `doc/mcp_schema.json`.
Directory _packageDir() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: sleuth_mcp\n') &&
        File('${dir.path}/doc/mcp_schema.json').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('sleuth_mcp package root not found from cwd');
}

/// `lib/src/models/snapshot_sections.dart` of the sleuth package, when the
/// sidecar runs inside the sleuth repo.
File? _sleuthEnumSource() {
  var dir = _packageDir();
  for (var i = 0; i < 4; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    final source = File('${dir.path}/lib/src/models/snapshot_sections.dart');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: sleuth\n') &&
        source.existsSync()) {
      return source;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  test('snapshotSectionKeys matches the ext.sleuth.snapshot payload keys in '
      'doc/mcp_schema.json both ways', () {
    final schema =
        jsonDecode(
              File(
                '${_packageDir().path}/doc/mcp_schema.json',
              ).readAsStringSync(),
            )
            as Map<String, Object?>;
    final data =
        ((schema['handlers'] as Map<String, Object?>)['ext.sleuth.snapshot']
                as Map<String, Object?>)['data']
            as Map<String, Object?>;
    final documented = <String>{
      for (final entry in data.entries)
        if (entry.value is Map &&
            !entry.key.startsWith('_') &&
            !snapshotMetadataKeys.contains(entry.key))
          entry.key,
    };
    final mirrored = snapshotSectionKeys.toSet();
    expect(
      mirrored,
      documented,
      reason:
          'sidecar-only: ${mirrored.difference(documented)}\n'
          'schema-only: ${documented.difference(mirrored)}',
    );
    for (final key in snapshotMetadataKeys) {
      expect(data.containsKey(key), isTrue, reason: 'metadata key $key');
    }
  });

  test('snapshotSectionKeys matches the SnapshotSection enum in the sleuth '
      'source, in order', () {
    final source = _sleuthEnumSource();
    if (source == null) {
      markTestSkipped('sleuth source not found; the doc check still runs');
      return;
    }
    final text = source.readAsStringSync();
    final body = RegExp(
      r'enum\s+SnapshotSection\s*\{([^;]*);',
    ).firstMatch(text);
    expect(body, isNotNull, reason: 'enum SnapshotSection not found');
    final names = RegExp(r'([a-zA-Z]+)\s*,?')
        .allMatches(body!.group(1)!.replaceAll(RegExp(r'//[^\n]*'), ''))
        .map((m) => m.group(1)!)
        .toList();
    expect(names, snapshotSectionKeys);
  });
}
