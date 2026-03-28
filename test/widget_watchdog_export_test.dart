import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/widget_watchdog.dart';

void main() {
  group('WidgetWatchdog static export API', () {
    tearDown(() {
      // Ensure clean state between tests
      // ignore: invalid_use_of_visible_for_testing_member
      WidgetWatchdog.notifyControllerDisposed(
        // Call with a dummy to not accidentally clear a real one.
        // The real cleanup happens when the widget is disposed.
        _DummyController(),
      );
    });

    test('returns null before wrap()', () {
      expect(WidgetWatchdog.exportSnapshot(), isNull);
      expect(WidgetWatchdog.exportSnapshotJson(), isNull);
    });

    testWidgets('returns non-null after wrap()', (tester) async {
      final widget = WidgetWatchdog.wrap(
        child: const MaterialApp(home: Scaffold()),
      );
      await tester.pumpWidget(widget);

      expect(WidgetWatchdog.exportSnapshot(), isNotNull);
      expect(WidgetWatchdog.exportSnapshotJson(), isNotNull);

      final snapshot = WidgetWatchdog.exportSnapshot()!;
      expect(snapshot.packageVersion, isNotEmpty);
    });

    testWidgets('returns null after overlay dispose', (tester) async {
      // Pump the watchdog overlay
      final key = UniqueKey();
      await tester.pumpWidget(
        KeyedSubtree(
          key: key,
          child: WidgetWatchdog.wrap(
            child: const MaterialApp(home: Scaffold()),
          ),
        ),
      );
      expect(WidgetWatchdog.exportSnapshot(), isNotNull);

      // Replace with an empty widget — triggers WatchdogOverlay.dispose()
      await tester.pumpWidget(const SizedBox());

      expect(WidgetWatchdog.exportSnapshot(), isNull);
      expect(WidgetWatchdog.exportSnapshotJson(), isNull);
    });
  });
}

/// Dummy controller for tearDown cleanup.
class _DummyController extends WatchdogController {}
