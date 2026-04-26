// Anchor-fixture grounding test for `ProfileCaptureSchema`.
//
// The dedicated anchor fixture (`anchor_devtools_export.json`) is the
// last line of defence against schema-vs-reality drift: a shape-faithful
// mirror of a DevTools Performance "Export timeline" output. This test
// asserts the anchor parses cleanly AND pins the fields future
// contributors rely on so a silent shape change fails here first.
//
// When v0.16.4 lands the first real `runtimeVerified` capture, the anchor
// will be replaced in-place with a real DevTools export. This test
// should continue to pass — if it fails, the schema drifted away from
// the exporter's real output and the schema is the thing that needs to
// flex, not the anchor.

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

void main() {
  group('ProfileCaptureSchema anchor fixture', () {
    final anchor =
        File('test/validation/captures/_fixtures/anchor_devtools_export.json');

    test('anchor fixture exists on disk', () {
      expect(anchor.existsSync(), isTrue,
          reason: 'The anchor fixture is the contract against schema '
              'drift — it must exist.');
    });

    test('anchor fixture satisfies the schema', () {
      expect(() => ProfileCaptureSchema.parseFile(anchor), returnsNormally);
    });

    test('anchor metadata pins the pinned reference environment', () {
      final meta = ProfileCaptureSchema.parseFile(anchor);
      expect(meta['device'], 'iPhone 13 mini');
      expect(meta['deviceOsVersion'], 'iOS 17.6.1');
      // Anchor must track the pinned Flutter major.minor so a rotation
      // can't happen silently.
      final version = meta['flutterVersion'] as String;
      expect(version.startsWith(ProfileCaptureSchema.approvedFlutterMajorMinor),
          isTrue,
          reason: 'Anchor Flutter version ($version) must match the pinned '
              'major.minor (${ProfileCaptureSchema.approvedFlutterMajorMinor}.x).');
    });

    // CLAUDE-R3-1: pin a structural fingerprint of the anchor fixture so
    // unintended edits (e.g. a well-meaning format touch-up, a field
    // rename during refactoring, a synthetic event swap) fail this test.
    // Intentional updates require also updating _expectedAnchorSha256 —
    // that's the point: a single-line PR diff flags "anchor changed"
    // so reviewers look.
    test('anchor fixture byte-for-byte fingerprint is pinned (CLAUDE-R3-1)',
        () {
      final bytes = anchor.readAsBytesSync();
      final digest = sha256.convert(bytes).toString();
      expect(digest, equals(_expectedAnchorSha256),
          reason: 'The anchor fixture bytes changed. If this was '
              'intentional (e.g. replacing the synthetic anchor with a '
              'real DevTools export in v0.16.4), update '
              '_expectedAnchorSha256 in this file to the new digest and '
              'call it out in the PR description. Unintentional edits '
              'should be reverted — the anchor is the schema-drift '
              'contract.');
    });
  });
}

/// SHA-256 of `test/validation/captures/_fixtures/anchor_devtools_export.json`
/// as of v0.16.4 (added `provenance` field declaring the anchor as
/// shape-faithful synthetic, plus the 3.32 → 3.41 `flutterVersion`
/// rotation). Regenerate when the anchor is intentionally
/// replaced: run
/// `shasum -a 256 test/validation/captures/_fixtures/anchor_devtools_export.json`
/// and paste the new digest here.
const String _expectedAnchorSha256 =
    'c6d63ce6ae6c8fdbb85ab2f2c8e7a2398b82a6d2f21aac7d6e7706707a447f85';
