import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:sleuth/src/models/phase_event.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

TimelineEvent _makeEvent({
  required String name,
  required int dur,
  int? ts,
  String ph = 'X',
  String cat = '',
  Map<String, dynamic>? args,
}) {
  return TimelineEvent.parse({
    'name': name,
    'cat': cat,
    'ph': ph,
    'dur': dur,
    if (ts != null) 'ts': ts,
    if (args != null) 'args': args,
    'pid': 1,
    'tid': 1,
  })!;
}

void main() {
  group('TimelineParser phaseEvents', () {
    test('populates phaseEvents alongside duration lists', () {
      final events = [
        _makeEvent(name: 'BUILD', dur: 3000, ts: 1000),
        _makeEvent(name: 'LAYOUT', dur: 2000, ts: 5000),
        _makeEvent(name: 'PAINT', dur: 1000, ts: 8000),
        _makeEvent(name: 'GPURasterizer::Draw', dur: 5000, ts: 10000),
        _makeEvent(name: 'ShaderCompilation', dur: 500, ts: 16000),
      ];

      final data = TimelineParser.parse(events);

      // Existing duration lists still populated
      expect(data.buildScopeDurations, [3000]);
      expect(data.flushLayoutDurations, [2000]);
      expect(data.flushPaintDurations, [1000]);
      expect(data.rasterDurations, [5000]);
      expect(data.shaderCompileDurations, [500]);

      // phaseEvents also populated
      expect(data.phaseEvents, hasLength(5));
    });

    test('extracts correct phase, timestamp, and duration', () {
      final events = [
        _makeEvent(name: 'BUILD', dur: 3000, ts: 1000),
      ];

      final data = TimelineParser.parse(events);
      final pe = data.phaseEvents.single;

      expect(pe.phase, TimelinePhase.build);
      expect(pe.timestampUs, 1000);
      expect(pe.durationUs, 3000);
      expect(pe.endUs, 4000);
    });

    test('classifies all phase types correctly', () {
      final events = [
        _makeEvent(name: 'Build', dur: 100, ts: 1000),
        _makeEvent(name: 'Layout', dur: 200, ts: 2000),
        _makeEvent(name: 'Paint', dur: 300, ts: 3000),
        _makeEvent(name: 'Raster', dur: 400, ts: 4000),
        _makeEvent(name: 'shader_compilation', dur: 500, ts: 5000),
      ];

      final data = TimelineParser.parse(events);
      final phases = data.phaseEvents.map((e) => e.phase).toList();

      expect(phases, [
        TimelinePhase.build,
        TimelinePhase.layout,
        TimelinePhase.paint,
        TimelinePhase.raster,
        TimelinePhase.shader,
      ]);
    });

    test('events without ts field do not produce PhaseEvents', () {
      final events = [
        _makeEvent(name: 'BUILD', dur: 3000), // no ts
        _makeEvent(name: 'LAYOUT', dur: 2000, ts: 5000), // has ts
      ];

      final data = TimelineParser.parse(events);

      // Duration lists still get both
      expect(data.buildScopeDurations, [3000]);
      expect(data.flushLayoutDurations, [2000]);

      // Only the event with ts gets a PhaseEvent
      expect(data.phaseEvents, hasLength(1));
      expect(data.phaseEvents.first.phase, TimelinePhase.layout);
    });

    test('non-pipeline events do not produce PhaseEvents', () {
      final events = [
        _makeEvent(
            name: 'Platform Channel send test#invoke', dur: 100, ts: 1000),
        _makeEvent(name: 'GC', dur: 50, ts: 2000, cat: 'gc'),
      ];

      final data = TimelineParser.parse(events);

      expect(data.platformChannelEvents, hasLength(1));
      expect(data.gcEvents, hasLength(1));
      expect(data.phaseEvents, isEmpty);
    });

    test('Begin/End BUILD pairs reconstruct PhaseEvents (iOS profile mode)',
        () {
      // iOS profile-mode emits BUILD as B/E pairs instead of `ph: 'X'`
      // complete events. The parser must reconstruct
      // `dur = E.ts - B.ts` and feed buildScopes / phaseEvents so that
      // HeavyComputeDetector + downstream consumers observe BUILDs on
      // iOS captures the same way they observe X-form BUILDs on
      // Android / desktop.
      final beginEvent = TimelineEvent.parse({
        'name': 'BUILD',
        'cat': '',
        'ph': 'B',
        'ts': 1000,
        'pid': 1,
        'tid': 1,
      })!;
      final endEvent = TimelineEvent.parse({
        'name': 'BUILD',
        'cat': '',
        'ph': 'E',
        'ts': 4000,
        'pid': 1,
        'tid': 1,
      })!;

      final data = TimelineParser.parse([beginEvent, endEvent]);

      // Build count incremented (B-side bumps the counter).
      expect(data.buildEventCount, 1);
      // Reconstructed dur = 4000 - 1000 = 3000us in both buildScopes
      // and phaseEvents.
      expect(data.buildScopeDurations, [3000]);
      expect(data.phaseEvents, hasLength(1));
      expect(data.phaseEvents.first.phase, TimelinePhase.build);
      expect(data.phaseEvents.first.durationUs, 3000);
      expect(data.phaseEvents.first.timestampUs, 1000);
    });

    test('Begin/End BUILD pairs across threads do not cross-contaminate', () {
      // Per-tid stack: B on tid 1 must pair with E on tid 1, NOT with
      // an interleaved E on tid 2. Without per-thread tracking, two
      // concurrent BUILDs would mismatch and reconstruct wrong durs.
      final events = [
        TimelineEvent.parse(
            {'name': 'BUILD', 'ph': 'B', 'ts': 1000, 'tid': 1, 'pid': 1})!,
        TimelineEvent.parse(
            {'name': 'BUILD', 'ph': 'B', 'ts': 1500, 'tid': 2, 'pid': 1})!,
        TimelineEvent.parse(
            {'name': 'BUILD', 'ph': 'E', 'ts': 2000, 'tid': 2, 'pid': 1})!,
        TimelineEvent.parse(
            {'name': 'BUILD', 'ph': 'E', 'ts': 5000, 'tid': 1, 'pid': 1})!,
      ];
      final data = TimelineParser.parse(events);
      // tid 1: 5000 - 1000 = 4000us. tid 2: 2000 - 1500 = 500us.
      expect(data.buildScopeDurations.toSet(), {4000, 500});
    });

    test('phaseEvents defaults to empty list', () {
      final data = ParsedTimelineData();
      expect(data.phaseEvents, isEmpty);
    });

    test('Begin/End BUILD pairs reconstruct across consecutive parse() calls',
        () {
      // iOS profile-mode poll boundary: B in batch N, E in batch N+1.
      // Without cross-batch state the orphan E in batch 2 cannot pair
      // and dur info is lost forever. With shared pendingBuildBegins,
      // batch 2's parse() consumes the carry-over B and reconstructs.
      final pending = <int, List<Map<String, dynamic>>>{};

      // Batch 1: only the B event.
      final batch1 = [
        TimelineEvent.parse(
            {'name': 'BUILD', 'ph': 'B', 'ts': 1000, 'tid': 1, 'pid': 1})!,
      ];
      final data1 = TimelineParser.parse(batch1, pendingBuildBegins: pending);
      expect(data1.buildScopeDurations, isEmpty,
          reason: 'No E yet → no reconstruction in batch 1.');

      // Batch 2: only the matching E event. Should reconstruct.
      final batch2 = [
        TimelineEvent.parse(
            {'name': 'BUILD', 'ph': 'E', 'ts': 5000, 'tid': 1, 'pid': 1})!,
      ];
      final data2 = TimelineParser.parse(batch2, pendingBuildBegins: pending);
      expect(data2.buildScopeDurations, [4000],
          reason: 'Cross-batch E pairs with batch-1 B: 5000 - 1000 = 4000.');
    });

    test('default pendingBuildBegins is fresh per call (backward-compat)', () {
      // Direct callers (32 existing test sites) pass no
      // pendingBuildBegins. Each call must allocate fresh state so
      // batch-1 orphan B does NOT leak into batch-2's reconstruction.
      final batch1 = [
        TimelineEvent.parse(
            {'name': 'BUILD', 'ph': 'B', 'ts': 1000, 'tid': 1, 'pid': 1})!,
      ];
      TimelineParser.parse(batch1);
      final batch2 = [
        TimelineEvent.parse(
            {'name': 'BUILD', 'ph': 'E', 'ts': 5000, 'tid': 1, 'pid': 1})!,
      ];
      final data2 = TimelineParser.parse(batch2);
      expect(data2.buildScopeDurations, isEmpty,
          reason: 'No shared state → orphan E from batch 2 cannot '
              'reconstruct without batch-1 B.');
    });

    test('Per-tid stack overflow drops oldest at cap=100', () {
      // Cap protects against unbounded growth from sustained orphan B
      // emission (e.g. event loss, VM service buffer overflow). After
      // 101 unmatched B events on one tid, the FIRST B is dropped.
      final pending = <int, List<Map<String, dynamic>>>{};
      // Emit 101 unmatched B events (no matching E for any).
      final manyBegins = [
        for (var i = 0; i < 101; i++)
          TimelineEvent.parse({
            'name': 'BUILD',
            'ph': 'B',
            'ts': 1000 + i,
            'tid': 1,
            'pid': 1,
          })!,
      ];
      TimelineParser.parse(manyBegins, pendingBuildBegins: pending);
      // Now match the LATEST B (ts=1100) → should reconstruct dur=10000-1100.
      final endLatest = [
        TimelineEvent.parse(
            {'name': 'BUILD', 'ph': 'E', 'ts': 10000, 'tid': 1, 'pid': 1})!,
      ];
      final data = TimelineParser.parse(endLatest, pendingBuildBegins: pending);
      // LIFO pop → matches ts=1100 (last B that was kept). dur = 8900.
      expect(data.buildScopeDurations, [10000 - 1100]);
      // Stack size should now be 99 (was 100 after cap, popped 1).
      expect(pending[1]?.length, 99);
    });
  });

  group('TimelineParser enrichment args', () {
    test('buildScope event extracts enrichment with prefixed keys', () {
      final events = [
        _makeEvent(
          name: 'BUILD',
          dur: 5000,
          ts: 1000,
          args: {
            'build scope dirty count': '3',
            'build scope dirty list': '[MyWidget, OtherWidget, ThirdWidget]',
            'lock level': '0',
            'scope context': 'MyApp(dirty)',
          },
        ),
      ];

      final data = TimelineParser.parse(events);
      final pe = data.phaseEvents.single;

      expect(pe.phase, TimelinePhase.build);
      expect(pe.dirtyCount, 3);
      expect(pe.dirtyList, ['MyWidget', 'OtherWidget', 'ThirdWidget']);
      expect(pe.scopeContext, 'MyApp(dirty)');
      expect(pe.hasEnrichment, isTrue);
    });

    test('flushLayout event extracts enrichment with short keys', () {
      final events = [
        _makeEvent(
          name: 'LAYOUT',
          dur: 2000,
          ts: 5000,
          args: {
            'dirty count': '5',
            'dirty list': '[RenderFlex#abc12, RenderParagraph#def34]',
          },
        ),
      ];

      final data = TimelineParser.parse(events);
      final pe = data.phaseEvents.single;

      expect(pe.phase, TimelinePhase.layout);
      expect(pe.dirtyCount, 5);
      expect(pe.dirtyList, ['RenderFlex#abc12', 'RenderParagraph#def34']);
      expect(pe.scopeContext, isNull);
    });

    test('flushPaint event extracts enrichment with short keys', () {
      final events = [
        _makeEvent(
          name: 'PAINT',
          dur: 1000,
          ts: 8000,
          args: {
            'dirty count': '2',
            'dirty list': '[RenderDecoratedBox#abc12]',
          },
        ),
      ];

      final data = TimelineParser.parse(events);
      final pe = data.phaseEvents.single;

      expect(pe.phase, TimelinePhase.paint);
      expect(pe.dirtyCount, 2);
      expect(pe.dirtyList, ['RenderDecoratedBox#abc12']);
    });

    test('raster event has no enrichment', () {
      final events = [
        _makeEvent(
          name: 'GPURasterizer::Draw',
          dur: 5000,
          ts: 10000,
          args: {'some_key': 'some_value'},
        ),
      ];

      final data = TimelineParser.parse(events);
      final pe = data.phaseEvents.single;

      expect(pe.phase, TimelinePhase.raster);
      expect(pe.dirtyCount, isNull);
      expect(pe.dirtyList, isNull);
      expect(pe.hasEnrichment, isFalse);
    });

    test('event without args has null enrichment', () {
      final events = [
        _makeEvent(name: 'BUILD', dur: 3000, ts: 1000),
      ];

      final data = TimelineParser.parse(events);
      final pe = data.phaseEvents.single;

      expect(pe.dirtyCount, isNull);
      expect(pe.dirtyList, isNull);
      expect(pe.scopeContext, isNull);
      expect(pe.hasEnrichment, isFalse);
    });

    test('dirty list with empty brackets returns null', () {
      final events = [
        _makeEvent(
          name: 'PAINT',
          dur: 1000,
          ts: 1000,
          args: {'dirty count': '0', 'dirty list': '[]'},
        ),
      ];

      final data = TimelineParser.parse(events);
      final pe = data.phaseEvents.single;

      expect(pe.dirtyCount, 0);
      expect(pe.dirtyList, isNull);
    });

    test('dirty count as int is handled defensively', () {
      final events = [
        _makeEvent(
          name: 'LAYOUT',
          dur: 1000,
          ts: 1000,
          args: {'dirty count': 7}, // int instead of String
        ),
      ];

      final data = TimelineParser.parse(events);
      expect(data.phaseEvents.single.dirtyCount, 7);
    });

    test('dirty list without brackets still splits correctly', () {
      final events = [
        _makeEvent(
          name: 'BUILD',
          dur: 5000,
          ts: 1000,
          args: {
            'build scope dirty list': 'Alpha, Beta',
          },
        ),
      ];

      final data = TimelineParser.parse(events);
      expect(data.phaseEvents.single.dirtyList, ['Alpha', 'Beta']);
    });

    test('single widget in dirty list', () {
      final events = [
        _makeEvent(
          name: 'BUILD',
          dur: 5000,
          ts: 1000,
          args: {
            'build scope dirty list': '[OnlyOne]',
          },
        ),
      ];

      final data = TimelineParser.parse(events);
      expect(data.phaseEvents.single.dirtyList, ['OnlyOne']);
    });
  });

  group('TimelineParser (root) suffix handling', () {
    test('LAYOUT (root) classified as layout', () {
      final events = [
        _makeEvent(name: 'LAYOUT (root)', dur: 2000, ts: 1000),
      ];
      final data = TimelineParser.parse(events);
      expect(data.flushLayoutDurations, [2000]);
      expect(data.phaseEvents.length, 1);
      expect(data.phaseEvents[0].phase, TimelinePhase.layout);
    });

    test('PAINT (root) classified as paint', () {
      final events = [
        _makeEvent(name: 'PAINT (root)', dur: 1000, ts: 1000),
      ];
      final data = TimelineParser.parse(events);
      expect(data.flushPaintDurations, [1000]);
      expect(data.phaseEvents.length, 1);
      expect(data.phaseEvents[0].phase, TimelinePhase.paint);
    });

    test('mixed root and child PipelineOwner events both captured', () {
      final events = [
        _makeEvent(name: 'LAYOUT (root)', dur: 3000, ts: 1000),
        _makeEvent(name: 'LAYOUT', dur: 500, ts: 5000),
        _makeEvent(name: 'PAINT (root)', dur: 2000, ts: 6000),
        _makeEvent(name: 'PAINT', dur: 300, ts: 9000),
      ];
      final data = TimelineParser.parse(events);
      expect(data.flushLayoutDurations, [3000, 500]);
      expect(data.flushPaintDurations, [2000, 300]);
    });

    test('LAYOUT (root) extracts enrichment args', () {
      final events = [
        _makeEvent(
          name: 'LAYOUT (root)',
          dur: 2000,
          ts: 5000,
          args: {
            'dirty count': '5',
            'dirty list': '[RenderFlex#abc12]',
          },
        ),
      ];
      final data = TimelineParser.parse(events);
      final pe = data.phaseEvents.single;
      expect(pe.dirtyCount, 5);
      expect(pe.dirtyList, ['RenderFlex#abc12']);
    });
  });

  group('TimelineParser phantom name rejection', () {
    test('old method-style names no longer match', () {
      final events = [
        _makeEvent(name: 'buildScope', dur: 3000, ts: 1000),
        _makeEvent(name: 'flushLayout', dur: 2000, ts: 5000),
        _makeEvent(name: 'flushPaint', dur: 1000, ts: 8000),
      ];
      final data = TimelineParser.parse(events);
      expect(data.buildScopeDurations, isEmpty);
      expect(data.flushLayoutDurations, isEmpty);
      expect(data.flushPaintDurations, isEmpty);
      expect(data.phaseEvents, isEmpty);
    });
  });

  group('TimelineParser platform channel classification (v8.4)', () {
    test('real format: debugProfilePlatformChannels prefix is classified', () {
      final events = [
        _makeEvent(
          name: 'Platform Channel send music#getTrack',
          dur: 500,
          ts: 1000,
        ),
      ];

      final data = TimelineParser.parse(events);
      expect(data.platformChannelEvents, hasLength(1));
    });

    test('legacy exact name: methodchannel is classified', () {
      final events = [
        _makeEvent(name: 'methodchannel', dur: 200, ts: 1000),
      ];

      final data = TimelineParser.parse(events);
      expect(data.platformChannelEvents, hasLength(1));
    });

    test('legacy exact name: platformchannel is classified', () {
      final events = [
        _makeEvent(name: 'PlatformChannel', dur: 200, ts: 1000),
      ];

      final data = TimelineParser.parse(events);
      expect(data.platformChannelEvents, hasLength(1));
    });

    test('case insensitivity: mixed case prefix is classified', () {
      final events = [
        _makeEvent(
          name: 'Platform Channel Send Music#IsLicensed',
          dur: 300,
          ts: 1000,
        ),
      ];

      final data = TimelineParser.parse(events);
      expect(data.platformChannelEvents, hasLength(1));
    });

    test('embedder vsync event is NOT classified as channel', () {
      final events = [
        _makeEvent(name: 'VSYNC', dur: 100, ts: 1000, cat: 'embedder'),
      ];

      final data = TimelineParser.parse(events);
      expect(data.platformChannelEvents, isEmpty);
    });

    test('embedder compositor event is NOT classified as channel', () {
      final events = [
        _makeEvent(
          name: 'FlutterCompositorPresentLayers',
          dur: 200,
          ts: 1000,
          cat: 'embedder',
        ),
      ];

      final data = TimelineParser.parse(events);
      expect(data.platformChannelEvents, isEmpty);
    });

    test('generic embedder event is NOT classified as channel', () {
      final events = [
        _makeEvent(
          name: 'SomeEmbedderWork',
          dur: 150,
          ts: 1000,
          cat: 'embedder',
        ),
      ];

      final data = TimelineParser.parse(events);
      expect(data.platformChannelEvents, isEmpty);
    });
  });

  group('TimelineParser async platform channel events', () {
    // Flutter's debugProfilePlatformChannels wraps each send in a
    // TimelineTask, which emits async begin/end events with lowercase
    // ph='b'/'e' — NOT the sync ph='X' format used by legacy helpers.
    TimelineEvent makeAsyncEvent({
      required String name,
      required String ph,
      int? ts,
      int id = 1,
    }) =>
        TimelineEvent.parse({
          'name': name,
          'cat': '',
          'ph': ph,
          if (ts != null) 'ts': ts,
          'id': '$id',
          'pid': 1,
          'tid': 1,
        })!;

    test('async begin (ph=b) platform channel event is classified', () {
      final events = [
        makeAsyncEvent(
          name: 'Platform Channel send sleuth_demo_channel#getData',
          ph: 'b',
          ts: 1000,
        ),
      ];

      final data = TimelineParser.parse(events);
      expect(data.platformChannelEvents, hasLength(1));
    });

    test('async end (ph=e) is NOT double-counted', () {
      final events = [
        makeAsyncEvent(
          name: 'Platform Channel send sleuth_demo_channel#ping',
          ph: 'b',
          ts: 1000,
        ),
        makeAsyncEvent(
          name: 'Platform Channel send sleuth_demo_channel#ping',
          ph: 'e',
          ts: 2000,
        ),
      ];

      final data = TimelineParser.parse(events);
      expect(data.platformChannelEvents, hasLength(1));
    });

    test('50 rapid async sends are all captured', () {
      final events = [
        for (var i = 0; i < 50; i++)
          makeAsyncEvent(
            name: 'Platform Channel send sleuth_demo_channel#getData',
            ph: 'b',
            ts: 1000 + i,
            id: i,
          ),
      ];

      final data = TimelineParser.parse(events);
      expect(data.platformChannelEvents, hasLength(50));
    });

    test('non-channel async event is NOT classified', () {
      final events = [
        makeAsyncEvent(name: 'SomeAsyncWork', ph: 'b', ts: 1000),
      ];

      final data = TimelineParser.parse(events);
      expect(data.platformChannelEvents, isEmpty);
    });
  });

  group('TimelineParser.extractStartupEvents', () {
    test('extracts FlutterEngineMainEnter instant event', () {
      final events = [
        _makeEvent(
            name: 'FlutterEngineMainEnter', dur: 0, ts: 22332982085, ph: 'i'),
        _makeEvent(name: 'BUILD', dur: 3000, ts: 100000),
      ];

      final result = TimelineParser.extractStartupEvents(events);
      expect(result, isNotNull);
      expect(result!.engineEnterUs, 22332982085);
      expect(result.firstFrameRasterizedUs, isNull);
    });

    test('extracts Rasterized first useful frame instant event', () {
      final events = [
        _makeEvent(
            name: 'Rasterized first useful frame',
            dur: 0,
            ts: 22334541649,
            ph: 'i'),
      ];

      final result = TimelineParser.extractStartupEvents(events);
      expect(result, isNotNull);
      expect(result!.firstFrameRasterizedUs, 22334541649);
    });

    test('extracts Framework initialization duration event', () {
      final events = [
        _makeEvent(
            name: 'Framework initialization',
            dur: 281595,
            ts: 22333000000,
            ph: 'X'),
      ];

      final result = TimelineParser.extractStartupEvents(events);
      // Returns null because neither engineEnterUs nor firstFrameRasterizedUs present
      expect(result, isNull);
    });

    test('extracts all startup events together', () {
      final events = [
        _makeEvent(
            name: 'FlutterEngineMainEnter', dur: 0, ts: 22332982085, ph: 'i'),
        _makeEvent(
            name: 'Framework initialization',
            dur: 281595,
            ts: 22333000000,
            ph: 'X'),
        _makeEvent(name: 'BUILD', dur: 3000, ts: 22333500000),
        _makeEvent(name: 'LAYOUT', dur: 1500, ts: 22333503000),
        _makeEvent(name: 'PAINT', dur: 800, ts: 22333504500),
        _makeEvent(name: 'GPURasterizer::Draw', dur: 5000, ts: 22333505300),
        _makeEvent(
            name: 'Rasterized first useful frame',
            dur: 0,
            ts: 22334541649,
            ph: 'i'),
      ];

      final result = TimelineParser.extractStartupEvents(events);
      expect(result, isNotNull);
      expect(result!.engineEnterUs, 22332982085);
      expect(result.frameworkInitDurationUs, 281595);
      expect(result.firstFrameRasterizedUs, 22334541649);
      expect(result.firstBuildScopeDurUs, 3000);
      expect(result.firstFlushLayoutDurUs, 1500);
      expect(result.firstFlushPaintDurUs, 800);
      expect(result.firstRasterDurUs, 5000);
    });

    test('returns null when no startup-relevant events found', () {
      final events = [
        _makeEvent(name: 'SomeOtherEvent', dur: 3000, ts: 100000),
        _makeEvent(name: 'AnotherEvent', dur: 1000, ts: 200000),
      ];

      final result = TimelineParser.extractStartupEvents(events);
      expect(result, isNull);
    });

    test('extracts first-frame sub-phase durations', () {
      final events = [
        _makeEvent(name: 'BUILD', dur: 3000, ts: 100000),
        _makeEvent(name: 'LAYOUT', dur: 1500, ts: 103000),
        _makeEvent(name: 'PAINT', dur: 800, ts: 104500),
        _makeEvent(name: 'GPURasterizer::Draw', dur: 5000, ts: 105300),
        // Second BUILD should be ignored (only first captured)
        _makeEvent(name: 'BUILD', dur: 2000, ts: 200000),
      ];

      final result = TimelineParser.extractStartupEvents(events);
      expect(result, isNotNull);
      expect(result!.firstBuildScopeDurUs, 3000);
      expect(result.firstFlushLayoutDurUs, 1500);
      expect(result.firstFlushPaintDurUs, 800);
      expect(result.firstRasterDurUs, 5000);
      // Engine-level events not present
      expect(result.engineEnterUs, isNull);
      expect(result.firstFrameRasterizedUs, isNull);
    });

    test('handles uppercase I phase for instant events', () {
      final events = [
        _makeEvent(name: 'FlutterEngineMainEnter', dur: 0, ts: 12345, ph: 'I'),
      ];

      final result = TimelineParser.extractStartupEvents(events);
      expect(result, isNotNull);
      expect(result!.engineEnterUs, 12345);
    });

    test('ignores startup event names with wrong phase type', () {
      // FlutterEngineMainEnter as a duration event should be ignored
      final events = [
        _makeEvent(
            name: 'FlutterEngineMainEnter', dur: 100, ts: 12345, ph: 'X'),
      ];

      final result = TimelineParser.extractStartupEvents(events);
      expect(result, isNull);
    });
  });
}
