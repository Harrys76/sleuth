import 'dart:io';

import 'package:test/test.dart';

/// Light coverage for the bash wrapper at `tool/attach_ios.sh`. The
/// Dart subcommand (`sleuth_mcp attach-ios`) has full coverage in
/// `attach_ios_command_test.dart`; these tests only exercise the
/// early argv-parse path (no `xcrun` / `dns-sd` / `iproxy` required),
/// so they run on every platform that ships `bash`.
void main() {
  // The Dart test process cwd is the package root (`packages/sleuth_mcp`).
  final script = File('tool/attach_ios.sh');

  test('exists and is executable', () {
    expect(script.existsSync(), isTrue,
        reason: 'tool/attach_ios.sh missing from package');
    final stat = script.statSync();
    // Owner execute bit must be set so `dart pub global activate` users
    // can `bash tool/attach_ios.sh` directly without chmod-ing.
    expect(stat.mode & 0x40, isNot(0),
        reason: 'tool/attach_ios.sh missing owner-execute bit '
            '(mode=${stat.modeString()})');
  });

  test('prints usage on missing UDID', () async {
    final r = await Process.run('bash', [script.absolute.path]);
    expect(r.exitCode, 64,
        reason: 'expected sysexits EX_USAGE (64); stderr=${r.stderr}');
    expect(r.stderr.toString(), contains('usage:'));
  });

  test('rejects unknown flag', () async {
    final r = await Process.run('bash', [script.absolute.path, '--bogus']);
    expect(r.exitCode, 64);
    expect(r.stderr.toString(), contains('unknown flag'));
  });

  test('--help exits 0 and prints usage to stdout', () async {
    final r = await Process.run('bash', [script.absolute.path, '--help']);
    expect(r.exitCode, 0);
    expect(r.stdout.toString(), contains('usage:'));
    expect(r.stdout.toString(), contains('--bundle'));
  });
}
