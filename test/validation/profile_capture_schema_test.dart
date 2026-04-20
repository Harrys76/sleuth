// Unit + dormant-gate tests for `ProfileCaptureSchema`.
//
// The schema is consumed by `detector_metadata_audit_test.dart` when a
// detector ships at `runtimeVerified` or stronger with a non-empty
// `profileCapturePaths`. v0.16.2 lands the schema and its enforcement
// hook ahead of the first real tier raise (v0.16.4); without a dormant-
// gate test the malformed/bracket-violation code paths would sit dark
// until then.
//
// This file exercises:
//
//   - `parse` happy path (via the anchor-like fixtures).
//   - `parse` negatives against synthetic bad fixtures (missing device,
//     bad ISO date, min > observed) AND programmatic invariants (missing
//     top-level keys, wrong Flutter version, non-approved device).
//   - Encoding hardening: UTF-8 BOM stripping, CRLF normalisation.
//   - `validateBracket` happy path: three dormant-bracket fixtures around
//     a synthetic 1000 ms threshold satisfy below / at / above.
//   - `validateBracket` negatives: swapped fixtures produce precise
//     failure messages that identify the offending file.
//   - Dormant-gate DetectorMetadataProvider: a fake provider exposes the
//     three bracket fixtures as `profileCapturePaths` and walks the same
//     per-capture `parseFile` check the audit gate performs, proving
//     the list-path code is live today.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

const _fixtureDir = 'test/validation/captures/_fixtures';

File _fx(String name) => File('$_fixtureDir/$name');

