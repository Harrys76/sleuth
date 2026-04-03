import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:widget_watchdog/src/models/phase_event.dart';
import 'package:widget_watchdog/src/vm/timeline_parser.dart';

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
        _makeEvent(name: 'buildScope', dur: 3000, ts: 1000),
        _makeEvent(name: 'flushLayout', dur: 2000, ts: 5000),
        _makeEvent(name: 'flushPaint', dur: 1000, ts: 8000),
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
        _makeEvent(name: 'buildScope', dur: 3000, ts: 1000),
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
        _makeEvent(name: 'buildScope', dur: 3000), // no ts
        _makeEvent(name: 'flushLayout', dur: 2000, ts: 5000), // has ts
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

    test('Begin/End events do not produce PhaseEvents', () {
      final beginEvent = TimelineEvent.parse({
        'name': 'buildScope',
        'cat': '',
        'ph': 'B',
        'ts': 1000,
        'pid': 1,
        'tid': 1,
      })!;
      final endEvent = TimelineEvent.parse({
        'name': 'buildScope',
        'cat': '',
        'ph': 'E',
        'ts': 4000,
        'pid': 1,
        'tid': 1,
      })!;

      final data = TimelineParser.parse([beginEvent, endEvent]);

      // Build count incremented
      expect(data.buildEventCount, 1);
      // But no PhaseEvents (only X events produce them)
      expect(data.phaseEvents, isEmpty);
    });

    test('phaseEvents defaults to empty list', () {
      final data = ParsedTimelineData();
      expect(data.phaseEvents, isEmpty);
    });
  });

  group('TimelineParser enrichment args', () {
    test('buildScope event extracts enrichment with prefixed keys', () {
      final events = [
        _makeEvent(
          name: 'buildScope',
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
          name: 'flushLayout',
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
          name: 'flushPaint',
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
        _makeEvent(name: 'buildScope', dur: 3000, ts: 1000),
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
          name: 'flushPaint',
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
          name: 'flushLayout',
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
          name: 'buildScope',
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
          name: 'buildScope',
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
}
