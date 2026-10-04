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
    expect(File('${dir.path}/state.json.tmp').existsSync(), isFalse);
  });
}
