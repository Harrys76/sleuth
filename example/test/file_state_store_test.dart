import 'dart:io';

import 'package:example/file_state_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('sleuth_store'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('reads null before the first write, then the last write', () async {
    final store = FileSleuthStateStore(File('${dir.path}/state.json'));
    expect(await store.read(), isNull);
    await store.write('{"schemaVersion":1}');
    await store.write('{"schemaVersion":1,"hiddenKeys":["a"]}');
    expect(await store.read(), '{"schemaVersion":1,"hiddenKeys":["a"]}');
    expect(dir.listSync().map((e) => e.path.split('/').last), ['state.json']);
  });

  test('a write that finishes after a newer one does not replace it', () async {
    final file = File('${dir.path}/state.json');
    final store = FileSleuthStateStore(file);
    // Both writes run at once; whichever finishes its temp file last, the
    // newer state is the one kept.
    final older = store.write('{"schemaVersion":1,"hiddenKeys":["old"]}');
    final newer = store.write('{"schemaVersion":1,"hiddenKeys":["new"]}');
    await Future.wait([newer, older]);
    expect(await store.read(), '{"schemaVersion":1,"hiddenKeys":["new"]}');
    expect(dir.listSync().map((e) => e.path.split('/').last), ['state.json']);
  });

  test('a file that is not UTF-8 reads as no saved state', () async {
    final file = File('${dir.path}/state.json')
      ..writeAsBytesSync([0xff, 0xfe, 0x00, 0x7b]);
    expect(await FileSleuthStateStore(file).read(), isNull);
  });

  test('a write creates the directory the file goes in', () async {
    final store = FileSleuthStateStore(File('${dir.path}/files/state.json'));
    await store.write('{"schemaVersion":2}');
    expect(await store.read(), '{"schemaVersion":2}');
  });

  group('overlayStateDirectory', () {
    // Android empties code_cache on every install of a new build.
    test('Android keeps the file in files beside code_cache', () {
      final picked = overlayStateDirectory(
        Directory('/data/user/0/com.example.example/code_cache'),
        'android',
      );
      expect(picked.path, '/data/user/0/com.example.example/files');
    });

    test('iOS keeps the file in Library/Application Support beside tmp', () {
      final picked = overlayStateDirectory(
        Directory('/var/mobile/Containers/Data/Application/ABC/tmp/'),
        'ios',
      );
      expect(
        picked.path,
        '/var/mobile/Containers/Data/Application/ABC/Library/'
        'Application Support',
      );
    });

    test('another layout or platform keeps the temp directory', () {
      final elsewhere = Directory('/tmp/sleuth');
      expect(overlayStateDirectory(elsewhere, 'android'), same(elsewhere));
      expect(overlayStateDirectory(elsewhere, 'ios'), same(elsewhere));
      final tmp = Directory('/var/folders/x/T/tmp');
      expect(overlayStateDirectory(tmp, 'macos'), same(tmp));
    });
  });
}
