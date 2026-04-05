import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/ai/ai_providers.dart';

void main() {
  group('SseLineParser', () {
    late SseLineParser parser;

    setUp(() => parser = SseLineParser());

    test('single complete line', () {
      final lines = parser.addChunk('data: hello\n');
      expect(lines, ['data: hello']);
    });

    test('multiple lines in one chunk', () {
      final lines = parser.addChunk('line1\nline2\nline3\n');
      expect(lines, ['line1', 'line2', 'line3']);
    });

    test('line split across two chunks', () {
      final lines1 = parser.addChunk('data: hel');
      expect(lines1, isEmpty);

      final lines2 = parser.addChunk('lo world\n');
      expect(lines2, ['data: hello world']);
    });

    test('empty lines preserved', () {
      final lines = parser.addChunk('data: a\n\ndata: b\n');
      expect(lines, ['data: a', '', 'data: b']);
    });

    test('trailing content without newline is buffered', () {
      final lines1 = parser.addChunk('data: partial');
      expect(lines1, isEmpty);

      final lines2 = parser.addChunk(' end\n');
      expect(lines2, ['data: partial end']);
    });

    test('carriage return + newline handled', () {
      final lines = parser.addChunk('data: hello\r\n');
      expect(lines, ['data: hello']);
    });

    test('large chunk with many lines', () {
      final chunk = '${List.generate(50, (i) => 'line$i').join('\n')}\n';
      final lines = parser.addChunk(chunk);
      expect(lines, hasLength(50));
      expect(lines.first, 'line0');
      expect(lines.last, 'line49');
    });

    test('empty chunk returns no lines', () {
      final lines = parser.addChunk('');
      expect(lines, isEmpty);
    });

    test('sequential chunks accumulate correctly', () {
      expect(parser.addChunk('da'), isEmpty);
      expect(parser.addChunk('ta:'), isEmpty);
      expect(parser.addChunk(' he'), isEmpty);
      expect(parser.addChunk('llo\n'), ['data: hello']);
    });

    test('multiple splits then complete lines', () {
      expect(parser.addChunk('first'), isEmpty);
      final lines = parser.addChunk('\nsecond\nthird');
      expect(lines, ['first', 'second']);
      // 'third' still buffered
      expect(parser.addChunk('\n'), ['third']);
    });

    test('newline-only chunk flushes buffer', () {
      parser.addChunk('buffered');
      final lines = parser.addChunk('\n');
      expect(lines, ['buffered']);
    });

    test('consecutive newlines produce empty strings', () {
      final lines = parser.addChunk('\n\n\n');
      expect(lines, ['', '', '']);
    });
  });
}