void main() {
  group('ProfileCaptureSchema.parse — happy path', () {
    test('anchor DevTools export parses', () {
      final metadata =
          ProfileCaptureSchema.parseFile(_fx('anchor_devtools_export.json'));
      expect(metadata['device'], 'iPhone 13 mini');
      expect(metadata['deviceOsVersion'], 'iOS 17.6.1');
      expect(metadata['flutterVersion'], '3.32.5');
      expect(metadata['scenario'], isA<String>());
      final magnitude = metadata['expectedMagnitude'] as Map<String, Object?>;
      expect(magnitude['observed'], isA<num>());
    });

    test('bracket fixtures all parse cleanly', () {
      for (final name in const [
        'dormant_bracket_below.json',
        'dormant_bracket_at.json',
        'dormant_bracket_above.json',
      ]) {
        expect(() => ProfileCaptureSchema.parseFile(_fx(name)), returnsNormally,
            reason: '$name should satisfy the schema');
      }
    });
  });

  group('ProfileCaptureSchema.parse — negative fixtures', () {
    test('missing device is rejected with a precise message', () {
      expect(
          () => ProfileCaptureSchema.parseFile(_fx('missing_device.json')),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('device'))));
    });

    test('non-ISO captureDate is rejected', () {
      expect(
          () => ProfileCaptureSchema.parseFile(_fx('bad_iso_date.json')),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('ISO-8601'))));
    });

    test('min > observed invariant violation is rejected', () {
      expect(
          () => ProfileCaptureSchema.parseFile(_fx('min_gt_observed.json')),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('invariant violated'))));
    });
  });

  group('ProfileCaptureSchema.parse — programmatic negatives', () {
    test('missing traceEvents is rejected', () {
      final bytes = utf8.encode(jsonEncode({
        'sleuthMetadata': _validMetadata(),
      }));
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('traceEvents'))));
    });

    test('non-approved device is rejected with an actionable message', () {
      final meta = _validMetadata()..['device'] = 'Some Random Phone';
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('approved reference device'),
                  contains('iPhone 13 mini'), contains('Pixel 7')))));
    });

    test('approved device with non-approved OS is rejected (pair policy)', () {
      final meta = _validMetadata()..['deviceOsVersion'] = 'iOS 18.0';
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('not approved for device'))));
    });

    test('non-pinned Flutter major.minor is rejected', () {
      final meta = _validMetadata()..['flutterVersion'] = '3.31.0';
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('pinned Flutter'))));
    });

    // v0.16.2 post-review F1: the regex used to reject any suffix, including
    // Flutter stable's own pre-release tags (`3.32.0-1.0.pre`) and build
    // metadata (`3.32.0+channel-stable`) that commonly appear in
    // `flutter --version` output. Captures authored from copy-pasted version
    // strings would fail audit. The regex now accepts suffixes; major.minor
    // stays strictly pinned.
    test('pre-release suffix on pinned major.minor is accepted', () {
      final meta = _validMetadata()..['flutterVersion'] = '3.32.0-1.0.pre';
      final bytes = _wrap(meta);
      expect(() => ProfileCaptureSchema.parse(bytes), returnsNormally);
    });

    test('build-metadata suffix on pinned major.minor is accepted', () {
      final meta = _validMetadata()
        ..['flutterVersion'] = '3.32.0+channel-stable';
      final bytes = _wrap(meta);
      expect(() => ProfileCaptureSchema.parse(bytes), returnsNormally);
    });

    test('suffix on non-pinned major.minor is still rejected', () {
      final meta = _validMetadata()..['flutterVersion'] = '3.33.0-1.0.pre';
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('pinned Flutter'))));
    });

    // CODEX-R1-3: magnitude must be strictly positive.
    test('zero observed is rejected', () {
      final meta = _validMetadata()
        ..['expectedMagnitude'] = {
          'min': 0,
          'observed': 0,
          'max': 10,
          'unit': 'ms',
        };
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('strictly positive'))));
    });

    test('negative min is rejected', () {
      final meta = _validMetadata()
        ..['expectedMagnitude'] = {
          'min': -10,
          'observed': 100,
          'max': 200,
          'unit': 'ms',
        };
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('strictly positive'))));
    });

    // CODEX-R1-4: out-of-range date/time components are rejected.
    test('month rollover (month 13) is rejected', () {
      final meta = _validMetadata()..['captureDate'] = '2026-13-01T12:00:00Z';
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('round-trips'))));
    });

    test('day rollover (day 45) is rejected', () {
      final meta = _validMetadata()..['captureDate'] = '2026-04-45T12:00:00Z';
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('round-trips'))));
    });

    test('hour rollover (hour 25) is rejected', () {
      final meta = _validMetadata()..['captureDate'] = '2026-04-18T25:00:00Z';
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('round-trips'))));
    });

    test('minute rollover (minute 60) is rejected', () {
      final meta = _validMetadata()..['captureDate'] = '2026-04-18T12:60:00Z';
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('round-trips'))));
    });

    test('in-range date with millisecond fraction passes round-trip', () {
      final meta = _validMetadata()
        ..['captureDate'] = '2026-04-18T14:32:00.123Z';
      final bytes = _wrap(meta);
      expect(() => ProfileCaptureSchema.parse(bytes), returnsNormally);
    });

    // AB-3: the prior implementation compared `toUtc().toIso8601String()`
    // against a string-normalised raw. That only bridged `+00:00` ↔ `Z`,
    // so any valid capture carrying a real non-zero UTC offset round-tripped
    // to a different moment's UTC form and was incorrectly rejected.
    test('non-zero positive UTC offset (+05:30) is accepted', () {
      final meta = _validMetadata()
        ..['captureDate'] = '2026-04-18T14:32:00+05:30';
      final bytes = _wrap(meta);
      expect(() => ProfileCaptureSchema.parse(bytes), returnsNormally);
    });

    test('non-zero negative UTC offset (-08:00) is accepted', () {
      final meta = _validMetadata()
        ..['captureDate'] = '2026-04-18T14:32:00-08:00';
      final bytes = _wrap(meta);
      expect(() => ProfileCaptureSchema.parse(bytes), returnsNormally);
    });

    test('Feb 30 is still rejected even under a non-zero offset', () {
      final meta = _validMetadata()
        ..['captureDate'] = '2026-02-30T14:32:00+05:30';
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('out-of-range day'))));
    });

    // Bundle E (AGR-1): expectedMagnitude.unit is mandatory. Before
    // Bundle E, missing/non-String unit was silently accepted AND
    // silently disabled the AB-1 trace/observed cross-check.
    test('missing expectedMagnitude.unit is rejected', () {
      final meta = _validMetadata()
        ..['expectedMagnitude'] = <String, Object?>{
          'min': 900,
          'observed': 1000,
          'max': 1100,
        };
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('unit'))));
    });

    test('non-String expectedMagnitude.unit is rejected', () {
      final meta = _validMetadata()
        ..['expectedMagnitude'] = <String, Object?>{
          'min': 900,
          'observed': 1000,
          'max': 1100,
          'unit': 42,
        };
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('non-empty string'))));
    });

    test('empty expectedMagnitude.unit is rejected', () {
      final meta = _validMetadata()
        ..['expectedMagnitude'] = <String, Object?>{
          'min': 900,
          'observed': 1000,
          'max': 1100,
          'unit': '   ',
        };
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('non-empty string'))));
    });

    test('novel unit spelling (millis) is rejected — approved-set gate', () {
      final meta = _validMetadata()
        ..['expectedMagnitude'] = <String, Object?>{
          'min': 900,
          'observed': 1000,
          'max': 1100,
          'unit': 'millis',
        };
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('approved unit set'))));
    });
  });

  group('ProfileCaptureSchema.parse — encoding hardening', () {
    test('UTF-8 BOM at the front is stripped before JSON decode', () {
      final body = jsonEncode({
        'traceEvents': _validTraceEvents(),
        'sleuthMetadata': _validMetadata(),
      });
      final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(body)];
      expect(() => ProfileCaptureSchema.parse(bytes), returnsNormally);
    });

    test('CRLF line endings are normalised', () {
      final body = '{\r\n  "traceEvents": ${jsonEncode(_validTraceEvents())},'
          '\r\n  "sleuthMetadata": ${jsonEncode(_validMetadata())}\r\n}';
      final bytes = utf8.encode(body);
      expect(() => ProfileCaptureSchema.parse(bytes), returnsNormally);
    });

    // AB-2: duplicate-key scanner must decode `\uXXXX` escapes the same
    // way `jsonDecode` does. Previously the scanner preserved `\u` runs
    // verbatim, so two structurally identical keys encoded differently
    // (`"captureDate"` and `"\u0063aptureDate"`) were treated as distinct
    // by the scanner but collapsed by `jsonDecode` into last-write-wins —
    // exactly the review-bypass surface the scanner exists to close.
    // AB-1 phase-set assertion: a capture composed entirely of metadata
    // (`M`) or instant (`i`) events passes the length + allowed-phase
    // checks but carries no runtime evidence. The phase-set assertion
    // requires at least 3 work-phase events (B/E/X/b/e) per capture.
    test('11 M-phase-only events are rejected (no work evidence)', () {
      final metadataOnly = List<Map<String, Object?>>.generate(
          11,
          (i) => {
                'ph': 'M',
                'name': 'thread_name',
                'pid': 1,
                'tid': i,
                'args': {'name': 'meta_$i'},
              });
      final body = jsonEncode({
        'traceEvents': metadataOnly,
        'sleuthMetadata': _validMetadata(),
      });
      expect(
          () => ProfileCaptureSchema.parse(utf8.encode(body)),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('work-phase entries'))));
    });

    // AB-1 cross-check: when the scenario-marker span is orders of
    // magnitude smaller than expectedMagnitude.observed, the capture
    // cannot have produced that magnitude in profile mode.
    test('observed of 1000 ms with 1 µs scenario span is rejected', () {
      final suspiciousEvents = [
        for (var i = 0; i < 6; i++)
          {
            'ph': 'M',
            'name': 'meta_$i',
            'pid': 1,
            'tid': 0,
            'args': {'name': 'meta_$i'},
          },
        // Markers 1 µs apart; observed = 1000 ms → ratio = 1_000_000×.
        {
          'ph': 'i',
          'cat': 'Sleuth',
          'name': 'sleuth.scenario.begin',
          'pid': 1,
          'tid': 39,
          'ts': 1000000,
          's': 'p'
        },
        {
          'ph': 'i',
          'cat': 'Sleuth',
          'name': 'sleuth.scenario.end',
          'pid': 1,
          'tid': 39,
          'ts': 1000001,
          's': 'p'
        },
        {
          'ph': 'X',
          'cat': 'Dart',
          'name': 'fake1',
          'pid': 1,
          'tid': 1,
          'ts': 1000000,
          'dur': 0
        },
        {
          'ph': 'B',
          'cat': 'Dart',
          'name': 'fake2',
          'pid': 1,
          'tid': 1,
          'ts': 1000000
        },
        {
          'ph': 'E',
          'cat': 'Dart',
          'name': 'fake2',
          'pid': 1,
          'tid': 1,
          'ts': 1000001
        },
      ];
      final body = jsonEncode({
        'traceEvents': suspiciousEvents,
        'sleuthMetadata': _validMetadata(), // observed: 1000 ms
      });
      expect(
          () => ProfileCaptureSchema.parse(utf8.encode(body)),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('cross-check failed'))));
    });

    // R3-NEW-1 (Bundle F): prior impl computed span from the global
    // work-phase min/max; an attacker could pad an unrelated event far
    // from the scenario to inflate the denominator and slide an
    // otherwise-fabricated claim through. With scenario-marker binding,
    // the padded event is irrelevant — span comes from markers only.
    test('global-window padding does not rescue a 1 µs scenario span', () {
      final paddedEvents = [
        for (var i = 0; i < 5; i++)
          {
            'ph': 'M',
            'name': 'meta_$i',
            'pid': 1,
            'tid': 0,
            'args': {'name': 'meta_$i'},
          },
        // Scenario markers 1 µs apart — the actual scoped window.
        {
          'ph': 'i',
          'cat': 'Sleuth',
          'name': 'sleuth.scenario.begin',
          'pid': 1,
          'tid': 39,
          'ts': 100,
          's': 'p'
        },
        {
          'ph': 'i',
          'cat': 'Sleuth',
          'name': 'sleuth.scenario.end',
          'pid': 1,
          'tid': 39,
          'ts': 101,
          's': 'p'
        },
        // Padding event far away — would have inflated the old global
        // span to 1 000 000 µs and rescued the fabrication.
        {
          'ph': 'X',
          'cat': 'Dart',
          'name': 'padding',
          'pid': 1,
          'tid': 1,
          'ts': 1000000,
          'dur': 0
        },
        {
          'ph': 'B',
          'cat': 'Dart',
          'name': 'real_work',
          'pid': 1,
          'tid': 1,
          'ts': 100
        },
        {
          'ph': 'E',
          'cat': 'Dart',
          'name': 'real_work',
          'pid': 1,
          'tid': 1,
          'ts': 101
        },
      ];
      final body = jsonEncode({
        'traceEvents': paddedEvents,
        'sleuthMetadata': _validMetadata(), // observed: 1000 ms
      });
      expect(
          () => ProfileCaptureSchema.parse(utf8.encode(body)),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('cross-check failed'))));
    });

    // AGR-2 (Bundle F): regression series. Previously 100_000×; now 100×.
    test('ratio 50× passes (within new 100× ceiling)', () {
      final body =
          _buildCaptureWithSpan(observedMs: 50, spanMicros: 1000); // ratio 50×
      expect(() => ProfileCaptureSchema.parse(body), returnsNormally);
    });

    test('ratio 200× is rejected', () {
      final body = _buildCaptureWithSpan(
          observedMs: 200, spanMicros: 1000); // ratio 200×
      expect(
          () => ProfileCaptureSchema.parse(body),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('cross-check failed'))));
    });

    test('ratio 1000× is rejected', () {
      final body = _buildCaptureWithSpan(
          observedMs: 1000, spanMicros: 1000); // ratio 1000×
      expect(
          () => ProfileCaptureSchema.parse(body),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('cross-check failed'))));
    });

    test('ratio 10000× is rejected', () {
      final body = _buildCaptureWithSpan(
          observedMs: 10000, spanMicros: 1000); // ratio 10_000×
      expect(
          () => ProfileCaptureSchema.parse(body),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('cross-check failed'))));
    });

    // R3-NEW-1: scenario-marker presence, uniqueness, and ordering.
    test('missing scenario markers are rejected', () {
      final events = _validTraceEvents()
          .where((e) =>
              e['name'] != 'sleuth.scenario.begin' &&
              e['name'] != 'sleuth.scenario.end')
          .toList();
      final body = jsonEncode({
        'traceEvents': events,
        'sleuthMetadata': _validMetadata(),
      });
      expect(
          () => ProfileCaptureSchema.parse(utf8.encode(body)),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('missing scenario markers'))));
    });

    test('duplicate scenario.begin markers are rejected', () {
      final events = [
        ..._validTraceEvents(),
        {
          'ph': 'i',
          'cat': 'Sleuth',
          'name': 'sleuth.scenario.begin',
          'pid': 1,
          'tid': 39,
          'ts': 200,
          's': 'p'
        },
      ];
      final body = jsonEncode({
        'traceEvents': events,
        'sleuthMetadata': _validMetadata(),
      });
      expect(
          () => ProfileCaptureSchema.parse(utf8.encode(body)),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('duplicate scenario'))));
    });

    test('inverted scenario markers (end < begin) are rejected', () {
      final events = _validTraceEvents().map((e) {
        if (e['name'] == 'sleuth.scenario.begin') {
          return {...e, 'ts': 2000000};
        }
        if (e['name'] == 'sleuth.scenario.end') {
          return {...e, 'ts': 1000};
        }
        return e;
      }).toList();
      final body = jsonEncode({
        'traceEvents': events,
        'sleuthMetadata': _validMetadata(),
      });
      expect(
          () => ProfileCaptureSchema.parse(utf8.encode(body)),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('Scenario markers inverted'))));
    });

    test('non-time unit (bytes) skips the cross-check', () {
      final meta = _validMetadata()
        ..['expectedMagnitude'] = {
          'min': 900,
          'observed': 1000,
          'max': 1100,
          'unit': 'bytes',
        };
      final bytes = _wrap(meta);
      expect(() => ProfileCaptureSchema.parse(bytes), returnsNormally);
    });

    test('duplicate key hidden behind a \\u escape is still detected', () {
      final meta = _validMetadata();
      // Build the JSON by hand so we can smuggle a second `captureDate`
      // encoded as `\u0063aptureDate` — `jsonEncode` would normalise the
      // escape away if we asked it to produce this shape from a Map.
      final metaBody = jsonEncode(meta);
      // Inject the duplicate before the FINAL `}` of the metadata object
      // so it sits at the same depth as the authentic `captureDate`
      // (which `_validMetadata()` places at the top level). Pick an
      // attacker-controlled value that differs from the authentic one so
      // last-write-wins would mask the collision if the scanner missed
      // it.
      final tampered = '${metaBody.substring(0, metaBody.length - 1)}'
          ',"\\u0063aptureDate":"2099-12-31T23:59:59Z"}';
      final body = '{"traceEvents": ${jsonEncode(_validTraceEvents())},'
          '"sleuthMetadata": $tampered}';
      expect(
          () => ProfileCaptureSchema.parse(utf8.encode(body)),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('Duplicate JSON key'))));
    });
  });

  group('ProfileCaptureSchema.validateBracket', () {
    const threshold = 1000;
    const unit = 'ms';

    final below = _fx('dormant_bracket_below.json');
    final at = _fx('dormant_bracket_at.json');
    final above = _fx('dormant_bracket_above.json');

    test('valid bracket around synthetic 1000 ms threshold succeeds', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
              ),
          returnsNormally);
    });

    test('swapping below and above produces a bracket violation', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: above,
                atFile: at,
                aboveFile: below,
                threshold: threshold,
                unit: unit,
              ),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('Bracket violation'))));
    });

    test('at fixture above +10% tolerance is rejected', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: above,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
              ),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('Bracket violation'))));
    });

    test('missing bracket file surfaces the file path in the error', () {
      final ghost = File('$_fixtureDir/definitely_does_not_exist.json');
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: ghost,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
              ),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains(ghost.path))));
    });

    // Bundle E (AGR-1): validateBracket must enforce unit equality
    // across the triad AND against the caller's bracket unit. Without
    // this a tier raise could assemble three captures in mismatched
    // scales (ms/µs/s) and the threshold comparison would be scale-
    // confused. Write a temp "at" fixture with unit swapped to µs and
    // prove the cross-check catches it.
    test('unit mismatch across triad is rejected', () async {
      final tmpDir = await Directory.systemTemp.createTemp('sleuth_bundle_e_');
      addTearDown(() => tmpDir.delete(recursive: true));
      final atBytes = at.readAsBytesSync();
      final atJson = jsonDecode(utf8.decode(atBytes)) as Map<String, Object?>;
      final atMeta = atJson['sleuthMetadata']! as Map<String, Object?>;
      final atMag = atMeta['expectedMagnitude']! as Map<String, Object?>;
      // Swap the unit to microseconds and scale observed/min/max to
      // match so the fixture still passes its own bracket invariant.
      atMag['unit'] = 'us';
      atMag['min'] = 945000;
      atMag['observed'] = 1050000;
      atMag['max'] = 1155000;
      final tamperedAt = File('${tmpDir.path}/at_unit_mismatch.json')
        ..writeAsStringSync(jsonEncode(atJson));
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: tamperedAt,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
              ),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('unit mismatch'))));
    });

    test('caller unit differs from (consistent) triad unit is rejected', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                // All three fixtures declare `ms`; pass `us` instead.
                unit: 'us',
              ),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('unit mismatch'))));
    });

    test('empty caller unit is rejected before triad walk', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: '',
              ),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('empty `unit`'))));
    });

    // NEW-CODEX-1 (Bundle G): provenance cross-check. Three captures
    // assembled from different devices / OS versions / Flutter patch
    // levels are not comparable — their observed values sit on
    // different reference axes even when the numerical bracketing
    // invariants happen to hold. validateBracket must reject any
    // triad whose `device`, `deviceOsVersion`, or `flutterVersion`
    // differ across the three captures.
    Future<File> cloneWithFieldOverride(
      File source,
      String field,
      String value,
      String tag,
    ) async {
      final tmpDir =
          await Directory.systemTemp.createTemp('sleuth_bundle_g_$tag');
      addTearDown(() => tmpDir.delete(recursive: true));
      final json = jsonDecode(utf8.decode(source.readAsBytesSync()))
          as Map<String, Object?>;
      final meta = json['sleuthMetadata']! as Map<String, Object?>;
      meta[field] = value;
      // Keep (device, OS) pair validity — if we override the device
      // alone we'd trip `_validateDevicePolicy` before reaching the
      // provenance cross-check. The Pixel 7 / Android 14 pair is
      // approved, so a clean (device, deviceOsVersion) swap passes
      // per-capture validation.
      if (field == 'device' && value == 'Pixel 7') {
        meta['deviceOsVersion'] = 'Android 14';
      }
      final out = File('${tmpDir.path}/${tag}_overridden.json')
        ..writeAsStringSync(jsonEncode(json));
      return out;
    }

    test('device mismatch across triad is rejected (provenance)', () async {
      final tamperedAt =
          await cloneWithFieldOverride(at, 'device', 'Pixel 7', 'device_at');
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: tamperedAt,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
              ),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('provenance mismatch on "device"'))));
    });

    test('OS version mismatch across triad is rejected (provenance)', () async {
      // Pin the device to the same (device, OS) pair as the triad so
      // the override survives per-capture validation: flip to a
      // different approved device entirely.
      final tamperedAbove = await cloneWithFieldOverride(
          above, 'device', 'Pixel 7', 'device_above');
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: tamperedAbove,
                threshold: threshold,
                unit: unit,
              ),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('provenance mismatch on "device"'))));
    });

    test('Flutter patch-level mismatch across triad is rejected (provenance)',
        () async {
      final tamperedBelow = await cloneWithFieldOverride(
          below, 'flutterVersion', '3.32.4', 'flutter_below');
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: tamperedBelow,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
              ),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('provenance mismatch on "flutterVersion"'))));
    });
  });

  group('Dormant-gate: fake DetectorMetadataProvider exercises list path', () {
    // Proves the v0.16.2 audit-gate code paths that will fire once the
    // first real detector ships at `runtimeVerified` (v0.16.4) are live
    // today. A fake provider stands in for a real detector and walks the
    // same per-capture `parseFile` check the audit test performs.
    test('fake runtimeVerified provider passes per-capture parse', () {
      const fake = _FakeDetectorMetadataProvider(
        capturePaths: [
          '$_fixtureDir/dormant_bracket_below.json',
          '$_fixtureDir/dormant_bracket_at.json',
          '$_fixtureDir/dormant_bracket_above.json',
        ],
      );
      final meta = fake.validationMetadata;
      expect(meta.tier, EvidenceTier.runtimeVerified);
      expect(meta.profileCapturePaths, isNotNull);
      expect(meta.profileCapturePaths, isNotEmpty);
      for (final path in meta.profileCapturePaths!) {
        final file = File(path);
        expect(file.existsSync(), isTrue,
            reason: 'Dormant-gate fixture $path must exist.');
        expect(() => ProfileCaptureSchema.parseFile(file), returnsNormally,
            reason: 'Dormant-gate fixture $path must satisfy the schema.');
      }
    });

    test('fake runtimeVerified provider passes validateBracket', () {
      const fake = _FakeDetectorMetadataProvider(
        capturePaths: [
          '$_fixtureDir/dormant_bracket_below.json',
          '$_fixtureDir/dormant_bracket_at.json',
          '$_fixtureDir/dormant_bracket_above.json',
        ],
      );
      final paths = fake.validationMetadata.profileCapturePaths!;
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: File(paths[0]),
                atFile: File(paths[1]),
                aboveFile: File(paths[2]),
                threshold: 1000,
                unit: 'ms',
              ),
          returnsNormally);
    });
  });
}

