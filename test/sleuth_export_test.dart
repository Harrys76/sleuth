import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/sleuth.dart';

void main() {
  group('Sleuth static export API', () {
    tearDown(() {
      // Ensure clean state between tests
      // ignore: invalid_use_of_visible_for_testing_member
      Sleuth.notifyControllerDisposed(
        // Call with a dummy to not accidentally clear a real one.
        // The real cleanup happens when the widget is disposed.
        _DummyController(),
      );
    });

    test('returns null before wrap()', () {
      expect(Sleuth.exportSnapshot(), isNull);
      expect(Sleuth.exportSnapshotJson(), isNull);
    });

    testWidgets('returns non-null after wrap()', (tester) async {
      final widget = Sleuth.track(
        child: const MaterialApp(home: Scaffold()),
      );
      await tester.pumpWidget(widget);

      expect(Sleuth.exportSnapshot(), isNotNull);
      expect(Sleuth.exportSnapshotJson(), isNotNull);

      final snapshot = Sleuth.exportSnapshot()!;
      expect(snapshot.packageVersion, isNotEmpty);
    });

    testWidgets('returns null after overlay dispose', (tester) async {
      // Pump the sleuth overlay
      final key = UniqueKey();
      await tester.pumpWidget(
        KeyedSubtree(
          key: key,
          child: Sleuth.track(
            child: const MaterialApp(home: Scaffold()),
          ),
        ),
      );
      expect(Sleuth.exportSnapshot(), isNotNull);

      // Replace with an empty widget — triggers SleuthOverlay.dispose()
      await tester.pumpWidget(const SizedBox());

      expect(Sleuth.exportSnapshot(), isNull);
      expect(Sleuth.exportSnapshotJson(), isNull);
    });
  });
}

/// Dummy controller for tearDown cleanup.
class _DummyController extends SleuthController {}
