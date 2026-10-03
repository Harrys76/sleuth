import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/utils/issue_explanation_builder.dart';
import 'package:sleuth/src/vm/service_extension_handlers.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';
import 'package:vm_service/vm_service.dart';

const _config = SleuthConfig(
  treeScanInterval: Duration(seconds: 1),
  enabledDetectors: {DetectorType.frameTiming},
);

SleuthController _newController() {
  final c = SleuthController(config: _config);
  addTearDown(c.dispose);
  return c;
}

PerformanceIssue _issue({
  String stableId = 'jank_detected',
  String title = 'Test issue',
  String? routeName,
  String? sourceRoute,
  IssueSeverity severity = IssueSeverity.warning,
}) => PerformanceIssue(
  severity: severity,
  category: IssueCategory.build,
  confidence: IssueConfidence.likely,
  title: title,
  detail: 'detail',
  fixHint: 'fix',
  stableId: stableId,
  routeName: routeName,
  sourceRoute: sourceRoute,
);

const _envelopeKeys = {'connectionMode', 'schemaVersion', 'sessionUuid'};

// Matches an unsubstituted `{placeholder}` token. Bare braces in code
// examples (e.g. `Widget build(context) {`) are legitimate text.
final _placeholder = RegExp(r'\{[a-zA-Z]+\}');

Iterable<String> _stringValues(Map<String, Object?> explanation) =>
    explanation.values.whereType<String>();