Map<String, Object?> _validMetadata() => <String, Object?>{
      'device': 'iPhone 13 mini',
      'deviceOsVersion': 'iOS 17.6.1',
      'flutterVersion': '3.32.5',
      'captureCommand': 'fvm flutter run --profile',
      'scenario': 'synthetic programmatic test body',
      'expectedMagnitude': {
        'min': 900,
        'observed': 1000,
        'max': 1100,
        'unit': 'ms',
      },
      'captureDate': '2026-04-18T16:00:00Z',
    };

List<Map<String, Object?>> _validTraceEvents() => [
      {
        'ph': 'M',
        'name': 'process_name',
        'pid': 1,
        'tid': 0,
        'args': {'name': 'test'},
      },
      {
        'ph': 'M',
        'name': 'thread_name',
        'pid': 1,
        'tid': 39,
        'args': {'name': '1.ui'},
      },
      {
        'ph': 'M',
        'name': 'thread_name',
        'pid': 1,
        'tid': 40,
        'args': {'name': '1.raster'},
      },
      // Bundle F: scenario markers bound the AB-1 cross-check span.
      // observed = 1000 ms in `_validMetadata()`; span below is
      // 1_000_000 µs so ratio = 1.0.
      {
        'ph': 'i',
        'cat': 'Sleuth',
        'name': 'sleuth.scenario.begin',
        'pid': 1,
        'tid': 39,
        'ts': 100,
        's': 'p',
      },
      {
        'ph': 'i',
        'cat': 'Sleuth',
        'name': 'sleuth.scenario.end',
        'pid': 1,
        'tid': 39,
        'ts': 1000100,
        's': 'p',
      },
      {
        'ph': 'X',
        'cat': 'Dart',
        'name': 'BUILD',
        'pid': 1,
        'tid': 39,
        'ts': 100,
        'dur': 50,
      },
      {
        'ph': 'X',
        'cat': 'Dart',
        'name': 'LAYOUT',
        'pid': 1,
        'tid': 39,
        'ts': 150,
        'dur': 30,
      },
      {
        'ph': 'X',
        'cat': 'Dart',
        'name': 'PAINT',
        'pid': 1,
        'tid': 39,
        'ts': 180,
        'dur': 20,
      },
      {
        'ph': 'B',
        'cat': 'Dart',
        'name': 'frame',
        'pid': 1,
        'tid': 39,
        'ts': 200,
      },
      {
        'ph': 'E',
        'cat': 'Dart',
        'name': 'frame',
        'pid': 1,
        'tid': 39,
        'ts': 300,
      },
      {
        'ph': 'i',
        'cat': 'Embedder',
        'name': 'ShaderCompile',
        'pid': 1,
        'tid': 40,
        'ts': 320,
        's': 't',
      },
      {
        'ph': 'b',
        'cat': 'Dart',
        'name': 'PlatformChannel',
        'pid': 1,
        'tid': 39,
        'id': '0x1',
        'ts': 330,
      },
      {
        'ph': 'e',
        'cat': 'Dart',
        'name': 'PlatformChannel',
        'pid': 1,
        'tid': 39,
        'id': '0x1',
        'ts': 340,
      },
    ];

