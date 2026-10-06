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
}