void main() {
  group('envelope shape', () {
    test('envelopeOk stamps mandatory keys + data', () {
      final c = _newController();
      final env = envelopeOk(controller: c, data: {'x': 1});
      expect(env.keys, containsAll(_envelopeKeys));
      expect(env['schemaVersion'], kMcpEnvelopeSchemaVersion);
      expect(env['sessionUuid'], c.sessionUuid);
      expect(env['data'], {'x': 1});
    });

    test('envelopeError stamps error + optional extras', () {
      final c = _newController();
      final env = envelopeError(
        controller: c,
        error: 'bad_thing',
        extra: {'route': '/foo'},
      );
      expect(env['error'], 'bad_thing');
      expect(env['route'], '/foo');
      expect(env.keys, containsAll(_envelopeKeys));
    });
  });

  group('sanitizeForJson', () {
    test('passes scalars and collections of scalars through', () {
      expect(sanitizeForJson(null), null);
      expect(sanitizeForJson(1), 1);
      expect(sanitizeForJson('s'), 's');
      expect(sanitizeForJson(true), true);
      expect(sanitizeForJson([1, 'a', null]), [1, 'a', null]);
      expect(sanitizeForJson({'k': 'v', 'n': 2}), {'k': 'v', 'n': 2});
    });

    test('coerces non-string map keys to strings', () {
      final out = sanitizeForJson({1: 'a', 'two': 'b'}) as Map<String, Object?>;
      expect(out['1'], 'a');
      expect(out['two'], 'b');
    });

    test('cyclic map replaced with __cycle envelope, no overflow', () {
      final m = <String, Object?>{'name': 'root'};
      m['self'] = m;
      final out = sanitizeForJson(m) as Map<String, Object?>;
      expect(out['name'], 'root');
      final inner = out['self'] as Map<String, Object?>;
      expect(inner['__cycle'], true);
      expect(inner['repr'], isA<String>());
      // Round-trip through jsonEncode to prove encodability.
      expect(() => jsonEncode(out), returnsNormally);
    });

    test('cyclic list replaced with __cycle envelope', () {
      final l = <Object?>[];
      l.add(l);
      final out = sanitizeForJson(l) as List<Object?>;
      final inner = out.first as Map<String, Object?>;
      expect(inner['__cycle'], true);
    });

    test('non-serialisable leaf replaced with __nonSerializable envelope', () {
      int fn() => 1;
      final out = sanitizeForJson({'fn': fn}) as Map<String, Object?>;
      final wrap = out['fn'] as Map<String, Object?>;
      expect(wrap['__nonSerializable'], isA<String>());
      expect(wrap['repr'], isA<String>());
      expect(() => jsonEncode(out), returnsNormally);
    });

    test('repr is truncated to 1024 characters + ellipsis', () {
      final huge = _OversizedNonEncodable('x' * 4096);
      final out = sanitizeForJson(huge) as Map<String, Object?>;
      final repr = out['repr'] as String;
      // 1024 visible chars + 1 ellipsis char.
      expect(repr.length, 1025);
      expect(repr.endsWith('…'), isTrue);
    });

    test('deeply nested non-cyclic payload truncates at depth cap', () {
      Map<String, Object?> nest = <String, Object?>{'leaf': 0};
      for (var i = 0; i < 400; i++) {
        nest = <String, Object?>{'k': nest};
      }
      final out = sanitizeForJson(nest);
      expect(() => jsonEncode(out), returnsNormally);
      // Walk down the result until we hit the truncation envelope.
      Object? cur = out;
      var depth = 0;
      while (cur is Map<String, Object?> &&
          cur['__truncated'] != true &&
          depth < 500) {
        cur = cur['k'];
        depth++;
      }
      expect(cur, isA<Map<String, Object?>>());
      final envelope = cur as Map<String, Object?>;
      expect(envelope['__truncated'], isTrue);
      expect(envelope['depth'], isA<int>());
    });

    test('Iterable (Set) emits as JSON array instead of nonSerializable', () {
      final out = sanitizeForJson({1, 2, 3});
      expect(out, isA<List<Object?>>());
      final list = (out as List<Object?>).toList()..sort();
      expect(list, [1, 2, 3]);
    });

    test('Identity-based cycle detection — equal-but-distinct maps do '
        'not falsely cycle', () {
      // Two distinct map instances with identical contents. Default
      // Set<Object> would see them as equal; the sanitiser must use
      // identity equality so neither is mis-flagged as a cycle.
      final a = <String, Object?>{'k': 1};
      final b = <String, Object?>{'k': 1};
      final parent = <String, Object?>{'a': a, 'b': b};
      final out = sanitizeForJson(parent) as Map<String, Object?>;
      expect((out['a'] as Map)['k'], 1);
      expect((out['b'] as Map)['k'], 1);
      expect((out['a'] as Map).containsKey('__cycle'), isFalse);
      expect((out['b'] as Map).containsKey('__cycle'), isFalse);
    });

    test('Non-string Map keys colliding after stringify emit '
        '__keyCollision envelope', () {
      final out =
          sanitizeForJson({1: 'first', '1': 'second'}) as Map<String, Object?>;
      final collision = out['1'] as Map<String, Object?>;
      expect(collision['__keyCollision'], isTrue);
      expect(collision['prior'], 'first');
      expect(collision['next'], 'second');
    });
  });

  group('handlers — envelope discipline', () {
    test('snapshot stamps envelope and emits data payload', () async {
      final c = _newController();
      final env = await extSnapshotHandler(c, const {});
      expect(env.keys, containsAll(_envelopeKeys));
      expect(env['data'], isA<Map<String, Object?>>());
      expect(() => jsonEncode(env), returnsNormally);
    });

    test('issues without route returns full list', () async {
      final c = _newController();
      c.seedIssuesForTest([
        _issue(stableId: 'jank_detected', routeName: '/a'),
        _issue(stableId: 'heap_growing', routeName: '/b'),
      ]);
      final env = await extIssuesHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      final issues = data['issues'] as List;
      expect(issues, hasLength(2));
      expect(data.containsKey('route'), isFalse);
    });

    test('issues with route filters by routeName + sourceRoute', () async {
      final c = _newController();
      c.seedIssuesForTest([
        _issue(stableId: 'jank_detected', routeName: '/a'),
        _issue(stableId: 'heap_growing', routeName: '/b'),
        _issue(stableId: 'gc_pressure', sourceRoute: '/a'),
      ]);
      final env = await extIssuesHandler(c, const {'route': '/a'});
      final data = env['data'] as Map<String, Object?>;
      final issues = data['issues'] as List;
      expect(issues, hasLength(2));
      expect(data['route'], '/a');
    });

    test(
      'routeHealth without arg returns empty list when no history',
      () async {
        final c = _newController();
        final env = await extRouteHealthHandler(c, const {});
        final data = env['data'] as Map<String, Object?>;
        expect(data['routes'], isEmpty);
      },
    );

    test('routeHealth with unknown route returns error envelope', () async {
      final c = _newController();
      final env = await extRouteHealthHandler(c, const {'route': '/missing'});
      expect(env['error'], 'unknown_route');
      expect(env['route'], '/missing');
    });

    test('explain missing stableId returns missing_required_arg', () async {
      final c = _newController();
      final env = await extExplainHandler(c, const {});
      expect(env['error'], 'missing_required_arg');
      expect(env['arg'], 'stableId');
    });

    test('explain unknown stableId returns unknown_stable_id', () async {
      final c = _newController();
      final env = await extExplainHandler(c, const {'stableId': 'no_such_id'});
      expect(env['error'], 'unknown_stable_id');
      expect(env['stableId'], 'no_such_id');
      expect(env['canonical'], 'no_such_id');
    });

    test('explain resolves parametric stableId through canonicalId', () async {
      final c = _newController();
      final base = IssueExplanationBuilder.allExplanations.keys.first;
      // Pick a parametric form by appending :42 if base accepts it; otherwise
      // dynamic suffix variant. Fall back to the base id itself if neither.
      final parametricKey = '$base:42';
      final env = await extExplainHandler(c, {'stableId': parametricKey});
      expect(env['error'], isNull);
      final data = env['data'] as Map<String, Object?>;
      expect(data['canonical'], base);
      expect(data['stableId'], parametricKey);
      expect(data['explanation'], isA<Map<String, Object?>>());
    });

    test('encyclopedia returns count + entries map', () async {
      final c = _newController();
      final env = await extEncyclopediaHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      expect(data['count'], IssueExplanationBuilder.allExplanations.length);
      expect(data['entries'], isA<Map<String, Object?>>());
    });

    test('explain without a live issue uses neutral placeholders', () async {
      final c = _newController();
      final env = await extExplainHandler(c, const {
        'stableId': 'non_lazy_list',
      });
      final data = env['data'] as Map<String, Object?>;
      final explanation = data['explanation'] as Map<String, Object?>;
      expect(explanation['whatItIs'], contains('N children'));
      for (final value in _stringValues(explanation)) {
        expect(value, isNot(contains('{')));
      }
    });

    test('explain fills placeholders from the matching live issue', () async {
      final c = _newController();
      c.seedIssuesForTest([
        _issue(
          stableId: 'non_lazy_listview',
          title: 'ListView with 120 children',
        ),
      ]);
      final env = await extExplainHandler(c, const {
        'stableId': 'non_lazy_listview',
      });
      final data = env['data'] as Map<String, Object?>;
      expect(data['canonical'], 'non_lazy_list');
      final explanation = data['explanation'] as Map<String, Object?>;
      expect(explanation['whatItIs'], contains('120'));
    });

    test('encyclopedia entries carry no unsubstituted placeholders', () async {
      final c = _newController();
      final env = await extEncyclopediaHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      final entries = data['entries'] as Map<String, Object?>;
      for (final entry in entries.entries) {
        final explanation = entry.value as Map<String, Object?>;
        for (final value in _stringValues(explanation)) {
          expect(
            _placeholder.hasMatch(value),
            isFalse,
            reason: '${entry.key}: $value',
          );
        }
      }
    });

    test('causalGraph returns pre-serialised rules', () async {
      final c = _newController();
      final env = await extCausalGraphHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      expect(data['count'], isA<int>());
      final rules = data['rules'] as List;
      expect(rules, isNotEmpty);
      final first = rules.first as Map<String, Object?>;
      expect(first.keys, containsAll({'trigger', 'effect'}));
    });

    test('diagnose carries packageVersion + sessionUuid + flags', () async {
      final c = _newController();
      final env = await extDiagnoseHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      expect(data['packageVersion'], kSleuthPackageVersion);
      expect(data['vmConnected'], isFalse);
      expect(data.containsKey('captureMode'), isTrue);
      expect(data.containsKey('lastCaptureExportFailure'), isTrue);
      expect(env['sessionUuid'], c.sessionUuid);
    });

    test('diagnose poll keys are null before the first poll and ints '
        'after', () async {
      const pollKeys = [
        'lastPollRpcMicros',
        'lastPollParseMicros',
        'lastPollDispatchMicros',
        'lastPollTailMicros',
        'lastPollEventCount',
        'lastPollResponseChars',
        'maxPollRpcMicros',
        'maxPollParseMicros',
        'maxPollDispatchMicros',
        'pollDuplicatesDropped',
      ];
      final c = _newController();
      final client = VmServiceClient();
      client.setServiceForTest(_TimelineOnlyService(), isolateId: 'i-1');
      c.setVmClientForTest(client);

      var data =
          (await extDiagnoseHandler(c, const {}))['data']
              as Map<String, Object?>;
      for (final key in pollKeys) {
        expect(data.containsKey(key), isTrue, reason: key);
        expect(data[key], isNull, reason: key);
      }

      await client.pollTimelineSync();

      data =
          (await extDiagnoseHandler(c, const {}))['data']
              as Map<String, Object?>;
      for (final key in pollKeys) {
        expect(data[key], isA<int>(), reason: key);
      }
      expect(data['lastPollEventCount'], 1);
      expect(data['pollDuplicatesDropped'], 0);
    });
  });

  group('handlers — JSON round-trip', () {
    test('every handler envelope is jsonEncode-able', () async {
      final c = _newController();
      c.seedIssuesForTest([_issue()]);
      final handlers = <Future<Map<String, Object?>> Function()>[
        () async => await extSnapshotHandler(c, const {}),
        () async => await extIssuesHandler(c, const {}),
        () async => await extRouteHealthHandler(c, const {}),
        () async =>
            await extExplainHandler(c, const {'stableId': 'jank_detected'}),
        () async => await extEncyclopediaHandler(c, const {}),
        () async => await extCausalGraphHandler(c, const {}),
        () async => await extDiagnoseHandler(c, const {}),
      ];
      for (final h in handlers) {
        final env = await h();
        expect(() => jsonEncode(env), returnsNormally);
      }
    });
  });
}

/// Object whose toString() exceeds the 1 KB repr cap. Used to verify the
/// sanitizer's truncation path.
class _OversizedNonEncodable {
  _OversizedNonEncodable(this.payload);
  final String payload;
  @override
  String toString() => payload;
}

/// Answers the timeline poll only; every other member is unimplemented.
class _TimelineOnlyService implements VmService {
  @override
  Future<Timeline> getVMTimeline({
    int? timeOriginMicros,
    int? timeExtentMicros,
  }) async => Timeline(
    traceEvents: [
      TimelineEvent.parse({
        'name': 'Build',
        'ph': 'X',
        'dur': 100,
        'ts': 1000,
        'pid': 1,
        'tid': 1,
      })!,
    ],
    timeOriginMicros: 0,
    timeExtentMicros: 0,
  );

  @override
  Future<Success> clearVMTimeline() async => Success();

  @override
  Future<Timestamp> getVMTimelineMicros() async => Timestamp(timestamp: 5000);

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
