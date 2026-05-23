import 'dart:async';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('parseReachedAtLine', () {
    test('extracts host, port, interface from a typical dns-sd line', () {
      const line =
          '18:58:20.123  com\\.example\\.example._dartVmService._tcp.local. '
          'can be reached at Pengen.local.:53172 (interface 25) Flags: 1';
      final r = parseReachedAtLine(line);
      expect(r, isNotNull);
      expect(r!.host, 'Pengen.local.');
      expect(r.port, 53172);
      expect(r.interfaceIndex, 25);
    });

    test('matches WiFi-interface line (interface 15) too', () {
      const line = 'can be reached at host.local.:8080 (interface 15) Flags: 0';
      final r = parseReachedAtLine(line);
      expect(r, isNotNull);
      expect(r!.port, 8080);
      expect(r.interfaceIndex, 15);
    });

    test('non-matching lines return null', () {
      expect(parseReachedAtLine(''), isNull);
      expect(parseReachedAtLine('Lookup com\\.example...'), isNull);
      expect(parseReachedAtLine('authCode=abc123='), isNull);
    });
  });

  group('parseAuthCodeLine', () {
    test('extracts authCode and strips trailing =', () {
      expect(parseAuthCodeLine(' authCode=fiEVCvhg6Qg='), 'fiEVCvhg6Qg');
      expect(parseAuthCodeLine('authCode=abc123=='), 'abc123');
      expect(parseAuthCodeLine('authCode=plainvalue'), 'plainvalue');
    });

    test('non-matching lines return null', () {
      expect(parseAuthCodeLine(''), isNull);
      expect(parseAuthCodeLine('can be reached at ...'), isNull);
    });
  });

  group('collectBonjourAnnouncements', () {
    test('pairs reached-at + authCode line by line, in order', () async {
      final lines = Stream.fromIterable([
        'com.example._dartVmService._tcp.local. can be reached at '
            'host.local.:53172 (interface 25) Flags: 1',
        ' authCode=usbAuth=',
        'com.example._dartVmService._tcp.local. can be reached at '
            'host.local.:53173 (interface 15) Flags: 1',
        ' authCode=wifiAuth=',
      ]);
      final result = await collectBonjourAnnouncements(
        lines: lines,
        collectFor: const Duration(milliseconds: 200),
      );
      expect(result, hasLength(2));
      expect(result[0].port, 53172);
      expect(result[0].interfaceIndex, 25);
      expect(result[0].authCode, 'usbAuth');
      expect(result[1].port, 53173);
      expect(result[1].interfaceIndex, 15);
      expect(result[1].authCode, 'wifiAuth');
    });

    test('orphan authCode without a preceding reached-at is ignored', () async {
      final lines = Stream.fromIterable([
        ' authCode=ghost=',
        'can be reached at host.local.:1234 (interface 25) Flags: 1',
        ' authCode=real=',
      ]);
      final result = await collectBonjourAnnouncements(
        lines: lines,
        collectFor: const Duration(milliseconds: 200),
      );
      expect(result, hasLength(1));
      expect(result.first.authCode, 'real');
    });

    test('returns early when maxAnnouncements is hit', () async {
      // 3 announcements available but we cap at 2.
      final lines = Stream.fromIterable([
        'can be reached at h.local.:1 (interface 25) Flags: 1',
        ' authCode=one=',
        'can be reached at h.local.:2 (interface 15) Flags: 1',
        ' authCode=two=',
        'can be reached at h.local.:3 (interface 9) Flags: 1',
        ' authCode=three=',
      ]);
      final result = await collectBonjourAnnouncements(
        lines: lines,
        maxAnnouncements: 2,
        collectFor: const Duration(seconds: 2),
      );
      expect(result, hasLength(2));
      expect(result.last.authCode, 'two');
    });

    test('times out cleanly when no auth lines arrive', () async {
      final controller = StreamController<String>();
      // Emit nothing — wait for the timeout.
      final f = collectBonjourAnnouncements(
        lines: controller.stream,
        collectFor: const Duration(milliseconds: 80),
      );
      final result = await f;
      expect(result, isEmpty);
      await controller.close();
    });
  });

  group('selectUsbAnnouncement', () {
    BonjourAnnouncement ann(int iface, int port, String auth) =>
        BonjourAnnouncement(
          interfaceIndex: iface,
          host: 'h.local.',
          port: port,
          authCode: auth,
        );

    test('returns null on empty list', () async {
      expect(await selectUsbAnnouncement(const []), isNull);
    });

    test('returns the highest interface index when no override / probe',
        () async {
      // Order intentionally interleaved so neither input position nor a
      // naive `.last` would coincidentally pass.
      final list = [ann(15, 1, 'wifi'), ann(25, 2, 'usb'), ann(9, 3, 'low')];
      final picked = await selectUsbAnnouncement(list);
      expect(picked!.authCode, 'usb');
      expect(picked.interfaceIndex, 25);
    });

    test('prefers highest interface index across 3-way (15 vs 25 vs 24)',
        () async {
      // Models the real Pengen / iOS 17.5 ordering: WiFi first (iface 15),
      // then USB primary (25), then USB alt (24). 25 must win.
      final picked = await selectUsbAnnouncement([
        ann(15, 1234, 'wifi'),
        ann(25, 1234, 'usb-25'),
        ann(24, 1234, 'usb-24'),
      ]);
      expect(picked!.interfaceIndex, 25);
      expect(picked.authCode, 'usb-25');
    });

    test('single announcement is returned as-is', () async {
      final picked = await selectUsbAnnouncement([ann(15, 1234, 'only')]);
      expect(picked!.authCode, 'only');
    });

    test('--auth override picks the matching authCode', () async {
      final list = [ann(15, 1, 'wifi'), ann(25, 2, 'usb')];
      final picked = await selectUsbAnnouncement(list, authOverride: 'usb=');
      expect(picked!.port, 2);
    });

    test('--auth override returns null on no match', () async {
      final list = [ann(15, 1, 'wifi')];
      final picked = await selectUsbAnnouncement(list, authOverride: 'nope');
      expect(picked, isNull);
    });

    test('probe picks the first announcement that returns true', () async {
      final list = [ann(15, 1, 'wifi'), ann(25, 2, 'usb')];
      final picked = await selectUsbAnnouncement(
        list,
        probe: (a) async => a.authCode == 'usb',
      );
      expect(picked!.authCode, 'usb');
    });
  });

  group('runAttachIosCommand argv', () {
    test('missing UDID → exit 64 with usage', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final r = await runAttachIosCommand(
        args: const [],
        stdout_: out,
        stderr_: err,
        hasTool: (_) async => true,
      );
      expect(r.exitCode, 64);
      expect(err.toString(), contains('missing required <udid>'));
      expect(err.toString(), contains('sleuth_mcp attach-ios'));
    });

    test('unknown flag → exit 64', () async {
      final err = StringBuffer();
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--banana'],
        stdout_: StringBuffer(),
        stderr_: err,
        hasTool: (_) async => true,
      );
      expect(r.exitCode, 64);
      expect(err.toString(), contains('unknown flag: --banana'));
    });

    test('--port without value → exit 64', () async {
      final err = StringBuffer();
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--port'],
        stdout_: StringBuffer(),
        stderr_: err,
        hasTool: (_) async => true,
      );
      expect(r.exitCode, 64);
      expect(err.toString(), contains('--port requires a value'));
    });

    test('--port out of range → exit 64', () async {
      final err = StringBuffer();
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--port', '99999'],
        stdout_: StringBuffer(),
        stderr_: err,
        hasTool: (_) async => true,
      );
      expect(r.exitCode, 64);
      expect(err.toString(), contains('--port must be an integer'));
    });

    test('--help → exit 0 with usage', () async {
      final out = StringBuffer();
      final r = await runAttachIosCommand(
        args: const ['--help'],
        stdout_: out,
        stderr_: StringBuffer(),
        hasTool: (_) async => true,
      );
      expect(r.exitCode, 0);
      expect(out.toString(), contains('sleuth_mcp attach-ios'));
    });
  });

  group('runAttachIosCommand doctor', () {
    test('missing xcrun → exit 65 with macOS hint', () async {
      final err = StringBuffer();
      final r = await runAttachIosCommand(
        args: const ['ABC123'],
        stdout_: StringBuffer(),
        stderr_: err,
        hasTool: (t) async => t != 'xcrun',
      );
      expect(r.exitCode, 65);
      expect(err.toString(), contains('missing required tool: xcrun'));
      expect(err.toString(), contains('macOS-only'));
    });

    test('missing iproxy → exit 65 with brew hint', () async {
      final err = StringBuffer();
      final r = await runAttachIosCommand(
        args: const ['ABC123'],
        stdout_: StringBuffer(),
        stderr_: err,
        hasTool: (t) async => t != 'iproxy',
      );
      expect(r.exitCode, 65);
      expect(err.toString(), contains('missing required tool: iproxy'));
      expect(err.toString(), contains('brew install libimobiledevice'));
    });
  });

  group('runAttachIosCommand pipeline', () {
    test('devicectl failure → exit 66', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--bundle', 'com.foo.bar'],
        stdout_: out,
        stderr_: err,
        hasTool: (_) async => true,
        run: (exe, args) async {
          expect(exe, 'xcrun');
          expect(args, contains('--device'));
          expect(args, contains('ABC123'));
          expect(args, contains('com.foo.bar'));
          return ProcessResult(0, 1, '', 'device not found');
        },
        start: (_, __) async => throw StateError('should not spawn iproxy'),
        bonjourLines: (_, __) => const Stream.empty(), // never reached
      );
      expect(r.exitCode, 66);
      expect(err.toString(), contains('devicectl launch failed'));
      expect(err.toString(), contains('device not found'));
    });

    test('Bonjour returns empty → exit 67', () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final r = await runAttachIosCommand(
        args: const ['ABC123'],
        stdout_: out,
        stderr_: err,
        hasTool: (_) async => true,
        run: (_, __) async => ProcessResult(0, 0, '', ''),
        start: (_, __) async => throw StateError('should not spawn iproxy'),
        bonjourLines: (_, __) => const Stream.empty(),
        bonjourCollectFor: const Duration(milliseconds: 50),
        bonjourTimeout: const Duration(milliseconds: 200),
      );
      expect(r.exitCode, 67);
      expect(err.toString(), contains('no Bonjour announcement'));
    });

    test('success path: prints wsUri, returns exit 0 without waiting',
        () async {
      final out = StringBuffer();
      final err = StringBuffer();
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--port', '12345'],
        stdout_: out,
        stderr_: err,
        hasTool: (_) async => true,
        run: (_, __) async => ProcessResult(0, 0, '', ''),
        iproxyStart: (exe, args) async {
          expect(exe, 'iproxy');
          expect(args, ['12345', '53172', '--udid', 'ABC123']);
          // Use a real shell process that just sleeps briefly so we get
          // a valid pid + drainable streams; waitForSignal=false skips
          // the wait, so we kill it ourselves on teardown via the
          // returned object. The test relies on `iproxyStart` returning
          // a real Process; we use `sh -c "sleep 1"`.
          return Process.start('sh', ['-c', 'sleep 1']);
        },
        bonjourLines: (_, __) => Stream.fromIterable([
          'can be reached at h.local.:53172 (interface 25) Flags: 1',
          ' authCode=usbtoken=',
        ]),
        bonjourCollectFor: const Duration(milliseconds: 100),
        waitForSignal: false,
      );
      expect(r.exitCode, 0);
      expect(r.wsUri, 'ws://127.0.0.1:12345/usbtoken=/ws');
      expect(out.toString(), contains('wsUri: ws://127.0.0.1:12345/'));
      expect(out.toString(), contains('attach_app(debugUrl:'));
      expect(out.toString(), contains('Collected 1 announcement(s):'));
      expect(out.toString(), contains('iface 25: h.local.:53172'));
    });

    test('two pairings + --auth picks the matching authCode', () async {
      final out = StringBuffer();
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--auth', 'usbtoken'],
        stdout_: out,
        stderr_: StringBuffer(),
        hasTool: (_) async => true,
        run: (_, __) async => ProcessResult(0, 0, '', ''),
        iproxyStart: (_, __) async => Process.start('sh', ['-c', 'sleep 1']),
        bonjourLines: (_, __) => Stream.fromIterable([
          'can be reached at h.local.:8001 (interface 15) Flags: 1',
          ' authCode=wifitoken=',
          'can be reached at h.local.:8002 (interface 25) Flags: 1',
          ' authCode=usbtoken=',
        ]),
        bonjourCollectFor: const Duration(milliseconds: 100),
        waitForSignal: false,
      );
      expect(r.exitCode, 0);
      expect(r.wsUri, 'ws://127.0.0.1:8002/usbtoken=/ws');
    });

    test('--auth no match in announcements → exit 67', () async {
      final err = StringBuffer();
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--auth', 'absent'],
        stdout_: StringBuffer(),
        stderr_: err,
        hasTool: (_) async => true,
        run: (_, __) async => ProcessResult(0, 0, '', ''),
        start: (_, __) async => throw StateError('should not spawn'),
        bonjourLines: (_, __) => Stream.fromIterable([
          'can be reached at h.local.:1 (interface 25) Flags: 1',
          ' authCode=present=',
        ]),
        bonjourCollectFor: const Duration(milliseconds: 100),
        waitForSignal: false,
      );
      expect(r.exitCode, 67);
      expect(err.toString(), contains('no announcement matched --auth'));
    });

    test('wireless detected → wsUri uses .local hostname, no iproxy spawn',
        () async {
      final out = StringBuffer();
      var iproxySpawned = false;
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--wireless'],
        stdout_: out,
        stderr_: StringBuffer(),
        hasTool: (t) async => t != 'iproxy',
        run: (_, __) async => ProcessResult(0, 0, '', ''),
        iproxyStart: (_, __) async {
          iproxySpawned = true;
          return Process.start('sh', ['-c', 'sleep 1']);
        },
        bonjourLines: (_, __) => Stream.fromIterable([
          'can be reached at Pengen.local.:53172 (interface 25) Flags: 1',
          ' authCode=wifitoken=',
        ]),
        bonjourCollectFor: const Duration(milliseconds: 100),
        waitForSignal: false,
      );
      expect(r.exitCode, 0);
      expect(r.wsUri, 'ws://Pengen.local:53172/wifitoken=/ws');
      expect(iproxySpawned, isFalse,
          reason: 'wireless mode must not spawn iproxy');
      expect(out.toString(), contains('Wireless attach'));
    });

    test('--usb forces wired path even when devicectl reports wireless',
        () async {
      final out = StringBuffer();
      var iproxySpawned = false;
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--port', '54000', '--usb'],
        stdout_: out,
        stderr_: StringBuffer(),
        hasTool: (_) async => true,
        run: (_, __) async => ProcessResult(0, 0, '', ''),
        iproxyStart: (_, __) async {
          iproxySpawned = true;
          return Process.start('sh', ['-c', 'sleep 1']);
        },
        bonjourLines: (_, __) => Stream.fromIterable([
          'can be reached at h.local.:53172 (interface 25) Flags: 1',
          ' authCode=usbtoken=',
        ]),
        bonjourCollectFor: const Duration(milliseconds: 100),
        pidfileDirectory: Directory.systemTemp.createTempSync('s_').path,
        waitForSignal: false,
      );
      expect(r.exitCode, 0);
      expect(r.wsUri, 'ws://127.0.0.1:54000/usbtoken=/ws');
      expect(iproxySpawned, isTrue);
    });
  });

  group('detectIosTransport', () {
    test('parses wired transport from devicectl JSON', () async {
      const sample = '''
{"result": {"devices": [
  {"hardwareProperties": {"udid": "ABC123"},
   "connectionProperties": {"transportType": "wired"}}
]}}''';
      final t = await detectIosTransport(
        udid: 'ABC123',
        run: (_, __) async => ProcessResult(0, 0, sample, ''),
      );
      expect(t, IosTransport.wired);
    });

    test('parses wireless transport (localNetwork) from devicectl JSON',
        () async {
      const sample = '''
{"result": {"devices": [
  {"hardwareProperties": {"udid": "ABC123"},
   "connectionProperties": {"transportType": "localNetwork"}}
]}}''';
      final t = await detectIosTransport(
        udid: 'ABC123',
        run: (_, __) async => ProcessResult(0, 0, sample, ''),
      );
      expect(t, IosTransport.wireless);
    });

    test('matches udid case-insensitively', () async {
      const sample = '''
{"result": {"devices": [
  {"hardwareProperties": {"udid": "abc123"},
   "connectionProperties": {"transportType": "localNetwork"}}
]}}''';
      final t = await detectIosTransport(
        udid: 'ABC123',
        run: (_, __) async => ProcessResult(0, 0, sample, ''),
      );
      expect(t, IosTransport.wireless);
    });

    test('udid not in list → unknown', () async {
      const sample = '''
{"result": {"devices": [
  {"hardwareProperties": {"udid": "OTHER"},
   "connectionProperties": {"transportType": "wired"}}
]}}''';
      final t = await detectIosTransport(
        udid: 'ABC123',
        run: (_, __) async => ProcessResult(0, 0, sample, ''),
      );
      expect(t, IosTransport.unknown);
    });

    test('non-zero exit → unknown', () async {
      final t = await detectIosTransport(
        udid: 'ABC123',
        run: (_, __) async => ProcessResult(0, 1, '', 'boom'),
      );
      expect(t, IosTransport.unknown);
    });

    test('malformed JSON → unknown', () async {
      final t = await detectIosTransport(
        udid: 'ABC123',
        run: (_, __) async => ProcessResult(0, 0, 'not json', ''),
      );
      expect(t, IosTransport.unknown);
    });
  });

  group('pidfileForSession', () {
    test('path is deterministic on (udid, hostPort)', () {
      final a =
          pidfileForSession(directory: '/tmp', udid: 'ABC123', hostPort: 12345);
      final b =
          pidfileForSession(directory: '/tmp', udid: 'ABC123', hostPort: 12345);
      expect(a.path, b.path);
      expect(a.path, '/tmp/sleuth_mcp_iproxy_ABC123_12345.pid');
    });

    test('sanitises hostile udid characters', () {
      final f = pidfileForSession(
        directory: '/tmp',
        udid: '../../etc/passwd',
        hostPort: 80,
      );
      // No slashes allowed in the synthesised segment.
      expect(f.path.startsWith('/tmp/sleuth_mcp_iproxy_'), isTrue);
      expect(f.path.contains('..'), isFalse);
      expect(f.path.split('/').last.contains('/'), isFalse);
    });
  });

  group('reclaimStaleIproxy', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sleuth_attach_test_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('no pidfile → no-op', () async {
      final pidfile =
          pidfileForSession(directory: tmp.path, udid: 'U', hostPort: 9001);
      final calls = <List<String>>[];
      await reclaimStaleIproxy(
        pidfile: pidfile,
        hostPort: 9001,
        devicePort: 9001,
        udid: 'U',
        run: (exe, args) async {
          calls.add([exe, ...args]);
          return ProcessResult(0, 0, '', '');
        },
        err: StringBuffer(),
      );
      expect(calls, isEmpty);
      expect(pidfile.existsSync(), isFalse);
    });

    test('stale pidfile pointing at dead pid → removed cleanly', () async {
      final pidfile =
          pidfileForSession(directory: tmp.path, udid: 'U', hostPort: 9002);
      pidfile.writeAsStringSync('99999\n');
      final err = StringBuffer();
      await reclaimStaleIproxy(
        pidfile: pidfile,
        hostPort: 9002,
        devicePort: 9002,
        udid: 'U',
        run: (exe, args) async {
          if (exe == 'kill' && args.first == '-0') {
            return ProcessResult(0, 1, '', ''); // dead
          }
          throw StateError('unexpected call: $exe $args');
        },
        err: err,
      );
      expect(pidfile.existsSync(), isFalse);
      expect(err.toString(), isEmpty);
    });

    test('live pid with matching argv → SIGTERM + pidfile removed', () async {
      final pidfile =
          pidfileForSession(directory: tmp.path, udid: 'U', hostPort: 9003);
      pidfile.writeAsStringSync('42\n');
      var aliveCallCount = 0;
      final calls = <List<String>>[];
      final err = StringBuffer();
      await reclaimStaleIproxy(
        pidfile: pidfile,
        hostPort: 9003,
        devicePort: 9003,
        udid: 'U',
        run: (exe, args) async {
          calls.add([exe, ...args]);
          if (exe == 'kill' && args.first == '-0') {
            aliveCallCount++;
            // First check (initial liveness) → alive (0). All polls
            // after SIGTERM → dead (1) so the loop exits quickly.
            return ProcessResult(0, aliveCallCount == 1 ? 0 : 1, '', '');
          }
          if (exe == 'ps') {
            return ProcessResult(0, 0, 'iproxy 9003 9003 --udid U\n', '');
          }
          if (exe == 'kill' && args.first == '-TERM') {
            return ProcessResult(0, 0, '', '');
          }
          throw StateError('unexpected call: $exe $args');
        },
        err: err,
      );
      expect(pidfile.existsSync(), isFalse);
      expect(err.toString(), contains('removed stale iproxy'));
      expect(
          calls.any((c) => c.first == 'kill' && c.contains('-TERM')), isTrue);
    });

    test('live pid with mismatched argv → NOT killed, pidfile removed',
        () async {
      final pidfile =
          pidfileForSession(directory: tmp.path, udid: 'U', hostPort: 9004);
      pidfile.writeAsStringSync('1234\n');
      final calls = <List<String>>[];
      final err = StringBuffer();
      await reclaimStaleIproxy(
        pidfile: pidfile,
        hostPort: 9004,
        devicePort: 9004,
        udid: 'U',
        run: (exe, args) async {
          calls.add([exe, ...args]);
          if (exe == 'kill' && args.first == '-0') {
            return ProcessResult(0, 0, '', ''); // alive
          }
          if (exe == 'ps') {
            // Different command — someone else owns this pid now.
            return ProcessResult(
                0, 0, '/Applications/Editor.app/Contents/MacOS/Editor\n', '');
          }
          throw StateError('unexpected call: $exe $args');
        },
        err: err,
      );
      expect(pidfile.existsSync(), isFalse,
          reason: 'pidfile cleared even though the process is left alone');
      expect(err.toString(), contains('argv does not match'));
      expect(
          calls.any((c) =>
              c.first == 'kill' &&
              (c.contains('-TERM') || c.contains('-KILL'))),
          isFalse,
          reason: 'must not signal a process whose argv does not match');
    });

    test('garbage pidfile content → removed without ps/kill calls', () async {
      final pidfile =
          pidfileForSession(directory: tmp.path, udid: 'U', hostPort: 9005);
      pidfile.writeAsStringSync('not-a-pid\n');
      final calls = <List<String>>[];
      await reclaimStaleIproxy(
        pidfile: pidfile,
        hostPort: 9005,
        devicePort: 9005,
        udid: 'U',
        run: (exe, args) async {
          calls.add([exe, ...args]);
          return ProcessResult(0, 0, '', '');
        },
        err: StringBuffer(),
      );
      expect(pidfile.existsSync(), isFalse);
      expect(calls, isEmpty);
    });
  });

  group('runAttachIosCommand pidfile lifecycle', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sleuth_attach_pidfile_');
    });
    tearDown(() async {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    });

    test('success path writes pidfile to deterministic location', () async {
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--port', '54000'],
        stdout_: StringBuffer(),
        stderr_: StringBuffer(),
        hasTool: (_) async => true,
        run: (_, __) async => ProcessResult(0, 0, '', ''),
        start: (_, __) async =>
            throw StateError('should not use non-iproxy start'),
        iproxyStart: (exe, args) async {
          expect(exe, 'iproxy');
          return Process.start('sh', ['-c', 'sleep 1']);
        },
        bonjourLines: (_, __) => Stream.fromIterable([
          'can be reached at h.local.:53172 (interface 25) Flags: 1',
          ' authCode=usbtoken=',
        ]),
        bonjourCollectFor: const Duration(milliseconds: 100),
        pidfileDirectory: tmp.path,
        waitForSignal: false,
      );
      expect(r.exitCode, 0);
      final pidfile = pidfileForSession(
          directory: tmp.path, udid: 'ABC123', hostPort: 54000);
      expect(pidfile.existsSync(), isTrue,
          reason: 'pidfile must persist after waitForSignal:false return');
      final recorded = int.parse(pidfile.readAsStringSync().trim());
      expect(recorded, greaterThan(1));
    });

    test('graceful teardown via injected signal removes pidfile', () async {
      final signalController = StreamController<ProcessSignal>();
      // Inject signal after the wsUri has been printed.
      Timer(const Duration(milliseconds: 200), () {
        signalController.add(ProcessSignal.sigint);
      });
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--port', '54100'],
        stdout_: StringBuffer(),
        stderr_: StringBuffer(),
        hasTool: (_) async => true,
        run: (_, __) async => ProcessResult(0, 0, '', ''),
        iproxyStart: (_, __) async => Process.start('sh', ['-c', 'sleep 3']),
        bonjourLines: (_, __) => Stream.fromIterable([
          'can be reached at h.local.:53172 (interface 25) Flags: 1',
          ' authCode=usbtoken=',
        ]),
        bonjourCollectFor: const Duration(milliseconds: 100),
        pidfileDirectory: tmp.path,
        interruptStream: signalController.stream,
      );
      expect(r.exitCode, 0);
      final pidfile = pidfileForSession(
          directory: tmp.path, udid: 'ABC123', hostPort: 54100);
      expect(pidfile.existsSync(), isFalse,
          reason: 'graceful teardown must remove pidfile');
      await signalController.close();
    });

    test('SLEUTH_MCP_BONJOUR_COLLECT env override widens collect window',
        () async {
      // The override is read via the injected `environment:` map. We
      // don't measure timing — we assert the pipeline still produces a
      // wsUri so the env-override path is wired through.
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--port', '54300'],
        stdout_: StringBuffer(),
        stderr_: StringBuffer(),
        hasTool: (_) async => true,
        run: (_, __) async => ProcessResult(0, 0, '', ''),
        iproxyStart: (_, __) async => Process.start('sh', ['-c', 'sleep 1']),
        bonjourLines: (_, __) => Stream.fromIterable([
          'can be reached at h.local.:53172 (interface 25) Flags: 1',
          ' authCode=usbtoken=',
        ]),
        // call-site default 4s would dominate; env override widens to
        // 10s and the pipeline still succeeds (announcements come in
        // immediately from the synchronous Stream.fromIterable).
        bonjourCollectFor: const Duration(milliseconds: 100),
        pidfileDirectory: tmp.path,
        waitForSignal: false,
        environment: const {'SLEUTH_MCP_BONJOUR_COLLECT': '10'},
      );
      expect(r.exitCode, 0);
      expect(r.wsUri, isNotNull);
    });

    test('invalid SLEUTH_MCP_BONJOUR_COLLECT falls back to default', () async {
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--port', '54400'],
        stdout_: StringBuffer(),
        stderr_: StringBuffer(),
        hasTool: (_) async => true,
        run: (_, __) async => ProcessResult(0, 0, '', ''),
        iproxyStart: (_, __) async => Process.start('sh', ['-c', 'sleep 1']),
        bonjourLines: (_, __) => Stream.fromIterable([
          'can be reached at h.local.:53172 (interface 25) Flags: 1',
          ' authCode=usbtoken=',
        ]),
        bonjourCollectFor: const Duration(milliseconds: 100),
        pidfileDirectory: tmp.path,
        waitForSignal: false,
        environment: const {'SLEUTH_MCP_BONJOUR_COLLECT': 'not-a-number'},
      );
      expect(r.exitCode, 0,
          reason: 'invalid env value must fall back to call-site default');
      expect(r.wsUri, isNotNull);
    });

    test('readiness-window failure removes pidfile', () async {
      final r = await runAttachIosCommand(
        args: const ['ABC123', '--port', '54200'],
        stdout_: StringBuffer(),
        stderr_: StringBuffer(),
        hasTool: (_) async => true,
        run: (_, __) async => ProcessResult(0, 0, '', ''),
        iproxyStart: (_, __) async =>
            Process.start('sh', ['-c', 'echo failed >&2; exit 1']),
        bonjourLines: (_, __) => Stream.fromIterable([
          'can be reached at h.local.:53172 (interface 25) Flags: 1',
          ' authCode=usbtoken=',
        ]),
        bonjourCollectFor: const Duration(milliseconds: 100),
        readinessWindow: const Duration(seconds: 1),
        pidfileDirectory: tmp.path,
        waitForSignal: false,
      );
      expect(r.exitCode, 68);
      final pidfile = pidfileForSession(
          directory: tmp.path, udid: 'ABC123', hostPort: 54200);
      expect(pidfile.existsSync(), isFalse);
    });
  });
}
