import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/persistence/sleuth_state_store.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';
import 'package:sleuth/src/vm/service_extension_handlers.dart';

import '../helpers/overlay_harness.dart';

/// Store whose read completes when the test says so.
class _ControlledStore implements SleuthStateStore {
  final Completer<String?> readCompleter = Completer<String?>();
  final List<String> writes = [];
  bool failWrites = false;

  @override
  Future<String?> read() => readCompleter.future;

  @override
  Future<void> write(String json) async {
    if (failWrites) throw StateError('disk full');
    writes.add(json);
  }
}

/// Store whose writes complete when the test says so.
class _SlowWriteStore implements SleuthStateStore {
  final List<String> started = [];
  final List<Completer<void>> pending = [];
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<String?> read() async => null;

  @override
  Future<void> write(String json) {
    started.add(json);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    final c = Completer<void>();
    pending.add(c);
    return c.future.whenComplete(() => inFlight--);
  }

  void completeNext() => pending.removeAt(0).complete();
}

class _ThrowingStore implements SleuthStateStore {
  @override
  Future<String?> read() => throw StateError('no access');

  @override
  Future<void> write(String json) async {}
}

PerformanceIssue _issue(String id) => PerformanceIssue(
  severity: IssueSeverity.warning,
  category: IssueCategory.build,
  confidence: IssueConfidence.likely,
  title: id,
  detail: 'detail',
  fixHint: 'fix',
  stableId: id,
);

/// Tree that triggers `non_lazy_list`.
Widget _listTree() => Directionality(
  textDirection: TextDirection.ltr,
  child: SingleChildScrollView(
    child: Column(
      children: List.generate(
        55,
        (i) => SizedBox(key: ValueKey(i), height: 10),
      ),
    ),
  ),
);

/// Controller with [store], test-initialised; `initialize()` only starts
/// the state load.
SleuthController _controller(SleuthStateStore store) {
  final c = SleuthController(config: SleuthConfig(stateStore: store))
    ..initializeDetectorsForTest()
    ..markInitializedForTest();
  unawaited(c.initialize());
  return c;
}

