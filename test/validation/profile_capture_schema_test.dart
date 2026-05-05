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
      expect(metadata['device'], 'iPhone 12');
      expect(metadata['deviceOsVersion'], 'iOS 17.5');
      expect(metadata['flutterVersion'], '3.41.4');
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
                  contains('iPhone 12')))));
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
      final meta = _validMetadata()..['flutterVersion'] = '3.40.0';
      final bytes = _wrap(meta);
      expect(
          () => ProfileCaptureSchema.parse(bytes),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('pinned Flutter'))));
    });

    // v0.16.2 regex relaxation: previously rejected any suffix, including
    // Flutter stable's own pre-release tags (`3.41.0-1.0.pre`) and build
    // metadata (`3.41.0+channel-stable`) that commonly appear in
    // `flutter --version` output. Captures authored from copy-pasted version
    // strings would fail audit. The regex now accepts suffixes; major.minor
    // stays strictly pinned.
    test('pre-release suffix on pinned major.minor is accepted', () {
      final meta = _validMetadata()..['flutterVersion'] = '3.41.0-1.0.pre';
      final bytes = _wrap(meta);
      expect(() => ProfileCaptureSchema.parse(bytes), returnsNormally);
    });

    test('build-metadata suffix on pinned major.minor is accepted', () {
      final meta = _validMetadata()
        ..['flutterVersion'] = '3.41.0+channel-stable';
      final bytes = _wrap(meta);
      expect(() => ProfileCaptureSchema.parse(bytes), returnsNormally);
    });

    test('suffix on non-pinned major.minor is still rejected', () {
      final meta = _validMetadata()..['flutterVersion'] = '3.42.0-1.0.pre';
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

    // Exponent-overflow JSON literals decode silently to
    // `double.infinity` in Dart. Without
    // the finite-positive guard at `_validateExpectedMagnitude` this would
    // pass every magnitude invariant (`Infinity > 0` is true; `min >
    // observed` and `observed > max` both evaluate false when either side
    // is `Infinity`). Literal `NaN`/`Infinity` tokens cannot reach parse
    // via bytes (the JSON spec rejects them, and `jsonEncode` refuses to
    // emit them), so the only realistic exploit path at parse level is
    // overflow on decode. Map-input NaN/Infinity coverage lives on
    // `validateBracket` below.
    test('exponent-overflow (1e400) observed decodes to Infinity and rejects',
        () {
      final baseline =
          utf8.decode(_wrap(_validMetadata()), allowMalformed: false);
      // Swap the observed magnitude in-string for an exponent-overflow
      // literal. `_validMetadata()` sets observed=1000 and this file has
      // no other `"observed":1000` occurrence so the replace is precise.
      final exploit =
          baseline.replaceFirst('"observed":1000', '"observed":1e400');
      expect(
          () => ProfileCaptureSchema.parse(utf8.encode(exploit)),
          throwsA(isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains(
                  '"expectedMagnitude.observed" must be a finite number'))));
    });

    test('exponent-overflow (-1e400) min decodes to -Infinity and rejects', () {
      final baseline =
          utf8.decode(_wrap(_validMetadata()), allowMalformed: false);
      final exploit = baseline.replaceFirst('"min":900', '"min":-1e400');
      expect(
          () => ProfileCaptureSchema.parse(utf8.encode(exploit)),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('"expectedMagnitude.min" must be a finite number'))));
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

    // v0.16.4 post-review LOW-2: symmetric guard — span wildly larger
    // than observed magnitude means markers bracket unrelated work.
    test('inverse ratio 200× (span >> observed) is rejected', () {
      // observedMs=1 → observedMicros=1000; spanMicros=200000 →
      // inverseRatio = 200×.
      final body = _buildCaptureWithSpan(observedMs: 1, spanMicros: 200000);
      expect(
          () => ProfileCaptureSchema.parse(body),
          throwsA(isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(contains('cross-check failed'),
                  contains('larger than expectedMagnitude.observed')))));
    });

    test('inverse ratio 50× (span > observed within ceiling) passes', () {
      // observedMs=1 → observedMicros=1000; spanMicros=50000 →
      // inverseRatio = 50×, within 100× ceiling.
      final body = _buildCaptureWithSpan(observedMs: 1, spanMicros: 50000);
      expect(() => ProfileCaptureSchema.parse(body), returnsNormally);
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

    // v0.16.4 post-review MED-2: pin `ph: 'n'` (async nestable instant)
    // acceptance. Perfetto `traceconv` converts Dart `Timeline.instantSync`
    // events to `ph: 'n'` when exporting `.pftrace` → Chrome Trace JSON;
    // the DevTools-native export path emits `'i'`/`'I'`. v0.16.4 captures
    // travelled the Perfetto path, so the schema must accept `'n'` for
    // scenario markers AND as a general allowed phase.
    test('ph "n" scenario markers are accepted (Perfetto traceconv path)', () {
      final events = _validTraceEvents().map((e) {
        if (e['name'] == 'sleuth.scenario.begin' ||
            e['name'] == 'sleuth.scenario.end') {
          return {...e, 'ph': 'n'}..remove('s');
        }
        return e;
      }).toList();
      final body = jsonEncode({
        'traceEvents': events,
        'sleuthMetadata': _validMetadata(),
      });
      expect(
          () => ProfileCaptureSchema.parse(utf8.encode(body)), returnsNormally);
    });

    test('ph "n" is allowed in allowedTracePhases', () {
      final events = [
        ..._validTraceEvents(),
        {
          'ph': 'n',
          'cat': 'Dart',
          'name': 'nestable_instant_event',
          'pid': 1,
          'tid': 39,
          'ts': 500,
          'id': '0x42',
        },
      ];
      final body = jsonEncode({
        'traceEvents': events,
        'sleuthMetadata': _validMetadata(),
      });
      expect(
          () => ProfileCaptureSchema.parse(utf8.encode(body)), returnsNormally);
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

    test(
        'swapping below and above slots fails the role-vs-label check '
        '(authoritative role enforcement)', () {
      // The role-vs-label assertion in `_parseOrThrowWithLabel` fires
      // before the bracket-ordering check. A capture with role='above'
      // placed in the below-slot is rejected immediately so a
      // mis-rolled triad cannot suppress the AB-1 inverse-ratio bypass
      // by occupying the wrong slot.
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: above,
                atFile: at,
                aboveFile: below,
                threshold: threshold,
                unit: unit,
              ),
          throwsA(isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('Bracket "below" slot'),
                contains('"above"'),
                contains('positional bracket label and the stored role '
                    'must match'),
              ))));
    });

    test('at fixture above +10% tolerance is rejected', () async {
      // Build a programmatic triad whose roles match their slots but
      // whose at-leg observed exceeds the +10% tolerance, isolating the
      // tolerance check from the role-vs-label assertion.
      final tmp = await Directory.systemTemp.createTemp('sleuth_at_tolerance_');
      addTearDown(() => tmp.delete(recursive: true));
      final belowF =
          _writeRoleCapture(tmp, 'below.json', role: 'below', observed: 800);
      final atF = _writeRoleCapture(tmp, 'at.json',
          role: 'at', observed: 1200); // > 1000 * 1.10 = 1100 ceiling
      final aboveF =
          _writeRoleCapture(tmp, 'above.json', role: 'above', observed: 1500);
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: belowF,
                atFile: atF,
                aboveFile: aboveF,
                threshold: threshold,
                unit: unit,
              ),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('Bracket violation'))));
    });

    // Monotonic-ordering invariant: an "at" capture numerically larger
    // than the "above" capture is rejected even when both legs
    // individually satisfy their per-leg bracket constraints. Use a
    // wider atTolerance (0.30 → at-band [1000, 1300]) so the at-leg's
    // observed=1200 fits the at-band AND the above-leg's observed=1050
    // fits the above-band — without the wider tolerance, the
    // out-of-order values would already trip per-leg checks and we
    // couldn't isolate the ordering violation. Build programmatic
    // triads whose roles match their slots so the role-vs-label
    // assertion doesn't fire first.
    test('inverted triad (at > above) is rejected by ordering invariant',
        () async {
      final tmp =
          await Directory.systemTemp.createTemp('sleuth_inverted_triad_');
      addTearDown(() => tmp.delete(recursive: true));
      final belowF =
          _writeRoleCapture(tmp, 'below.json', role: 'below', observed: 800);
      final atF = _writeRoleCapture(tmp, 'at.json', role: 'at', observed: 1200);
      final aboveF =
          _writeRoleCapture(tmp, 'above.json', role: 'above', observed: 1050);
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: belowF,
          atFile: atF,
          aboveFile: aboveF,
          threshold: threshold,
          unit: unit,
          atTolerance: 0.30,
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Bracket violation'),
            contains('"above" observed'),
            contains('strictly greater than "at" observed'),
            contains('1050'),
            contains('1200'),
          ),
        )),
      );
    });

    test(
        'mis-rolled at-leg (role="below" in at-slot) fails the '
        'role-vs-label check before any bracket math', () async {
      // Direct regression for the v0.19.0 audit-bypass: a real at-leg
      // capture whose `metadata.role` was hand-edited to `'below'`
      // would otherwise silently disable the AB-1 inverse-ratio bypass
      // (parse() reads role and skips the inverse-ratio half) while
      // being audited in the at-slot. The role-vs-label assertion in
      // `_parseOrThrowWithLabel` rejects this triad with a clear error
      // naming the discrepancy.
      final tmp = await Directory.systemTemp.createTemp('sleuth_misrole_');
      addTearDown(() => tmp.delete(recursive: true));
      final belowF =
          _writeRoleCapture(tmp, 'below.json', role: 'below', observed: 800);
      final atF = _writeRoleCapture(tmp, 'at.json',
          role: 'below', observed: 1050); // mis-rolled
      final aboveF =
          _writeRoleCapture(tmp, 'above.json', role: 'above', observed: 1500);
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: belowF,
          atFile: atF,
          aboveFile: aboveF,
          threshold: threshold,
          unit: unit,
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Bracket "at" slot'),
            contains('"below"'),
            contains('positional bracket label and the stored role '
                'must match'),
          ),
        )),
      );
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
      // Rewrite scenario to satisfy basename-suffix shape — the dormant
      // bracket fixture's prose scenario is fixture-allowlisted, but
      // this copy lands in a tempdir outside `_fixtures/` and must
      // satisfy the cross-check.
      atMeta['scenario'] = 'synthetic_at_unit_mismatch';
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
      meta['scenario'] = 'synthetic_${tag}_overridden';
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
    },
        skip:
            'Requires a second approved device pair; matrix is iPhone-12-only '
            'as of v0.23.0. Re-enable when Android reference device lands. '
            'Per-file device-policy invariant catches unapproved devices first.');

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
    },
        skip:
            'Requires a second approved device pair; matrix is iPhone-12-only '
            'as of v0.23.0. Re-enable when Android reference device lands.');

    test('Flutter patch-level mismatch across triad is rejected (provenance)',
        () async {
      final tamperedBelow = await cloneWithFieldOverride(
          below, 'flutterVersion', '3.41.3', 'flutter_below');
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

    // Bounded `above`. The schema default ceiling is 2.0 × threshold;
    // fixtures at `observed = 1200 ms` pass under threshold = 1000 ms.
    // Tightening the multiplier below the fixture's observed value
    // must surface a bracket violation so a detector whose `above`
    // capture drifts into an adjacent tier (e.g. 1000 ms warning vs
    // 3000 ms critical — the dual-use pattern v0.16.4 reverted) fails
    // loudly instead of silently over-claiming evidence.
    test('above above ceiling is rejected (aboveCeilingMultiplier)', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
                // observed = 1200, ceiling = 1000 * 1.15 = 1150 < 1200.
                // Multiplier 1.15 exceeds default `1 + atTolerance = 1.10`
                // so the at-band collision guard does not fire; the
                // ceiling guard does.
                aboveCeilingMultiplier: 1.15,
              ),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('exceeds ceiling'))));
    });

    test('aboveCeilingMultiplier <= 1.0 is rejected', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
                aboveCeilingMultiplier: 1.0,
              ),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('aboveCeilingMultiplier'))));
    });

    test('aboveCeilingMultiplier <= 1 + atTolerance collapses band', () {
      // Ceiling multiplier equal to `1 + atTolerance` (default 1.10)
      // makes the above-band collapse into the at-band. Guard must
      // reject before the ceiling comparison so the failure message
      // names the real cause.
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
                aboveCeilingMultiplier: 1.10,
              ),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('non-empty "above" band'))));
    });

    test(
        'atTolerance=0.60 seam: 25.6 ms accepts, 25.601 ms rejects '
        '(threshold=16, the HeavyCompute critical bracket boundary)', () async {
      // Pins the schema-side at-band upper edge for the
      // HeavyComputeDetector critical bracket. Detector metadata declares
      // atTolerance=0.60 against threshold=16, so the audit gate accepts
      // observed up to 16 × 1.6 = 25.6 ms and rejects the next tick.
      // Without this test the seam value is just a number in BracketSpec —
      // a future drift around the boundary could ship green.
      final tmp = await Directory.systemTemp.createTemp('sleuth_060_seam_');
      addTearDown(() => tmp.delete(recursive: true));
      final belowF =
          _writeRoleCapture(tmp, 'below.json', role: 'below', observed: 12);
      final aboveF =
          _writeRoleCapture(tmp, 'above.json', role: 'above', observed: 27);
      final atAcceptF =
          _writeRoleCapture(tmp, 'at_accept.json', role: 'at', observed: 25.6);
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: belowF,
          atFile: atAcceptF,
          aboveFile: aboveF,
          threshold: 16,
          unit: 'ms',
          atTolerance: 0.60,
          aboveCeilingMultiplier: 1.875,
        ),
        returnsNormally,
      );
      final atRejectF = _writeRoleCapture(tmp, 'at_reject.json',
          role: 'at', observed: 25.601);
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: belowF,
          atFile: atRejectF,
          aboveFile: aboveF,
          threshold: 16,
          unit: 'ms',
          atTolerance: 0.60,
          aboveCeilingMultiplier: 1.875,
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains('Bracket violation'), contains('"at" observed')),
        )),
      );
    });

    test(
        'atTolerance=0.40 seam: 4200 ms accepts, 4200.001 ms rejects '
        '(threshold=3000, the slow_request critical bracket boundary)',
        () async {
      // Pins the schema-side at-band upper edge for the
      // NetworkMonitorDetector slow_request critical bracket. Detector
      // metadata declares atTolerance=0.40 against threshold=3000, so the
      // audit gate accepts observed up to 3000 × 1.4 = 4200 ms and
      // rejects the next tick.
      final tmp = await Directory.systemTemp.createTemp('sleuth_040_seam_');
      addTearDown(() => tmp.delete(recursive: true));
      final belowF =
          _writeRoleCapture(tmp, 'below.json', role: 'below', observed: 2700);
      final aboveF =
          _writeRoleCapture(tmp, 'above.json', role: 'above', observed: 5000);
      final atAcceptF =
          _writeRoleCapture(tmp, 'at_accept.json', role: 'at', observed: 4200);
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: belowF,
          atFile: atAcceptF,
          aboveFile: aboveF,
          threshold: 3000,
          unit: 'ms',
          atTolerance: 0.40,
          aboveCeilingMultiplier: 2.0,
        ),
        returnsNormally,
      );
      final atRejectF = _writeRoleCapture(tmp, 'at_reject.json',
          role: 'at', observed: 4200.001);
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: belowF,
          atFile: atRejectF,
          aboveFile: aboveF,
          threshold: 3000,
          unit: 'ms',
          atTolerance: 0.40,
          aboveCeilingMultiplier: 2.0,
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(contains('Bracket violation'), contains('"at" observed')),
        )),
      );
    });

    test('aboveCeilingMultiplier below 1 + atTolerance also rejected', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
                aboveCeilingMultiplier: 1.05,
              ),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('1 + atTolerance'))));
    });

    test('tighter atTolerance makes narrower multiplier valid again', () {
      // Contract sanity: `atTolerance: 0.05` puts at-band ceiling at 1.05;
      // the at-fixture's observed = 1050 still lands inside the band
      // (upper bound is inclusive). Multiplier 1.10 now leaves a valid
      // (1.05, 1.10] above strip and the collision guard (1.10 >
      // 1+0.05 = 1.05) passes. above observed 1200 still exceeds ceiling
      // 1100 so the ceiling guard fires — proves the collision guard
      // is a _precondition_ for the ceiling check, not a replacement.
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
                atTolerance: 0.05,
                aboveCeilingMultiplier: 1.10,
              ),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('exceeds ceiling'))));
    });

    test('default aboveCeilingMultiplier accepts fixture observed = 1200', () {
      // Sanity: no explicit multiplier uses `defaultAboveCeilingMultiplier`
      // (2.0). 1200 < 2000, so the default bracket still succeeds.
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

    // Non-finite-input regression tests. Dart's NaN-comparison
    // semantics (every `<`, `>`, `<=`,
    // `>=`, `==` against NaN returns `false`) silently bypass every
    // bracket and magnitude guard. Infinity disables the ceiling
    // (`threshold * Infinity = Infinity`; `observed > Infinity =
    // false`). Both must be rejected at `validateBracket`'s numeric
    // boundary before any comparison happens.
    test('NaN bracketThreshold is rejected', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: double.nan,
                unit: unit,
              ),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('"bracketThreshold" must be a finite number'))));
    });

    test('+Infinity bracketThreshold is rejected', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: double.infinity,
                unit: unit,
              ),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('"bracketThreshold" must be a finite number'))));
    });

    test('-Infinity bracketThreshold is rejected', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: double.negativeInfinity,
                unit: unit,
              ),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('"bracketThreshold" must be a finite number'))));
    });

    test('NaN aboveCeilingMultiplier is rejected', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
                aboveCeilingMultiplier: double.nan,
              ),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('"aboveCeilingMultiplier" must be a finite number'))));
    });

    test('+Infinity aboveCeilingMultiplier is rejected', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
                aboveCeilingMultiplier: double.infinity,
              ),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('"aboveCeilingMultiplier" must be a finite number'))));
    });

    test('NaN atTolerance is rejected', () {
      expect(
          () => ProfileCaptureSchema.validateBracket(
                belowFile: below,
                atFile: at,
                aboveFile: above,
                threshold: threshold,
                unit: unit,
                atTolerance: double.nan,
              ),
          throwsA(isA<FormatException>().having((e) => e.message, 'message',
              contains('"atTolerance" must be a finite number'))));
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

  // -- NetworkMonitor runtimeVerified live captures (v0.18.0) ----------
  //
  // The three captures under `test/validation/captures/network_monitor/`
  // back `NetworkMonitorDetector.slow_request` warning-tier
  // `runtimeVerified` evidence. They were produced by the in-app
  // capture procedure (`Sleuth.markScenarioBegin/End` +
  // `Sleuth.exportCaptureJson`) on iPhone 12 / iOS 17.5 / Flutter
  // 3.41.x, with the detector emitting
  // `sleuth.issue.slow_request.warning` inside the scenario span via
  // the real `_recordIssuesForCapture` pipeline.
  group('NetworkMonitor runtimeVerified captures (v0.18.0)', () {
    File capture(String role) => File(
        'test/validation/captures/network_monitor/slow_request_$role.json');

    test('all three captures parse cleanly', () {
      for (final role in const ['below', 'at', 'above']) {
        final file = capture(role);
        expect(file.existsSync(), isTrue,
            reason: 'capture missing — expected at ${file.path}');
        expect(() => ProfileCaptureSchema.parseFile(file), returnsNormally,
            reason: '$role capture failed parseFile');
      }
    });

    test('validateBracket succeeds with trace-record gate', () {
      // The full runtimeVerified contract: schemaVersion: v1, scenario
      // markers, and a `sleuth.issue.slow_request.warning` event inside
      // the scenario span on at + above legs (below stays silent).
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: capture('below'),
          atFile: capture('at'),
          aboveFile: capture('above'),
          threshold: 1000,
          unit: 'ms',
          requireDetectorTraceRecord: true,
          stableId: 'slow_request',
          severityLabel: 'warning',
          aboveCeilingMultiplier: 2.0,
        ),
        returnsNormally,
      );
    });

    test('strong uniqueness invariant passes on v0.18.1 captures', () {
      // v0.18.1 captures were recorded under producer-side dedup, so
      // every in-span trace record carries a distinct
      // `detectedAtMicros`. The strong invariant must accept them.
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: capture('below'),
          atFile: capture('at'),
          aboveFile: capture('above'),
          threshold: 1000,
          unit: 'ms',
          requireDetectorTraceRecord: true,
          requireUniqueDetectedAtMicros: true,
          stableId: 'slow_request',
          severityLabel: 'warning',
          aboveCeilingMultiplier: 2.0,
        ),
        returnsNormally,
      );
    });

    test('strong invariant rejects replay with detectedAtMicros stripped', () {
      // Forgery defense: the strong invariant must not be bypassable by
      // replaying one record N times AND deleting the
      // `args.detectedAtMicros` field from every copy. A presence-only
      // check (uniqueDetectedAtMicros.isNotEmpty) would silently accept
      // such forgeries because the unique-set stays empty. The fix
      // requires count_unique == count_records, which fails when
      // matchCount=N but the unique-set is empty (0 != N).
      final strippedAt = File('test/validation/captures/_fixtures/'
          'slow_request_at_replayed_stripped.json');
      if (!strippedAt.existsSync()) {
        final source = json.decode(capture('at').readAsStringSync())
            as Map<String, dynamic>;
        final events = (source['traceEvents'] as List).cast<dynamic>();
        final original = events.firstWhere((e) =>
            e is Map &&
            (e['name'] as String)
                .startsWith('sleuth.issue.slow_request.warning'));
        // Strip args.detectedAtMicros from the original AND every clone.
        final stripped = Map<String, dynamic>.from(original as Map);
        if (stripped['args'] is Map) {
          stripped['args'] = Map<String, dynamic>.from(stripped['args'] as Map)
            ..remove('detectedAtMicros');
        }
        final originalIdx = events.indexOf(original);
        events[originalIdx] = stripped;
        for (var i = 0; i < 4; i++) {
          events.add(Map<String, dynamic>.from(stripped));
        }
        strippedAt.parent.createSync(recursive: true);
        strippedAt.writeAsStringSync(json.encode(source));
      }
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: capture('below'),
          atFile: strippedAt,
          aboveFile: capture('above'),
          threshold: 1000,
          unit: 'ms',
          requireDetectorTraceRecord: true,
          requireUniqueDetectedAtMicros: true,
          stableId: 'slow_request',
          severityLabel: 'warning',
          aboveCeilingMultiplier: 2.0,
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Inflated detector trace records'),
        )),
      );
    });

    test('strong uniqueness invariant rejects synthetic replay capture', () {
      // Negative test: synthesise a capture whose at.json has been
      // hand-edited to replay one slow_request.warning record N times
      // (all sharing one `detectedAtMicros`). Strong invariant must
      // reject. Uses the v0.18.1 below + above captures unchanged so
      // only the at-leg's replay defeats the invariant.
      final replayedAt = File(
          'test/validation/captures/_fixtures/slow_request_at_replayed.json');
      if (!replayedAt.existsSync()) {
        // Construct on first run from the real at-capture.
        final source = json.decode(capture('at').readAsStringSync())
            as Map<String, dynamic>;
        final events = (source['traceEvents'] as List).cast<dynamic>();
        // Find the one slow_request.warning record and clone it 4 more
        // times with the same `detectedAtMicros` — the replay shape.
        final original = events.firstWhere((e) =>
            e is Map &&
            (e['name'] as String)
                .startsWith('sleuth.issue.slow_request.warning'));
        for (var i = 0; i < 4; i++) {
          events.add(Map<String, dynamic>.from(original as Map));
        }
        replayedAt.parent.createSync(recursive: true);
        replayedAt.writeAsStringSync(json.encode(source));
      }
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: capture('below'),
          atFile: replayedAt,
          aboveFile: capture('above'),
          threshold: 1000,
          unit: 'ms',
          requireDetectorTraceRecord: true,
          requireUniqueDetectedAtMicros: true,
          stableId: 'slow_request',
          severityLabel: 'warning',
          aboveCeilingMultiplier: 2.0,
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Inflated detector trace records'),
        )),
      );
    });
  });

  group('validateBracketSpec (v0.19.8 schema extension)', () {
    const threshold = 1000;
    const unit = 'ms';
    final below = _fx('dormant_bracket_below.json');
    final at = _fx('dormant_bracket_at.json');
    final above = _fx('dormant_bracket_above.json');

    BracketSpec mkSpec() => const BracketSpec(
          stableId: 'dormant_bracket',
          severityLabel: 'warning',
          threshold: threshold,
          unit: unit,
          coveredThresholds: {'dormant_bracket.warning'},
          profileCapturePaths: <String>[],
          requireDetectorTraceRecord: false,
        );

    test('valid bracket via spec entrypoint succeeds', () {
      expect(
          () => ProfileCaptureSchema.validateBracketSpec(
                mkSpec(),
                belowFile: below,
                atFile: at,
                aboveFile: above,
              ),
          returnsNormally);
    });

    test('synthetic-spec error text byte-for-byte identical (F2 preservation)',
        () async {
      // Build a bracket-violation triad and run BOTH entrypoints. The
      // refactor extracted `_validateOneBracket(BracketSpec, ...)` as the
      // shared body, so error messages must match byte-for-byte between
      // (a) public validateBracket(named-args) and (b) validateBracketSpec.
      // Drift here breaks every existing test pinned on string-match.
      final tmp = await Directory.systemTemp.createTemp('sleuth_spec_eq_');
      addTearDown(() => tmp.delete(recursive: true));
      final belowF =
          _writeRoleCapture(tmp, 'below.json', role: 'below', observed: 800);
      final atF = _writeRoleCapture(tmp, 'at.json',
          role: 'at', observed: 1200); // > 1100 at-band ceiling
      final aboveF =
          _writeRoleCapture(tmp, 'above.json', role: 'above', observed: 1500);

      String? msgFromNamedArgs;
      try {
        ProfileCaptureSchema.validateBracket(
          belowFile: belowF,
          atFile: atF,
          aboveFile: aboveF,
          threshold: threshold,
          unit: unit,
        );
      } on FormatException catch (e) {
        msgFromNamedArgs = e.message;
      }

      String? msgFromSpec;
      try {
        ProfileCaptureSchema.validateBracketSpec(
          const BracketSpec(
            stableId: '',
            severityLabel: '',
            threshold: threshold,
            unit: unit,
            coveredThresholds: <String>{},
            profileCapturePaths: <String>[],
            requireDetectorTraceRecord: false,
          ),
          belowFile: belowF,
          atFile: atF,
          aboveFile: aboveF,
        );
      } on FormatException catch (e) {
        msgFromSpec = e.message;
      }

      expect(msgFromNamedArgs, isNotNull);
      expect(msgFromSpec, equals(msgFromNamedArgs),
          reason: 'synthetic-spec wrapper must produce byte-identical '
              'error text. Drift would break every existing string-match '
              'assertion in the audit + reproducer test suite.');
    });

    test('per-spec iteration: 2 specs both validate independently', () {
      final s1 = mkSpec();
      final s2 = mkSpec();
      expect(
          () => ProfileCaptureSchema.validateBracketSpec(
                s1,
                belowFile: below,
                atFile: at,
                aboveFile: above,
              ),
          returnsNormally);
      expect(
          () => ProfileCaptureSchema.validateBracketSpec(
                s2,
                belowFile: below,
                atFile: at,
                aboveFile: above,
              ),
          returnsNormally);
    });

    test(
        'NaN threshold rejection: error text byte-for-byte identical across '
        'both entrypoints', () {
      String? msgFromNamedArgs;
      try {
        ProfileCaptureSchema.validateBracket(
          belowFile: below,
          atFile: at,
          aboveFile: above,
          threshold: double.nan,
          unit: unit,
        );
      } on FormatException catch (e) {
        msgFromNamedArgs = e.message;
      }
      String? msgFromSpec;
      try {
        ProfileCaptureSchema.validateBracketSpec(
          BracketSpec(
            stableId: '',
            severityLabel: '',
            threshold: double.nan,
            unit: unit,
            coveredThresholds: const <String>{},
            profileCapturePaths: const <String>[],
            requireDetectorTraceRecord: false,
          ),
          belowFile: below,
          atFile: at,
          aboveFile: above,
        );
      } on FormatException catch (e) {
        msgFromSpec = e.message;
      }
      expect(msgFromNamedArgs, isNotNull);
      expect(msgFromSpec, equals(msgFromNamedArgs));
    });

    test(
        'below-not-below-threshold rejection: error text byte-for-byte '
        'identical across both entrypoints', () async {
      final tmp =
          await Directory.systemTemp.createTemp('sleuth_below_violation_');
      addTearDown(() => tmp.delete(recursive: true));
      final belowF = _writeRoleCapture(tmp, 'below.json',
          role: 'below', observed: 1100); // >= threshold = violation
      final atF = _writeRoleCapture(tmp, 'at.json', role: 'at', observed: 1050);
      final aboveF =
          _writeRoleCapture(tmp, 'above.json', role: 'above', observed: 1500);
      String? msgFromNamedArgs;
      try {
        ProfileCaptureSchema.validateBracket(
          belowFile: belowF,
          atFile: atF,
          aboveFile: aboveF,
          threshold: threshold,
          unit: unit,
        );
      } on FormatException catch (e) {
        msgFromNamedArgs = e.message;
      }
      String? msgFromSpec;
      try {
        ProfileCaptureSchema.validateBracketSpec(
          const BracketSpec(
            stableId: '',
            severityLabel: '',
            threshold: threshold,
            unit: unit,
            coveredThresholds: <String>{},
            profileCapturePaths: <String>[],
            requireDetectorTraceRecord: false,
          ),
          belowFile: belowF,
          atFile: atF,
          aboveFile: aboveF,
        );
      } on FormatException catch (e) {
        msgFromSpec = e.message;
      }
      expect(msgFromNamedArgs, isNotNull);
      expect(msgFromSpec, equals(msgFromNamedArgs));
    });
  });

  group('parseFile scenario-name ↔ file-path cross-check (v0.19.15)', () {
    late Directory tempRoot;
    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync('sleuth_scenario_path_');
    });
    tearDown(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    File writeCaptureWithScenario(String relativePath, String scenario) {
      final f = File('${tempRoot.path}/$relativePath');
      f.parent.createSync(recursive: true);
      // Mutate the anchor fixture so trace + magnitude pass and only the
      // scenario field is overridden — keeps the test focused on the
      // scenario-name check.
      final base =
          File('test/validation/captures/_fixtures/anchor_devtools_export.json')
              .readAsStringSync();
      final mutated = base.replaceFirst(
          RegExp(r'"scenario"\s*:\s*"[^"]*"'), '"scenario": "$scenario"');
      f.writeAsStringSync(mutated);
      return f;
    }

    test('basename-exact scenario passes', () {
      final f = writeCaptureWithScenario('det/foo_below.json', 'foo_below');
      expect(() => ProfileCaptureSchema.parseFile(f), returnsNormally);
    });

    test('directory-prefixed scenario passes', () {
      final f = writeCaptureWithScenario(
          'frame_timing/jank_detected_below.json',
          'frame_timing_jank_detected_below');
      expect(() => ProfileCaptureSchema.parseFile(f), returnsNormally);
    });

    test('family-prefixed scenario (RebuildDetector shape) passes', () {
      final f = writeCaptureWithScenario(
          'rebuild_detector/below.json', 'rebuild_activity_below');
      expect(() => ProfileCaptureSchema.parseFile(f), returnsNormally);
    });

    test('scenario disagreeing with basename rejected', () {
      final f =
          writeCaptureWithScenario('det/foo_below.json', 'wrong_scenario');
      expect(
          () => ProfileCaptureSchema.parseFile(f),
          throwsA(isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf([
                contains('"sleuthMetadata.scenario"'),
                contains('"wrong_scenario"'),
                contains('"foo_below"'),
              ]))));
    });

    test('_fixtures/ subdirectory bypasses cross-check', () {
      final f = writeCaptureWithScenario(
          '_fixtures/synth.json', 'arbitrary_unrelated_scenario');
      expect(() => ProfileCaptureSchema.parseFile(f), returnsNormally);
    });

    test('prose scenario in non-_fixtures directory rejected', () {
      // Outside `_fixtures/`, every scenario must satisfy basename-exact
      // or suffix-of-basename — including prose. A content-shape escape
      // would let a stale committed capture pass simply by phrasing its
      // scenario as prose, re-opening the gap the cross-check exists to
      // close.
      final f = writeCaptureWithScenario(
          'det/anything.json', 'Synthetic prose with spaces');
      expect(
          () => ProfileCaptureSchema.parseFile(f),
          throwsA(isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf([
                contains('"sleuthMetadata.scenario"'),
                contains('"Synthetic prose with spaces"'),
                contains('"anything"'),
              ]))));
    });

    test('dotfile basename (file ".json" only) rejected', () {
      // Operator-typo corner: a file literally named `.json` has no
      // name before the extension. `package:path.basenameWithoutExtension`
      // returns `.json` itself (dotfile semantics), so the suffix rule
      // becomes strict — `scenario.endsWith('_.json')` rejects any
      // ordinary scenario.
      final f = writeCaptureWithScenario('det/.json', 'anything_below');
      expect(
          () => ProfileCaptureSchema.parseFile(f),
          throwsA(isA<FormatException>().having(
              (e) => e.message,
              'message',
              allOf([
                contains('"sleuthMetadata.scenario"'),
                contains('"anything_below"'),
                contains('".json"'),
              ]))));
    });
  });

  // Pins the schema's per-record observed-axis cross-check skip
  // semantics. v0.19.18 declared `observedAxisArgKey` on
  // `MemoryPressureDetector.heap_growing` while leaving the existing 3
  // capture JSONs unmodified (recorded before the
  // `observedSlopeBytesPerSec` stamp existed). The schema's per-record
  // cross-check at `profile_capture_schema.dart` L1267-1269 must skip
  // silently when the spec declares the argKey but the records lack it
  // (the sample list stays empty); otherwise pre-stamp captures
  // regress across every detector that has not yet refreshed its
  // captures. This test pins that contract — DO NOT change L1267-1269
  // to throw on missing arg without addressing every detector's
  // pre-stamp captures first.
  group('observed-axis cross-check skip semantics (backward compat)', () {
    File capture(String role) => File(
        'test/validation/captures/network_monitor/slow_request_$role.json');

    test(
        'declared argKey + records lacking the arg → skip silently '
        '(no exception)', () {
      // Construct a synthetic capture triad by stripping the
      // `observedDurationMs` arg from every in-span issue record.
      // `validateBracket` must accept the triad when called with
      // `observedAxisArgKey: 'observedDurationMs'` AND
      // `observedAxisExpected: <something>` because the per-record
      // cross-check is gated on a non-empty samples list — empty here
      // because the arg was stripped from every record.
      File mutateStripObservedArg(String role, String argKeyToStrip) {
        final out = File('test/validation/captures/_fixtures/'
            'slow_request_${role}_no_observed_axis.json');
        // Generated once and committed (matches the
        // `slow_request_at_replayed_stripped.json` pattern); skip
        // regeneration on subsequent runs so CI does not rewrite
        // identical content unnecessarily.
        if (out.existsSync()) return out;
        final source = json.decode(capture(role).readAsStringSync())
            as Map<String, dynamic>;
        final events = (source['traceEvents'] as List).cast<dynamic>();
        for (var i = 0; i < events.length; i++) {
          final ev = events[i];
          if (ev is! Map) continue;
          final name = ev['name'];
          if (name is! String ||
              !name.startsWith('sleuth.issue.slow_request.warning')) {
            continue;
          }
          final args = ev['args'];
          if (args is! Map) continue;
          final cleaned = Map<String, dynamic>.from(args)
            ..remove(argKeyToStrip);
          final clone = Map<String, dynamic>.from(ev);
          clone['args'] = cleaned;
          events[i] = clone;
        }
        out.parent.createSync(recursive: true);
        out.writeAsStringSync(json.encode(source));
        return out;
      }

      final belowStripped =
          mutateStripObservedArg('below', 'observedDurationMs');
      final atStripped = mutateStripObservedArg('at', 'observedDurationMs');
      final aboveStripped =
          mutateStripObservedArg('above', 'observedDurationMs');

      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: belowStripped,
          atFile: atStripped,
          aboveFile: aboveStripped,
          threshold: 1000,
          unit: 'ms',
          requireDetectorTraceRecord: true,
          stableId: 'slow_request',
          severityLabel: 'warning',
          aboveCeilingMultiplier: 2.0,
          observedAxisArgKey: 'observedDurationMs',
          observedAxisTolerance: 0.25,
        ),
        returnsNormally,
        reason: 'Schema must skip the observed-axis cross-check when '
            'records carry no matching arg, even though the spec '
            'declared the argKey. Otherwise pre-stamp captures across '
            'every detector regress silently the moment a new tier-raise '
            'declares argKey. See profile_capture_schema.dart '
            'L1267-1269 for the gate.',
      );
    });
  });
}

