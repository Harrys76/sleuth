import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/utils/source_location_cache.dart';

void main() {
  group('SourceLocationCache.abbreviatePath', () {
    test('strips everything before lib/', () {
      expect(
        SourceLocationCache.abbreviatePath(
            '/Users/dev/myapp/lib/screens/home.dart'),
        'lib/screens/home.dart',
      );
    });

    test('handles path starting with lib/', () {
      expect(
        SourceLocationCache.abbreviatePath('lib/main.dart'),
        'lib/main.dart',
      );
    });

    test('no lib/ — returns last 2 segments', () {
      expect(
        SourceLocationCache.abbreviatePath('/usr/local/share/widget.dart'),
        'share/widget.dart',
      );
    });

    test('single segment path returned as-is', () {
      expect(
        SourceLocationCache.abbreviatePath('main.dart'),
        'main.dart',
      );
    });

    test('empty path returned as-is', () {
      expect(
        SourceLocationCache.abbreviatePath(''),
        '',
      );
    });

    test('path with multiple lib/ occurrences uses first', () {
      expect(
        SourceLocationCache.abbreviatePath('/app/lib/src/lib/widget.dart'),
        'lib/src/lib/widget.dart',
      );
    });

    test('file:// URI path with lib/', () {
      expect(
        SourceLocationCache.abbreviatePath(
            'file:///Users/dev/myapp/lib/main.dart'),
        'lib/main.dart',
      );
    });
  });

  group('SourceLocationCache', () {
    test('clear resets length to zero', () {
      final cache = SourceLocationCache();
      // No entries after construction
      expect(cache.length, 0);
      cache.clear();
      expect(cache.length, 0);
    });

    test('maxEntries defaults to 200', () {
      final cache = SourceLocationCache();
      expect(cache.maxEntries, 200);
    });

    test('custom maxEntries respected', () {
      final cache = SourceLocationCache(maxEntries: 10);
      expect(cache.maxEntries, 10);
    });
  });

  group('SourceLocationCache with widget tree', () {
    testWidgets('lookup returns location for tracked widget', (tester) async {
      final cache = SourceLocationCache();

      await tester.pumpWidget(const _TestWidget());

      final element = tester.element(find.byType(_TestWidget));
      final location = cache.lookup(element);

      // In test mode, --track-widget-creation is enabled.
      // The location should contain this test file's path and a line number.
      expect(location, isNotNull);
      expect(location, contains('source_location_cache_test.dart:'));
    });

    testWidgets('lookup caches by widget type', (tester) async {
      final cache = SourceLocationCache();

      await tester.pumpWidget(const _TestWidget());

      final element = tester.element(find.byType(_TestWidget));
      final first = cache.lookup(element);
      final second = cache.lookup(element);

      expect(first, isNotNull);
      expect(second, first); // Same cached value
      expect(cache.length, 1);
    });

    testWidgets('bounded at maxEntries', (tester) async {
      final cache = SourceLocationCache(maxEntries: 1);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [_TestWidget(), _OtherTestWidget()]),
        ),
      );

      final element1 = tester.element(find.byType(_TestWidget));
      final element2 = tester.element(find.byType(_OtherTestWidget));

      // First lookup fills the single slot.
      final loc1 = cache.lookup(element1);
      expect(loc1, isNotNull);
      expect(cache.length, 1);

      // Second type cannot be cached — returns null.
      final loc2 = cache.lookup(element2);
      expect(loc2, isNull);
      expect(cache.length, 1);
    });

    testWidgets('clear allows re-caching', (tester) async {
      final cache = SourceLocationCache(maxEntries: 1);

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(children: [_TestWidget(), _OtherTestWidget()]),
        ),
      );

      final element1 = tester.element(find.byType(_TestWidget));
      final element2 = tester.element(find.byType(_OtherTestWidget));

      cache.lookup(element1);
      expect(cache.length, 1);

      cache.clear();
      expect(cache.length, 0);

      // Now the other type can be cached.
      final loc = cache.lookup(element2);
      expect(loc, isNotNull);
      expect(cache.length, 1);
    });

    testWidgets('location path is abbreviated', (tester) async {
      final cache = SourceLocationCache();

      await tester.pumpWidget(const _TestWidget());

      final element = tester.element(find.byType(_TestWidget));
      final location = cache.lookup(element);

      // Should not contain the full absolute path
      expect(location, isNotNull);
      // The path should either start with "test/" (abbreviated from full path
      // using last 2 segments) or "lib/" — since this widget is in a test file,
      // it won't have "lib/" but will have the test file's abbreviated path.
      expect(location!.contains('/Users/'), isFalse);
    });
  });
}

class _TestWidget extends StatelessWidget {
  const _TestWidget();

  @override
  Widget build(BuildContext context) => const SizedBox.shrink(key: Key('test'));
}

class _OtherTestWidget extends StatelessWidget {
  const _OtherTestWidget();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.shrink(key: Key('other'));
}