List<int> _wrap(Map<String, Object?> metadata) => utf8.encode(jsonEncode({
      'traceEvents': _validTraceEvents(),
      'sleuthMetadata': metadata,
    }));

/// Builds a capture whose scenario markers span exactly [spanMicros] µs
/// and whose `expectedMagnitude.observed` is [observedMs] ms. Lets AB-1
/// ratio tests vary the trace-span / observed ratio deterministically.
List<int> _buildCaptureWithSpan({
  required num observedMs,
  required int spanMicros,
}) {
  const beginTs = 100;
  final endTs = beginTs + spanMicros;
  final events = <Map<String, Object?>>[
    {
      'ph': 'M',
      'name': 'process_name',
      'pid': 1,
      'tid': 0,
      'args': {'name': 'test'},
    },
    {
      'ph': 'M',
      'name': 'thread_name',
      'pid': 1,
      'tid': 39,
      'args': {'name': '1.ui'},
    },
    {
      'ph': 'M',
      'name': 'thread_name',
      'pid': 1,
      'tid': 40,
      'args': {'name': '1.raster'},
    },
    {
      'ph': 'i',
      'cat': 'Sleuth',
      'name': 'sleuth.scenario.begin',
      'pid': 1,
      'tid': 39,
      'ts': beginTs,
      's': 'p',
    },
    {
      'ph': 'i',
      'cat': 'Sleuth',
      'name': 'sleuth.scenario.end',
      'pid': 1,
      'tid': 39,
      'ts': endTs,
      's': 'p',
    },
    {
      'ph': 'X',
      'cat': 'Dart',
      'name': 'BUILD',
      'pid': 1,
      'tid': 39,
      'ts': beginTs,
      'dur': 50,
    },
    {
      'ph': 'X',
      'cat': 'Dart',
      'name': 'LAYOUT',
      'pid': 1,
      'tid': 39,
      'ts': beginTs + 50,
      'dur': 30,
    },
    {
      'ph': 'X',
      'cat': 'Dart',
      'name': 'PAINT',
      'pid': 1,
      'tid': 39,
      'ts': beginTs + 80,
      'dur': 20,
    },
    {
      'ph': 'B',
      'cat': 'Dart',
      'name': 'frame',
      'pid': 1,
      'tid': 39,
      'ts': beginTs + 100,
    },
    {
      'ph': 'E',
      'cat': 'Dart',
      'name': 'frame',
      'pid': 1,
      'tid': 39,
      'ts': beginTs + 200,
    },
    {
      'ph': 'b',
      'cat': 'Dart',
      'name': 'PlatformChannel',
      'pid': 1,
      'tid': 39,
      'id': '0x1',
      'ts': beginTs + 210,
    },
    {
      'ph': 'e',
      'cat': 'Dart',
      'name': 'PlatformChannel',
      'pid': 1,
      'tid': 39,
      'id': '0x1',
      'ts': beginTs + 220,
    },
  ];
  final meta = _validMetadata()
    ..['expectedMagnitude'] = {
      'min': observedMs * 0.9,
      'observed': observedMs,
      'max': observedMs * 1.1,
      'unit': 'ms',
    };
  return utf8.encode(jsonEncode({
    'traceEvents': events,
    'sleuthMetadata': meta,
  }));
}

/// Test-only stand-in for a future `runtimeVerified` detector. Exists so
/// the audit-gate code paths that depend on `profileCapturePaths` being
/// a non-empty list of schema-valid captures are exercised today.
class _FakeDetectorMetadataProvider with DetectorMetadataProvider {
  const _FakeDetectorMetadataProvider({required this.capturePaths});

  final List<String> capturePaths;

  @override
  DetectorMetadata get validationMetadata => DetectorMetadata(
        tier: EvidenceTier.runtimeVerified,
        rationale:
            'Dormant-gate fake: exercises the v0.16.2 profileCapturePaths '
            'list code path ahead of the first real runtimeVerified tier '
            'raise.',
        reproducerPath: 'test/validation/profile_capture_schema_test.dart',
        profileCapturePaths: capturePaths,
        coveredStableIds: const {'dormant_gate_fake'},
      );
}