Map<String, Object?> _validMetadata() => <String, Object?>{
      'device': 'iPhone 12',
      'deviceOsVersion': 'iOS 17.5',
      'flutterVersion': '3.41.4',
      'captureCommand': 'fvm flutter run --profile',
      'scenario': 'synthetic programmatic test body',
      'expectedMagnitude': {
        'min': 900,
        'observed': 1000,
        'max': 1100,
        'unit': 'ms',
      },
      'captureDate': '2026-04-18T16:00:00Z',
      'role': 'at',
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

/// Writes a synthetic capture file with the given [role] and observed
/// magnitude. Used by `validateBracket` tests that need triads where
/// each leg's `sleuthMetadata.role` matches its bracket slot but the
/// observed values can be tuned to violate downstream invariants
/// (ordering, tolerance, etc.) in isolation. Trace events span exactly
/// `observed * 1000` µs so AB-1 ratio = 1.0 and the inverse-ratio
/// half passes for at/above roles regardless of the bracket-violation
/// being exercised.
File _writeRoleCapture(
  Directory dir,
  String filename, {
  required String role,
  required num observed,
}) {
  final spanMicros = (observed * 1000).round();
  // Synthetic-test scenarios derive from filename basename so the
  // schema's scenario-name cross-check (basename-exact OR
  // suffix-of-basename) accepts these tempdir captures without needing
  // a content-shape escape hatch in production code.
  final basenameNoExt = filename.endsWith('.json')
      ? filename.substring(0, filename.length - '.json'.length)
      : filename;
  final metadata = <String, Object?>{
    'device': 'iPhone 12',
    'deviceOsVersion': 'iOS 17.5',
    'flutterVersion': '3.41.4',
    'captureCommand': 'fvm flutter run --profile',
    'scenario': 'synthetic_$basenameNoExt',
    'expectedMagnitude': {
      'min': observed * 0.5,
      'observed': observed,
      'max': observed * 1.5,
      'unit': 'ms',
    },
    'captureDate': '2026-04-26T00:00:00Z',
    'role': role,
  };
  final traceEvents = <Map<String, Object?>>[
    {
      'ph': 'M',
      'name': 'process_name',
      'pid': 1,
      'tid': 0,
      'args': {'name': 'test'}
    },
    {
      'ph': 'M',
      'name': 'thread_name',
      'pid': 1,
      'tid': 39,
      'args': {'name': '1.ui'}
    },
    {
      'ph': 'M',
      'name': 'thread_name',
      'pid': 1,
      'tid': 40,
      'args': {'name': '1.raster'}
    },
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
      'ts': 100 + spanMicros,
      's': 'p',
    },
    // 5 work-phase events to clear the schema's minWorkPhaseEvents=3
    // floor without skewing the bracket math.
    for (var i = 0; i < 5; i++)
      {
        'ph': 'X',
        'cat': 'flutter',
        'name': 'idle',
        'pid': 1,
        'tid': 39,
        'ts': 200 + i * 100,
        'dur': 50,
      },
  ];
  final body = jsonEncode({
    'traceEvents': traceEvents,
    'sleuthMetadata': metadata,
  });
  final file = File('${dir.path}/$filename');
  file.writeAsStringSync(body);
  return file;
}
