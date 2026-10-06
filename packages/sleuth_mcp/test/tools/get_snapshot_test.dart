import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/mcp/tool_call_context.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

/// A connected bridge whose `ext.sleuth.snapshot` projects like the app.
Future<FakeVmBridge> _projectingBridge({
  Map<String, Object?>? data,
  bool isVmConnected = true,
}) async {
  final bridge = defaultFakeBridge()
    ..setResponder(
      'ext.sleuth.snapshot',
      projectingSnapshotResponder(
        data ?? fullFakeSnapshotData(isVmConnected: isVmConnected),
      ),
    );
  await bridge.connect(Uri.parse('ws://localhost/ws'));
  return bridge;
}

Future<Object> _call(FakeVmBridge bridge, Map<String, Object?> args) =>
    builtInTools['get_snapshot']!.handler(bridge, args);

Map<String, Object?> _data(Object result) =>
    (result as Map<String, Object?>)['data'] as Map<String, Object?>;

Map<String, dynamic> _sentArgs(FakeVmBridge bridge) =>
    bridge.callLog.lastWhere((c) => c.method == 'ext.sleuth.snapshot').args;

void main() {
  // deleteFiles, not cleanupAll: cleanupAll is the exit cleanup and makes
  // every later write in this isolate fail.
  tearDown(snapshotDiskHandoff.deleteFiles);

  group('section lists', () {
    test('default and heavy sets split the 14 sections with no overlap', () {
      expect(snapshotSectionKeys, hasLength(14));
      expect(snapshotSectionKeys.toSet(), hasLength(14));
      expect({
        ...defaultSnapshotSections,
        ...heavySnapshotSections,
      }, snapshotSectionKeys.toSet());
      expect(
        defaultSnapshotSections.toSet().intersection(
          heavySnapshotSections.toSet(),
        ),
        isEmpty,
      );
      expect(
        heavySnapshotSections,
        containsAll(<String>['capturedFrames', 'recentFrames']),
      );
      expect(
        defaultSnapshotSections,
        containsAll(<String>['currentIssues', 'frameStatsSummary']),
        reason: 'compare_snapshots and check_budgets read these two',
      );
    });
  });

  group('default projection', () {
    test('no args asks the app for the default sections and says what it '
        'left out', () async {
      final bridge = await _projectingBridge();
      final result = await _call(bridge, {});
      expect(_sentArgs(bridge), {
        'sections': defaultSnapshotSections.join(','),
      });
      final data = _data(result);
      for (final section in heavySnapshotSections) {
        expect(data.containsKey(section), isFalse, reason: section);
      }
      for (final section in defaultSnapshotSections) {
        expect(data.containsKey(section), isTrue, reason: section);
      }
      expect(data['_projectionApplied'], 'by_app');
      expect(
        data['_projectedSections'],
        List<String>.of(defaultSnapshotSections)..sort(),
      );
      expect(data['_omittedSections'], heavySnapshotSections);
      expect(data['_omittedSectionsHint'], contains('full: true'));
      expect(data['isVmConnected'], isTrue, reason: 'metadata always returns');
    });

    test('an empty sections list gets the default set', () async {
      final bridge = await _projectingBridge();
      final data = _data(await _call(bridge, {'sections': <String>[]}));
      expect(_sentArgs(bridge)['sections'], defaultSnapshotSections.join(','));
      expect(data['_omittedSections'], heavySnapshotSections);
    });

    test('currentIssues stay compact by default', () async {
      final bridge = await _projectingBridge();
      final issues = (_data(await _call(bridge, {}))['currentIssues'] as List)
          .cast<Map<String, Object?>>();
      expect(issues, hasLength(2));
      expect(issues.first['stableId'], 'jank_detected');
      expect(issues.first.containsKey('rankingScore'), isFalse);
      expect(issues.first.containsKey('title'), isTrue);
    });

    test('maxIssueCount combines with the default set', () async {
      final bridge = await _projectingBridge();
      final data = _data(await _call(bridge, {'maxIssueCount': 1}));
      expect(_sentArgs(bridge), {
        'sections': defaultSnapshotSections.join(','),
        'maxIssueCount': '1',
      });
      expect(data['currentIssues'], hasLength(1));
      expect(data['_omittedSections'], heavySnapshotSections);
    });

    test('an app that ignores projection gets the default cut from the '
        'sidecar', () async {
      final bridge = defaultFakeBridge()
        ..setEnvelope('ext.sleuth.snapshot', {
          'connectionMode': 'full',
          'schemaVersion': 1,
          'sessionUuid': 'fake-uuid',
          'data': fullFakeSnapshotData(),
        });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final data = _data(await _call(bridge, {}));
      for (final section in heavySnapshotSections) {
        expect(data.containsKey(section), isFalse, reason: section);
      }
      expect(data.containsKey('currentIssues'), isTrue);
      expect(data['packageVersion'], '0.37.0');
      expect(data['_projectionApplied'], 'by_sidecar_fallback');
      expect(
        data['_projectedSections'],
        List<String>.of(defaultSnapshotSections)..sort(),
      );
      expect(data['_omittedSections'], heavySnapshotSections);
    });

    test('compare_snapshots accepts two default snapshots', () async {
      final bridge = await _projectingBridge();
      final before = _data(await _call(bridge, {}));
      final after = _data(await _call(bridge, {}));
      final diff = await builtInTools['compare_snapshots']!.handler(bridge, {
        'before': before,
        'after': after,
      });
      expect(diff, isA<Map<String, Object?>>(), reason: '$diff');
      final map = diff as Map<String, Object?>;
      expect(map['added'], isEmpty);
      expect(map['fpsDelta'], 0.0);
    });

    test('check_budgets and sleuth_check read every section they need from '
        'a default snapshot', () async {
      final bridge = await _projectingBridge();
      final data = _data(await _call(bridge, {}));
      final result = evaluateBudgets(
        snapshot: data,
        minFps: 30,
        maxIssues: 10,
        maxCriticalIssues: 5,
      );
      expect(result, isA<Map<String, Object?>>(), reason: '$result');
      expect((result as Map<String, Object?>)['passed'], isTrue);
    });
  });

  group('one argument away', () {
    test('full: true sends no sections and returns every section', () async {
      final bridge = await _projectingBridge();
      final data = _data(await _call(bridge, {'full': true}));
      expect(_sentArgs(bridge), isEmpty);
      for (final section in snapshotSectionKeys) {
        expect(data.containsKey(section), isTrue, reason: section);
      }
      expect(data.containsKey('_omittedSections'), isFalse);
      expect(data.containsKey('_projectionApplied'), isFalse);
    });

    test('sections naming a heavy section returns exactly it', () async {
      final bridge = await _projectingBridge();
      final data = _data(
        await _call(bridge, {
          'sections': ['recentFrames', 'capturedFrames'],
        }),
      );
      expect(_sentArgs(bridge), {'sections': 'recentFrames,capturedFrames'});
      expect(data.containsKey('recentFrames'), isTrue);
      expect(data.containsKey('capturedFrames'), isTrue);
      expect(data.containsKey('currentIssues'), isFalse);
      expect(data.containsKey('_omittedSections'), isFalse);
    });

    test('full: false behaves like no argument', () async {
      final bridge = await _projectingBridge();
      final data = _data(await _call(bridge, {'full': false}));
      expect(data['_omittedSections'], heavySnapshotSections);
    });

    test('full: true with sections is an arg_conflict error', () async {
      final bridge = await _projectingBridge();
      final result = await _call(bridge, {
        'full': true,
        'sections': ['currentIssues'],
      });
      final tc = result as ToolCallResult;
      expect(tc.isError, isTrue);
      expect(tc.content.first['text'] as String, startsWith('arg_conflict:'));
      expect(
        bridge.callLog.where((c) => c.method == 'ext.sleuth.snapshot'),
        isEmpty,
      );
    });
  });

  group('through tools/call', () {
    Future<Map<String, Object?>> serverCall(
      McpServer server,
      Map<String, Object?> args,
    ) async {
      final resp = await server.handleForTest(
        JsonRpcMessage(
          method: 'tools/call',
          params: {'name': 'get_snapshot', 'arguments': args},
          id: 2,
        ),
      );
      return resp!.result as Map<String, Object?>;
    }

    Future<McpServer> initialized(FakeVmBridge bridge) async {
      final server = McpServer(bridge: bridge)..registerDefaults();
      await server.handleForTest(
        JsonRpcMessage(
          method: 'initialize',
          params: const {'protocolVersion': '2025-06-18'},
          id: 1,
        ),
      );
      return server;
    }

    test('the sections enum rejects an unknown section', () async {
      final server = await initialized(await _projectingBridge());
      final result = await serverCall(server, {
        'sections': ['currentIssues', 'bogus'],
      });
      expect(result['isError'], isTrue);
      final text = ((result['content'] as List).first as Map)['text'] as String;
      expect(text, startsWith('arg_enum_violation: sections[1]=bogus'));
    });

    test('a non-string section is a type mismatch', () async {
      final server = await initialized(await _projectingBridge());
      final result = await serverCall(server, {
        'sections': [3],
      });
      final text = ((result['content'] as List).first as Map)['text'] as String;
      expect(text, startsWith('arg_type_mismatch: sections[0]'));
    });

    test('the default response on measured captures fits a 25k-token budget '
        'with text and structuredContent', () async {
      final captures = _sleuthSnapshotCaptures();
      if (captures.isEmpty) {
        markTestSkipped('sleuth repo captures not found');
        return;
      }
      for (final capture in captures) {
        final full =
            jsonDecode(capture.readAsStringSync()) as Map<String, Object?>;
        final bridge = await _projectingBridge(data: full);
        final server = await initialized(bridge);
        final defaultBytes = utf8
            .encode(jsonEncode(await serverCall(server, {})))
            .length;
        final fullBytes = utf8
            .encode(jsonEncode(await serverCall(server, {'full': true})))
            .length;
        // 25k tokens at a conservative 2.5 bytes per token of JSON.
        expect(
          defaultBytes,
          lessThan(62500),
          reason: '${capture.path}: default response is $defaultBytes bytes',
        );
        expect(fullBytes, greaterThan(defaultBytes * 5), reason: capture.path);
      }
    });
  });

  group('disk handoff', () {
    test('diskHandoff without sections writes every section', () async {
      final bridge = await _projectingBridge();
      final result =
          await _call(bridge, {'diskHandoff': true}) as Map<String, Object?>;
      expect(_sentArgs(bridge), isEmpty);
      expect(result.containsKey('data'), isFalse);
      final written =
          jsonDecode(File(result['path'] as String).readAsStringSync())
              as Map<String, Object?>;
      final data = written['data'] as Map<String, Object?>;
      expect(data.containsKey('recentFrames'), isTrue);
      expect(data.containsKey('_omittedSections'), isFalse);
      expect(result['sizeBytes'], isA<int>());
      expect(result['sha256'], isA<String>());
    });

    test('diskHandoff with sections against an app that ignores projection '
        'stamps by_sidecar_fallback', () async {
      // defaultFakeBridge returns a snapshot WITHOUT _projectedSections,
      // like an app that predates projection support.
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final result =
          await _call(bridge, {
                'diskHandoff': true,
                'sections': ['currentIssues'],
              })
              as Map<String, Object?>;
      expect(result['_projectionApplied'], 'by_sidecar_fallback');
      expect(result.containsKey('path'), isTrue);
    });

    test('a diskHandoff call the client cancelled while the snapshot was '
        'read writes no file', () async {
      final bridge = await _projectingBridge();
      final gate = bridge.gateExtension('ext.sleuth.snapshot');
      final context = ToolCallContext();
      final pending = context.run(() => _call(bridge, {'diskHandoff': true}));
      await Future<void>.delayed(Duration.zero);
      context.cancel();
      gate.complete();
      final result = await pending;
      expect(result, isA<ToolCallResult>());
      final text = (result as ToolCallResult).content.first['text'] as String;
      expect(text, startsWith('cancelled:'));
      final processDir = Directory(
        '${Directory.systemTemp.path}/sleuth_snapshot_$pid',
      );
      final written = processDir.existsSync()
          ? processDir.listSync().where((e) => e.path.endsWith('.json'))
          : const <FileSystemEntity>[];
      expect(written, isEmpty);
    });

    test('a handoff whose file cannot be written returns disk_handoff_failed '
        'instead of throwing', () async {
      final tmp = Directory.systemTemp.createTempSync('sleuth_handoff_fs_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      // A plain file where the process directory belongs makes every write
      // fail with a FileSystemException, as a write does when another
      // sidecar's startup sweep removes the directory under it.
      File('${tmp.path}/sleuth_snapshot_$pid').writeAsStringSync('x');
      final result = await writeSnapshotHandoff(
        SnapshotDiskHandoff(tempDir: tmp),
        {'data': <String, Object?>{}},
      );
      expect(result, isA<ToolCallResult>());
      final failure = result as ToolCallResult;
      expect(failure.isError, isTrue);
      expect(
        failure.content.first['text'] as String,
        startsWith('disk_handoff_failed:'),
      );
    });

    test('a handoff after the exit cleanup returns disk_handoff_failed and '
        'writes nothing', () async {
      final tmp = Directory.systemTemp.createTempSync('sleuth_handoff_exit_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final handoff = SnapshotDiskHandoff(tempDir: tmp)..cleanupAll();
      final result = await writeSnapshotHandoff(handoff, {
        'data': <String, Object?>{},
      });
      expect(
        (result as ToolCallResult).content.first['text'] as String,
        startsWith('disk_handoff_failed:'),
      );
      expect(tmp.listSync(), isEmpty);
    });

    test('diskHandoff:true with an app ERROR envelope surfaces the error '
        'inline, never a file pointer', () async {
      final bridge = FakeVmBridge(fakeSessionUuid: 'u')
        ..setEnvelope('ext.sleuth.diagnose', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'u',
          'data': {'packageVersion': '0.37.0'},
        })
        ..setEnvelope('ext.sleuth.snapshot', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'u',
          'error': 'arg_invalid_section: "bogus" is not a known section',
        });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final result =
          await _call(bridge, {
                'diskHandoff': true,
                'sections': ['bogus'],
              })
              as Map<String, Object?>;
      expect(result.containsKey('error'), isTrue);
      expect(
        result.containsKey('path'),
        isFalse,
        reason: 'error envelopes must never be disk-handed-off',
      );
    });
  });

  group('caller projection against an app that ignores it', () {
    for (final args in <Map<String, Object?>>[
      {
        'sections': ['currentIssues'],
      },
      {'maxIssueCount': 1},
    ]) {
      test('inline $args returns projection_unsupported_by_app', () async {
        final bridge = defaultFakeBridge();
        await bridge.connect(Uri.parse('ws://localhost/ws'));
        final result = await _call(bridge, args);
        final tc = result as ToolCallResult;
        expect(tc.isError, isTrue);
        expect(
          tc.content.first['text'] as String,
          startsWith('projection_unsupported_by_app:'),
        );
      });
    }
  });

  test('verbose:true keeps full currentIssues fields', () async {
    final bridge = await _projectingBridge();
    final data = _data(await _call(bridge, {'verbose': true}));
    final issues = (data['currentIssues'] as List).cast<Map<String, Object?>>();
    expect(issues.first.containsKey('rankingScore'), isTrue);
  });
}

/// The on-device snapshot captures in the sleuth repo
/// (`test/validation/captures/mcp_snapshots/`), or none outside the repo.
List<File> _sleuthSnapshotCaptures() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final captures = Directory(
      '${dir.path}/test/validation/captures/mcp_snapshots',
    );
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (captures.existsSync() &&
        pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: sleuth\n')) {
      return captures
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return const [];
}