void main() {
  group('state store load', () {
    testWidgets('trigger paints only after the stored state is applied', (
      tester,
    ) async {
      final store = _ControlledStore();
      final controller = await pumpOverlay(
        tester,
        config: SleuthConfig(stateStore: store),
      );
      controller.issuesNotifier.value = [_issue('a'), _issue('b')];
      await tester.pump();

      expect(controller.uiStateReady.value, isFalse);
      expect(find.byIcon(Icons.pets), findsNothing);

      store.readCompleter.complete(
        jsonEncode({
          'schemaVersion': 1,
          'hiddenKeys': ['a'],
        }),
      );
      await tester.pump();
      await tester.pump();

      expect(controller.uiStateReady.value, isTrue);
      expect(controller.overlayUiState.hiddenKeys, {'a'});
      expect(find.byIcon(Icons.pets), findsOneWidget);
      // The badge counts the visible card only.
      expect(find.bySemanticsLabel('Open Sleuth, 1 issue'), findsOneWidget);
    });

    testWidgets('a throwing store yields defaults and ready', (tester) async {
      final controller = _controller(_ThrowingStore());
      addTearDown(controller.dispose);
      await tester.pump();
      expect(controller.uiStateReady.value, isTrue);
      expect(controller.overlayUiState.hiddenKeys, isEmpty);
    });

    for (final garbage in [
      'not json',
      '[1, 2]',
      '{"schemaVersion": 9, "hiddenKeys": ["x"]}',
      '{"hiddenKeys": ["x"]}',
    ]) {
      testWidgets('unreadable data yields defaults and ready: $garbage', (
        tester,
      ) async {
        final controller = _controller(InMemorySleuthStateStore(garbage));
        addTearDown(controller.dispose);
        await tester.pump();
        expect(controller.uiStateReady.value, isTrue);
        expect(controller.overlayUiState.hiddenKeys, isEmpty);
      });
    }

    testWidgets('a read that never completes is cut at 2 s', (tester) async {
      final controller = _controller(_ControlledStore());
      addTearDown(controller.dispose);
      await tester.pump(const Duration(milliseconds: 1900));
      expect(controller.uiStateReady.value, isFalse);
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.uiStateReady.value, isTrue);
    });

    testWidgets('after a timed-out read the session never writes', (
      tester,
    ) async {
      final store = _ControlledStore();
      final controller = _controller(store);
      addTearDown(controller.dispose);
      await tester.pump(const Duration(milliseconds: 2100));
      expect(controller.uiStateReady.value, isTrue);

      controller.overlayUiState.hide('k');
      await tester.pump(const Duration(seconds: 1));
      expect(controller.overlayUiState.hiddenKeys, {'k'});

      // A late read changes nothing and still enables no writes.
      store.readCompleter.complete(
        jsonEncode({
          'schemaVersion': 1,
          'hiddenKeys': ['late'],
        }),
      );
      await tester.pump();
      controller.overlayUiState.hide('k2');
      await tester.pump(const Duration(seconds: 1));
      expect(controller.overlayUiState.hiddenKeys, {'k', 'k2'});
      expect(store.writes, isEmpty);
    });

    testWidgets('changes made before the read completes are kept', (
      tester,
    ) async {
      final store = _ControlledStore();
      final controller = _controller(store);
      addTearDown(controller.dispose);

      controller.overlayUiState
        ..hide('local')
        ..toggleSeverity(IssueSeverity.ok);
      store.readCompleter.complete(
        jsonEncode({
          'schemaVersion': 1,
          'hiddenKeys': ['loaded'],
          'severityFilter': ['critical'],
          'cardWidth': 420,
        }),
      );
      await tester.pump();

      final state = controller.overlayUiState;
      expect(state.hiddenKeys, ['loaded', 'local']);
      // The filter was changed locally, so the stored one is skipped.
      expect(state.severityFilter, {
        IssueSeverity.critical,
        IssueSeverity.warning,
      });
      // Untouched fields come from the store.
      expect(state.cardWidth, 420);
    });

    testWidgets('no store: ready from construction', (tester) async {
      final controller = SleuthController();
      addTearDown(controller.dispose);
      expect(controller.uiStateReady.value, isTrue);
    });
  });

  group('state store writes', () {
    Future<(SleuthController, _ControlledStore)> loaded(
      WidgetTester tester,
    ) async {
      final store = _ControlledStore();
      final controller = _controller(store);
      store.readCompleter.complete(null);
      await tester.pump();
      expect(controller.uiStateReady.value, isTrue);
      return (controller, store);
    }

    testWidgets('a change writes once after the 500 ms debounce', (
      tester,
    ) async {
      final (controller, store) = await loaded(tester);
      addTearDown(controller.dispose);

      controller.overlayUiState.hide('k');
      await tester.pump(const Duration(milliseconds: 400));
      expect(store.writes, isEmpty);
      await tester.pump(const Duration(milliseconds: 200));
      expect(store.writes, hasLength(1));
      final saved = jsonDecode(store.writes.single) as Map<String, Object?>;
      expect(saved['hiddenKeys'], ['k']);
    });

    testWidgets('two rapid changes write once', (tester) async {
      final (controller, store) = await loaded(tester);
      addTearDown(controller.dispose);

      controller.overlayUiState.hide('a');
      await tester.pump(const Duration(milliseconds: 100));
      controller.overlayUiState.toggleSeverity(IssueSeverity.ok);
      await tester.pump(const Duration(milliseconds: 600));
      expect(store.writes, hasLength(1));
      final saved = OverlayUiState.fromJson(
        jsonDecode(store.writes.single) as Map<String, Object?>,
      );
      expect(saved.hiddenKeys, {'a'});
      expect(saved.severityFilter.contains(IssueSeverity.ok), isFalse);
    });

    testWidgets('opening the dashboard does not write', (tester) async {
      final (controller, store) = await loaded(tester);
      addTearDown(controller.dispose);

      controller.overlayUiState.dashboardOpen = true;
      await tester.pump(const Duration(seconds: 1));
      expect(store.writes, isEmpty);
    });

    testWidgets('a failing write does not throw', (tester) async {
      final (controller, store) = await loaded(tester);
      addTearDown(controller.dispose);
      store.failWrites = true;

      controller.overlayUiState.hide('a');
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);

      // The next change retries.
      store.failWrites = false;
      controller.overlayUiState.hide('b');
      await tester.pump(const Duration(milliseconds: 600));
      expect(store.writes, hasLength(1));
    });

    testWidgets('dispose flushes a pending change with one write', (
      tester,
    ) async {
      final (controller, store) = await loaded(tester);
      controller.overlayUiState.hide('a');
      controller.dispose();
      await tester.pump(const Duration(seconds: 1));
      expect(store.writes, hasLength(1));
      final saved = jsonDecode(store.writes.single) as Map<String, Object?>;
      expect(saved['hiddenKeys'], ['a']);
    });

    testWidgets('dispose with nothing pending does not write', (tester) async {
      final (controller, store) = await loaded(tester);
      controller.overlayUiState.hide('a');
      await tester.pump(const Duration(milliseconds: 600));
      expect(store.writes, hasLength(1));
      controller.dispose();
      await tester.pump(const Duration(seconds: 1));
      expect(store.writes, hasLength(1));
    });

    testWidgets('one write in flight; changes during it write once more '
        'with the latest state', (tester) async {
      final store = _SlowWriteStore();
      final controller = _controller(store);
      addTearDown(controller.dispose);
      await tester.pump();
      expect(controller.uiStateReady.value, isTrue);

      controller.overlayUiState.hide('a');
      await tester.pump(const Duration(milliseconds: 600));
      expect(store.started, hasLength(1));

      // Two changes while the first write is still running.
      controller.overlayUiState.hide('b');
      await tester.pump(const Duration(milliseconds: 600));
      controller.overlayUiState.hide('c');
      await tester.pump(const Duration(milliseconds: 600));
      expect(store.started, hasLength(1));

      store.completeNext();
      await tester.pump();
      expect(store.started, hasLength(2));
      store.completeNext();
      await tester.pump(const Duration(seconds: 1));

      expect(store.started, hasLength(2));
      expect(store.maxInFlight, 1);
      List<Object?> keys(String json) =>
          (jsonDecode(json) as Map<String, Object?>)['hiddenKeys']!
              as List<Object?>;
      expect(keys(store.started[0]), ['a']);
      expect(keys(store.started[1]), ['a', 'b', 'c']);
    });

    testWidgets('dispose during an in-flight write queues the flush after '
        'it', (tester) async {
      final store = _SlowWriteStore();
      final controller = _controller(store);
      await tester.pump();

      controller.overlayUiState.hide('a');
      await tester.pump(const Duration(milliseconds: 600));
      controller.overlayUiState.hide('b');
      controller.dispose();
      await tester.pump();
      expect(store.started, hasLength(1));

      store.completeNext();
      await tester.pump();
      expect(store.started, hasLength(2));
      expect(store.maxInFlight, 1);
      store.completeNext();
      await tester.pump();
    });
  });

  group('runtime hide stays in the overlay', () {
    testWidgets('a hidden issue still reaches latestIssues, ext.sleuth.issues '
        'and the snapshot', (tester) async {
      final controller = SleuthController()..initializeDetectorsForTest();
      addTearDown(controller.dispose);
      controller.overlayUiState
        ..hide('non_lazy_list')
        ..toggleSeverity(IssueSeverity.warning)
        ..toggleSeverity(IssueSeverity.ok);

      await tester.pumpWidget(_listTree());
      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      bool hasIssue(Iterable<String?> ids) => ids.contains('non_lazy_list');
      expect(hasIssue(controller.latestIssues.map((i) => i.stableId)), isTrue);
      expect(
        hasIssue(controller.issuesNotifier.value.map((i) => i.stableId)),
        isTrue,
      );
      expect(controller.suppressedCountForTest, 0);
      expect(
        hasIssue(
          controller.exportSnapshot().currentIssues.map((i) => i.stableId),
        ),
        isTrue,
      );

      final response = await extIssuesHandler(controller, const {});
      final data = response['data']! as Map<String, Object?>;
      final ids = [
        for (final i in data['issues']! as List<Object?>)
          (i! as Map<String, Object?>)['stableId'] as String?,
      ];
      expect(hasIssue(ids), isTrue);

      // The overlay itself does not show it.
      expect(
        controller.overlayUiState
            .visibleIssues(controller.latestIssues)
            .any((i) => i.stableId == 'non_lazy_list'),
        isFalse,
      );
    });
  });
}
