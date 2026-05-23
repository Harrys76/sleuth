import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/vm/service_extension_handlers.dart';

void main() {
  test('kSleuthPackageVersion matches pubspec.yaml version', () {
    final pubspecFile = File('pubspec.yaml');
    expect(
      pubspecFile.existsSync(),
      isTrue,
      reason: 'run from repo root — `pubspec.yaml` not found in CWD '
          '(${Directory.current.path})',
    );
    final pubspec = pubspecFile.readAsStringSync();
    final match =
        RegExp(r'^version:\s*(.+)$', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml missing version line');
    final pubspecVersion = match!.group(1)!.trim();
    expect(
      kSleuthPackageVersion,
      pubspecVersion,
      reason:
          'kSleuthPackageVersion (in lib/src/vm/service_extension_handlers.dart) '
          'is out of sync with pubspec.yaml. Update both together when bumping.',
    );
  });
}
