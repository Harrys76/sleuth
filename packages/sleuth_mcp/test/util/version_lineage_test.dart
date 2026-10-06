import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:sleuth_mcp/src/util/version_lineage.dart'
    show acceptedPriorLineages;
import 'package:test/test.dart';

Map<String, Object?> _diagnose(Object? packageVersion) => {
  'connectionMode': 'full',
  'schemaVersion': 1,
  'sessionUuid': 'uuid',
  'data': {'packageVersion': packageVersion, 'vmConnected': true},
};

void main() {
  group('versionLineage', () {
    test('returns major.minor for a semver version', () {
      expect(versionLineage('0.37.0'), '0.37');
      expect(versionLineage('0.36.12'), '0.36');
      expect(versionLineage('1.0.0'), '1.0');
    });

    test('classifies a prerelease or build by its major.minor', () {
      expect(versionLineage('0.37.0-dev.1'), '0.37');
      expect(versionLineage('0.36.0+build'), '0.36');
      expect(versionLineage('0.37.1-rc.2+sha.5114f85'), '0.37');
    });

    test('returns null for anything that is not semver major.minor.patch', () {
      for (final bad in [
        '',
        '0.36',
        '0',
        '0.37.garbage',
        '0.37.0.1',
        '0.37.0-',
        '0.37.0+',
        '00.37.0',
        '0.037.0',
        'v0.37.0',
        ' 0.37.0',
        '0.37.0 ',
      ]) {
        expect(versionLineage(bad), isNull, reason: '"$bad" must not parse');
      }
    });

    test(
      'the sidecar pin and every accepted prior lineage are well formed',
      () {
        expect(versionLineage(sleuthPackageVersionPin), isNotNull);
        for (final lineage in acceptedPriorLineages) {
          expect(versionLineage('$lineage.0'), lineage);
        }
      },
    );
  });

  group('defaultVersionSkewValidator', () {
    test('accepts the pin, its patches and prereleases, and 0.36', () async {
      for (final ok in [
        sleuthPackageVersionPin,
        '0.37.4',
        '0.37.0-dev.1',
        '0.36.0',
        '0.36.0+build',
      ]) {
        expect(
          await defaultVersionSkewValidator(_diagnose(ok)),
          isNull,
          reason: '$ok must connect',
        );
      }
    });

    test('refuses 0.35 and 0.38 lineages as version_skew_major', () async {
      for (final refused in ['0.35.0', '0.35.9', '0.38.0', '0.38.0-dev.1']) {
        expect(
          await defaultVersionSkewValidator(_diagnose(refused)),
          startsWith('version_skew_major:'),
          reason: '$refused must be refused',
        );
      }
    });

    test(
      'refuses malformed or missing versions as version_skew_unknown',
      () async {
        for (final malformed in <Object?>[
          '0.36',
          '0.37.garbage',
          '',
          37,
          null,
        ]) {
          expect(
            await defaultVersionSkewValidator(_diagnose(malformed)),
            startsWith('version_skew_unknown:'),
            reason: '$malformed must fail closed',
          );
        }
      },
    );
  });

  group('connect warning by lineage', () {
    for (final (version, warning) in <(String, String)>[
      ('0.37.0-dev.1', 'version_skew_minor'),
      ('0.36.0+build', 'version_skew_prior_lineage'),
    ]) {
      test('$version connects with $warning', () async {
        final bridge = FakeVmBridge(fakeSessionUuid: 'uuid')
          ..setEnvelope('ext.sleuth.diagnose', _diagnose(version));
        final result =
            await builtInTools['connect']!.handler(bridge, {
                  'uri': 'ws://localhost/ws',
                })
                as Map<String, Object?>;
        expect(result['warning'], warning);
        expect(bridge.isConnected, isTrue);
      });
    }
  });
}
