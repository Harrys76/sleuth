import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/hidden_issues_page.dart';
import 'package:sleuth/src/ui/issue_card.dart';
import 'package:sleuth/src/ui/overlay_filters.dart' show hideKeysOf;
import 'package:sleuth/src/ui/overlay_ui_state.dart';
import 'package:sleuth/src/ui/sleuth_theme.dart';
import 'package:sleuth/src/ui/status_lines.dart';

import '../helpers/contrast_helpers.dart';
import '../helpers/overlay_harness.dart'
    show
        crosshair,
        crosshairOn,
        expandedIssueCards,
        moreMenuRow,
        openFromMoreMenu,
        openMoreMenu,
        tapVisible;

PerformanceIssue _issue(
  String id, {
  IssueSeverity severity = IssueSeverity.warning,
  IssueCategory category = IssueCategory.build,
  List<String>? rootCauseIds,
  List<String>? downstreamIds,
  String? widgetName,
}) => PerformanceIssue(
  severity: severity,
  category: category,
  confidence: IssueConfidence.confirmed,
  title: 'Title $id',
  detail: 'Detail $id',
  fixHint: 'Fix $id',
  stableId: id,
  rootCauseIds: rootCauseIds,
  downstreamIds: downstreamIds,
  widgetName: widgetName,
);

void main() {
  late SleuthController controller;
  late List<MethodCall> platformCalls;
  late bool failClipboard;

  setUp(() {
    controller = SleuthController()..initializeDetectorsForTest();
    platformCalls = [];
    failClipboard = false;
  });

  tearDown(() => controller.dispose());

  /// Card in a tall view so several rows are tappable, with the platform
  /// channel recorded.
  Future<void> pumpCard(WidgetTester tester, {SleuthThemeData? theme}) async {
    // Tall enough that an expanded card's details leave room to build the
    // cards below it.
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        platformCalls.add(call);
        if (failClipboard && call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'denied');
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final card = FloatingIssuesCard(
      controller: controller,
      onClose: () {},
      isDebugMode: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: theme == null ? card : SleuthTheme(data: theme, child: card),
        ),
      ),
    );
    await tester.pump();
  }

  /// Lets any toast run out so no timer is pending at the end of a test.
  Future<void> drainToasts(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> expand(WidgetTester tester, String id) async {
    await tester.tap(find.text('Title $id'));
    await tester.pump();
  }

  /// The status-row chip for [severity] ("N severity, on" / "..., off, ...").
  Finder chip(String severity) => find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.selected != null &&
        (w.properties.label?.contains(' $severity, ') ?? false),
  );

  /// Scrolls the [severity] chip into view and taps it. The test font is
  /// wider than platform fonts, so three chips do not fit a 320 px card.
  Future<void> tapChip(WidgetTester tester, String severity) async {
    await tester.ensureVisible(chip(severity));
    await tester.pump();
    await tester.tap(chip(severity));
    await tester.pump();
  }

  /// Border of the [severity] chip's pill.
  BorderSide pillBorder(WidgetTester tester, String severity) {
    final pill = tester.widget<DecoratedBox>(
      find
          .descendant(of: chip(severity), matching: find.byType(DecoratedBox))
          .first,
    );
    return ((pill.decoration as BoxDecoration).border! as Border).top;
  }

  /// [icon] inside the [severity] chip.
  Finder chipGlyph(String severity, IconData icon) =>
      find.descendant(of: chip(severity), matching: find.byIcon(icon));

  /// Ids of the cards on screen, top to bottom.
  List<String> rowOrder(WidgetTester tester, List<String> ids) {
    final shown = [
      for (final id in ids)
        if (find.text('Title $id').evaluate().isNotEmpty) id,
    ];
    return shown..sort(
      (a, b) => tester
          .getTopLeft(find.text('Title $a'))
          .dy
          .compareTo(tester.getTopLeft(find.text('Title $b')).dy),
    );
  }

  group('Hide with Undo', () {
    testWidgets('hiding a root removes it and its collapsed effects; Undo '
        'brings them back', (tester) async {
      controller.issuesNotifier.value = [
        _issue(
          'root',
          severity: IssueSeverity.critical,
          downstreamIds: ['child'],
        ),
        _issue('child', rootCauseIds: ['root']),
        _issue('other'),
      ];
      await pumpCard(tester);
      expect(find.text('Title child'), findsNothing); // collapsed

      await expand(tester, 'root');
      expect(find.text('Title child'), findsOneWidget); // related effects
      await tapVisible(tester, find.bySemanticsLabel('Hide'));
      await tester.pump();

      expect(find.text('Title root'), findsNothing);
      expect(find.text('Title child'), findsNothing);
      expect(find.text('Title other'), findsOneWidget);
      expect(find.text('Issue hidden'), findsOneWidget);
      expect(controller.overlayUiState.hiddenKeys, hasLength(1));
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(find.text('Title root'), findsOneWidget);
      expect(find.text('Title child'), findsNothing);
      expect(controller.overlayUiState.hiddenKeys, isEmpty);
      await drainToasts(tester);
    });

    testWidgets('hiding an expanded card with others expanded keeps the '
        'freeze zone consistent', (tester) async {
      controller.issuesNotifier.value = [_issue('a'), _issue('b'), _issue('c')];
      await pumpCard(tester);
      await expand(tester, 'a');
      await expand(tester, 'c');
      expect(expandedIssueCards(), findsNWidgets(2));

      await tapVisible(tester, find.bySemanticsLabel('Hide').first);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Title a'), findsNothing);
      expect(expandedIssueCards(), findsOneWidget);

      // Issues update, restore and undo with a card still expanded.
      controller.issuesNotifier.value = [
        _issue('c'),
        _issue('b'),
        _issue('a'),
        _issue('d', severity: IssueSeverity.critical),
      ];
      await tester.pump();
      controller.overlayUiState.restoreAll();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Title a'), findsOneWidget);

      // Collapsing the last card releases the snapshot.
      await expand(tester, 'c');
      expect(expandedIssueCards(), findsNothing);
      expect(tester.takeException(), isNull);
      await drainToasts(tester);
    });

    testWidgets('hiding the highlighted issue clears the highlight', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('lay', category: IssueCategory.layout, widgetName: 'Lay'),
      ];
      await pumpCard(tester);
      await tester.tap(crosshair());
      await tester.pump();
      expect(controller.pendingIssueSelection, isNotNull);

      await expand(tester, 'lay');
      await tapVisible(tester, find.bySemanticsLabel('Hide'));
      await tester.pump();
      expect(controller.pendingIssueSelection, isNull);
      expect(controller.selectedHighlightNotifier.value, isNull);
      await drainToasts(tester);
    });

    testWidgets('a widget that is not on screen unticks the card', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('lay', category: IssueCategory.layout, widgetName: 'Lay'),
      ];
      // A scan already ran and outlined nothing.
      controller.scanTickNotifier.value = 1;
      await pumpCard(tester);
      await tester.tap(crosshair());
      await tester.pump();

      expect(
        find.textContaining('Widget not currently visible'),
        findsOneWidget,
      );
      expect(crosshairOn(tester, crosshair()), isFalse);
      expect(controller.pendingIssueSelection, isNull);
      expect(controller.selectedHighlightNotifier.value, isNull);
      await drainToasts(tester);
    });

    testWidgets('losing the highlighted issue clears the highlight', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('lay', category: IssueCategory.layout, widgetName: 'Lay'),
      ];
      await pumpCard(tester);
      await tester.tap(crosshair());
      await tester.pump();
      expect(controller.pendingIssueSelection, isNotNull);

      controller.issuesNotifier.value = [_issue('other')];
      await tester.pump();
      expect(controller.pendingIssueSelection, isNull);
      await drainToasts(tester);
    });

    testWidgets('a hidden keep-alive card stays hidden when another '
        'pager appears', (tester) async {
      PerformanceIssue keepAlive(String id) => PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.memory,
        confidence: IssueConfidence.possible,
        title: 'Title $id',
        detail: 'Detail',
        fixHint: 'Fix',
        stableId: 'excessive_keep_alive:$id',
        widgetName: 'PageView',
      );
      controller.issuesNotifier.value = [keepAlive('PageView~2')];
      await pumpCard(tester);
      controller.overlayUiState.hide(
        OverlayUiState.hideKeyFor(keepAlive('PageView~2')),
      );
      await tester.pump();

      // A pager earlier in the tree starts keeping pages alive: the
      // hidden card keeps its id.
      controller.issuesNotifier.value = [
        keepAlive('PageView~1'),
        keepAlive('PageView~2'),
      ];
      await tester.pump();
      expect(find.text('Title PageView~1'), findsOneWidget);
      expect(find.text('Title PageView~2'), findsNothing);
    });

    testWidgets('same detector id on two widgets hides independently', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('dup', widgetName: 'A'),
        _issue('dup2', widgetName: 'B'),
      ];
      await pumpCard(tester);
      controller.overlayUiState.hide('dup|A');
      await tester.pump();
      expect(find.text('Title dup'), findsNothing);
      expect(find.text('Title dup2'), findsOneWidget);
    });
  });

  group('Freeze zone', () {
    testWidgets('expanding a card below the frozen zone keeps it where it '
        'was tapped', (tester) async {
      controller.issuesNotifier.value = [
        for (final id in ['a', 'b', 'c', 'd', 'e']) _issue(id),
      ];
      await pumpCard(tester);
      await expand(tester, 'a');

      // The ranker reorders everything below the expanded card. The
      // collapsed order holds, then takes the new order in a quiet
      // period.
      controller.issuesNotifier.value = [
        for (final id in ['a', 'e', 'd', 'c', 'b']) _issue(id),
      ];
      await tester.pump();
      const ids = ['a', 'b', 'c', 'd', 'e'];
      expect(rowOrder(tester, ids), ['a', 'b', 'c', 'd', 'e']);
      await tester.pump(const Duration(seconds: 10));
      expect(rowOrder(tester, ids), ['a', 'e', 'd', 'c', 'b']);

      await expand(tester, 'c');
      expect(rowOrder(tester, ids), ['a', 'e', 'd', 'c', 'b']);

      // And on the next issues update.
      controller.issuesNotifier.value = [
        for (final id in ['b', 'c', 'd', 'e', 'a']) _issue(id),
      ];
      await tester.pump();
      expect(rowOrder(tester, ids), ['a', 'e', 'd', 'c', 'b']);
      expect(expandedIssueCards(), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    }, semanticsEnabled: false);

    testWidgets('Undo of a card hidden above the expanded card brings it '
        'back below the frozen zone', (tester) async {
      controller.issuesNotifier.value = [_issue('x'), _issue('a'), _issue('y')];
      await pumpCard(tester);
      await expand(tester, 'a');
      await expand(tester, 'x');

      // Hide x (the first expanded card's action row).
      await tapVisible(tester, find.bySemanticsLabel('Hide').first);
      await tester.pump();
      expect(rowOrder(tester, ['x', 'a', 'y']), ['a', 'y']);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(rowOrder(tester, ['x', 'a', 'y']), ['a', 'x', 'y']);
      expect(expandedIssueCards(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await drainToasts(tester);
    });
  });

  group('Held order', () {
    const ids = ['a', 'b', 'c', 'd'];

    Future<void> pumpABCD(WidgetTester tester) async {
      controller.issuesNotifier.value = [for (final id in ids) _issue(id)];
      await pumpCard(tester);
      expect(rowOrder(tester, ids), ids);
    }

    testWidgets('a rank change waits for 10 s without a touch', (tester) async {
      await pumpABCD(tester);
      controller.issuesNotifier.value = [
        for (final id in ['d', 'c', 'b', 'a']) _issue(id),
      ];
      await tester.pump();
      expect(rowOrder(tester, ids), ids);

      await tester.pump(const Duration(seconds: 9));
      expect(rowOrder(tester, ids), ids);
      await tester.pump(const Duration(seconds: 1));
      expect(rowOrder(tester, ids), ['d', 'c', 'b', 'a']);
    }, semanticsEnabled: false);

    testWidgets('a touch on the list restarts the quiet period', (
      tester,
    ) async {
      await pumpABCD(tester);
      controller.issuesNotifier.value = [
        for (final id in ['d', 'c', 'b', 'a']) _issue(id),
      ];
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));

      // A finger rests on the list past the quiet period.
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('Title b')),
      );
      await tester.pump(const Duration(seconds: 12));
      expect(rowOrder(tester, ids), ids);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(rowOrder(tester, ids), ids);

      await tester.pump(const Duration(seconds: 10));
      expect(rowOrder(tester, ids), ['d', 'c', 'b', 'a']);
    }, semanticsEnabled: false);

    testWidgets('a severity promotion moves at once', (tester) async {
      await pumpABCD(tester);
      controller.issuesNotifier.value = [
        _issue('c', severity: IssueSeverity.critical),
        _issue('a'),
        _issue('b'),
        _issue('d'),
      ];
      await tester.pump();
      expect(rowOrder(tester, ids), ['c', 'a', 'b', 'd']);
    }, semanticsEnabled: false);

    testWidgets('a new issue enters at the top with a New tag', (tester) async {
      await pumpABCD(tester);
      controller.issuesNotifier.value = [
        for (final id in ['a', 'b', 'c', 'n', 'd']) _issue(id),
      ];
      await tester.pump();
      const all = ['a', 'b', 'c', 'd', 'n'];
      expect(rowOrder(tester, all), ['n', 'a', 'b', 'c', 'd']);
      IssueCard card(String id) => tester.widget<IssueCard>(
        find.ancestor(
          of: find.text('Title $id'),
          matching: find.byType(IssueCard),
        ),
      );
      expect(card('n').isNew, isTrue);
      expect(card('a').isNew, isFalse);
      expect(find.text('New'), findsOneWidget);

      await tester.pump(const Duration(seconds: 2));
      expect(card('n').isNew, isFalse);
      expect(find.text('New'), findsNothing);
      await tester.pump(const Duration(seconds: 8));
      expect(rowOrder(tester, all), ['a', 'b', 'c', 'n', 'd']);
    }, semanticsEnabled: false);

    testWidgets('a new issue enters below the frozen zone', (tester) async {
      await pumpABCD(tester);
      await expand(tester, 'b');
      controller.issuesNotifier.value = [
        for (final id in ['n', 'a', 'b', 'c', 'd']) _issue(id),
      ];
      await tester.pump();
      expect(rowOrder(tester, ['a', 'b', 'c', 'd', 'n']), [
        'a',
        'b',
        'n',
        'c',
        'd',
      ]);
      await tester.pump(const Duration(seconds: 10));
    }, semanticsEnabled: false);

    testWidgets('a removed issue leaves its slot to the next card', (
      tester,
    ) async {
      await pumpABCD(tester);
      controller.issuesNotifier.value = [
        for (final id in ['d', 'c', 'a']) _issue(id),
      ];
      await tester.pump();
      expect(rowOrder(tester, ids), ['a', 'c', 'd']);
      await tester.pump(const Duration(seconds: 10));
      expect(rowOrder(tester, ids), ['d', 'c', 'a']);
    }, semanticsEnabled: false);

    testWidgets('a severity filter change adopts the ranker order', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        for (final id in ids) _issue(id),
        _issue('ok', severity: IssueSeverity.ok),
      ];
      await pumpCard(tester);
      controller.issuesNotifier.value = [
        for (final id in ['d', 'c', 'b', 'a']) _issue(id),
        _issue('ok', severity: IssueSeverity.ok),
      ];
      await tester.pump();
      expect(rowOrder(tester, ids), ids);

      controller.overlayUiState.toggleSeverity(IssueSeverity.ok);
      await tester.pump();
      expect(rowOrder(tester, ids), ['d', 'c', 'b', 'a']);
    });

    testWidgets('collapsing the last expanded card keeps the order on '
        'screen', (tester) async {
      await pumpABCD(tester);
      await expand(tester, 'b');
      controller.issuesNotifier.value = [
        for (final id in ['n', 'a', 'b', 'c', 'd']) _issue(id),
      ];
      await tester.pump();
      const all = ['a', 'b', 'c', 'd', 'n'];
      expect(rowOrder(tester, all), ['a', 'b', 'n', 'c', 'd']);

      // Collapse: nothing moves under the finger.
      await expand(tester, 'b');
      expect(rowOrder(tester, all), ['a', 'b', 'n', 'c', 'd']);
      await tester.pump(const Duration(seconds: 5));
      expect(rowOrder(tester, all), ['a', 'b', 'n', 'c', 'd']);
      await tester.pump(const Duration(seconds: 10));
      expect(rowOrder(tester, all), ['n', 'a', 'b', 'c', 'd']);
    }, semanticsEnabled: false);

    testWidgets('under a screen reader the order changes only on reset '
        'points', (tester) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(accessibleNavigation: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await pumpABCD(tester);
      controller.issuesNotifier.value = [
        _issue('d', severity: IssueSeverity.critical),
        _issue('c'),
        _issue('b'),
        _issue('a'),
      ];
      await tester.pump();
      // Neither the promotion nor the quiet period moves a card.
      expect(rowOrder(tester, ids), ids);
      await tester.pump(const Duration(seconds: 30));
      expect(rowOrder(tester, ids), ids);

      controller.overlayUiState.hide('b');
      await tester.pump();
      expect(rowOrder(tester, ids), ['d', 'c', 'a']);
    });

    testWidgets('with semantics on, the quiet period applies nothing', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpABCD(tester);
      controller.issuesNotifier.value = [
        for (final id in ['d', 'c', 'b', 'a']) _issue(id),
      ];
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));
      expect(rowOrder(tester, ids), ids);
      handle.dispose();
    });

    testWidgets('a scroll restarts the quiet period and the change waits '
        'for the top', (tester) async {
      final many = [for (var i = 0; i < 30; i++) 'r$i'];
      controller.issuesNotifier.value = [for (final id in many) _issue(id)];
      await pumpCard(tester);
      controller.issuesNotifier.value = [
        for (final id in many.reversed) _issue(id),
      ];
      await tester.pump();
      final position = tester
          .state<ScrollableState>(
            find
                .descendant(
                  of: find.byType(ListView),
                  matching: find.byType(Scrollable),
                )
                .first,
          )
          .position;

      await tester.pump(const Duration(seconds: 8));
      // A scroll with no pointer (a screen reader's scroll action).
      position.jumpTo(120);
      await tester.pump();
      await tester.pump(const Duration(seconds: 9));
      expect(find.text('Title r29'), findsNothing);
      // Still scrolled away at the next quiet period: held.
      await tester.pump(const Duration(seconds: 2));
      expect(rowOrder(tester, ['r4', 'r5']), ['r4', 'r5']);
      position.jumpTo(0);
      await tester.pump();
      expect(rowOrder(tester, ['r0', 'r1']), ['r0', 'r1']);
      await tester.pump(const Duration(seconds: 10));
      expect(rowOrder(tester, ['r29', 'r0']), ['r29']);
    }, semanticsEnabled: false);

    testWidgets('a trackpad gesture restarts the quiet period', (tester) async {
      await pumpABCD(tester);
      controller.issuesNotifier.value = [
        for (final id in ['d', 'c', 'b', 'a']) _issue(id),
      ];
      await tester.pump();
      await tester.pump(const Duration(seconds: 8));

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.trackpad,
      );
      await gesture.panZoomStart(tester.getCenter(find.text('Title b')));
      await gesture.panZoomUpdate(
        tester.getCenter(find.text('Title b')),
        pan: const Offset(0, 4),
      );
      await gesture.panZoomEnd();
      await tester.pump(const Duration(seconds: 5));
      expect(rowOrder(tester, ids), ids);
      await tester.pump(const Duration(seconds: 6));
      expect(rowOrder(tester, ids), ['d', 'c', 'b', 'a']);
    }, semanticsEnabled: false);

    testWidgets('each new card keeps its New tag for its own 2 s, without '
        'moving the layout', (tester) async {
      await pumpABCD(tester);
      final before = tester.getTopLeft(find.text('Title a'));
      controller.issuesNotifier.value = [
        for (final id in ['a', 'b', 'c', 'd', 'n']) _issue(id),
      ];
      await tester.pump();
      IssueCard card(String id) => tester.widget<IssueCard>(
        find.ancestor(
          of: find.text('Title $id'),
          matching: find.byType(IssueCard),
        ),
      );
      expect(card('n').isNew, isTrue);
      final titleN = tester.getTopLeft(find.text('Title n'));
      expect(titleN.dx, before.dx);

      await tester.pump(const Duration(milliseconds: 1500));
      controller.issuesNotifier.value = [
        for (final id in ['a', 'b', 'c', 'd', 'n', 'm']) _issue(id),
      ];
      await tester.pump();
      expect(card('m').isNew, isTrue);
      await tester.pump(const Duration(milliseconds: 500));
      expect(card('n').isNew, isFalse);
      expect(card('m').isNew, isTrue);
      expect(tester.getTopLeft(find.text('Title n')).dx, before.dx);
      await tester.pump(const Duration(milliseconds: 1500));
      expect(card('m').isNew, isFalse);
      await tester.pump(const Duration(seconds: 10));
    }, semanticsEnabled: false);

    testWidgets('a new card that leaves drops its New tag', (tester) async {
      await pumpABCD(tester);
      controller.issuesNotifier.value = [
        for (final id in ['a', 'b', 'c', 'd', 'n']) _issue(id),
      ];
      await tester.pump();
      controller.issuesNotifier.value = [for (final id in ids) _issue(id)];
      await tester.pump();
      // Back within its 2 s: a new arrival, so a fresh tag.
      controller.issuesNotifier.value = [
        for (final id in ['a', 'b', 'c', 'd', 'n']) _issue(id),
      ];
      await tester.pump(const Duration(milliseconds: 1900));
      final card = tester.widget<IssueCard>(
        find.ancestor(
          of: find.text('Title n'),
          matching: find.byType(IssueCard),
        ),
      );
      expect(card.isNew, isTrue);
      await tester.pump(const Duration(seconds: 12));
    }, semanticsEnabled: false);

    testWidgets('a hide adopts the ranker order', (tester) async {
      await pumpABCD(tester);
      controller.issuesNotifier.value = [
        for (final id in ['d', 'c', 'b', 'a']) _issue(id),
      ];
      await tester.pump();
      controller.overlayUiState.hide('b');
      await tester.pump();
      expect(rowOrder(tester, ids), ['d', 'c', 'a']);
    });
  });

  group('Hide keys and severity', () {
    testWidgets('a card hidden at warning shows again once it turns '
        'critical', (tester) async {
      controller.issuesNotifier.value = [_issue('jank', widgetName: 'Feed')];
      await pumpCard(tester);
      await expand(tester, 'jank');
      await tapVisible(tester, find.bySemanticsLabel('Hide'));
      await tester.pump();
      expect(find.text('Title jank'), findsNothing);

      controller.issuesNotifier.value = [
        _issue('jank', widgetName: 'Feed', severity: IssueSeverity.critical),
      ];
      await tester.pump();
      expect(find.text('Title jank'), findsOneWidget);
      await drainToasts(tester);
    });

    testWidgets('a card hidden while critical stays hidden at warning', (
      tester,
    ) async {
      final critical = _issue(
        'jank',
        widgetName: 'Feed',
        severity: IssueSeverity.critical,
      );
      final warning = _issue('jank', widgetName: 'Feed');
      controller.issuesNotifier.value = [critical];
      await pumpCard(tester);
      await expand(tester, 'jank');
      await tapVisible(tester, find.bySemanticsLabel('Hide'));
      await tester.pump();
      expect(find.text('Title jank'), findsNothing);

      controller.issuesNotifier.value = [warning];
      await tester.pump();
      expect(find.text('Title jank'), findsNothing);
      expect(controller.overlayUiState.isHidden(warning), isTrue);
      expect(controller.overlayUiState.isHidden(critical), isTrue);
      await drainToasts(tester);
    });

    // A store written before 1.0 hid these cards by stable id alone.
    test('an any-widget key hides the stable id\'s cards by severity', () {
      final wrap = _issue('wrap_layout_bottleneck', widgetName: 'Wrap');
      final wrapCritical = _issue(
        'wrap_layout_bottleneck',
        widgetName: 'Wrap',
        severity: IssueSeverity.critical,
      );
      expect(isHiddenBy(wrap, {'wrap_layout_bottleneck|*'}), isTrue);
      expect(isHiddenBy(wrapCritical, {'wrap_layout_bottleneck|*'}), isFalse);
      expect(
        isHiddenBy(wrapCritical, {'wrap_layout_bottleneck|*!critical'}),
        isTrue,
      );
      expect(
        isHiddenBy(_issue('other'), {'wrap_layout_bottleneck|*'}),
        isFalse,
      );
    });

    test('removing hideKeysOf shows a card an any-widget key hides', () {
      final wrap = _issue('wrap_layout_bottleneck', widgetName: 'Wrap');
      final keys = {'wrap_layout_bottleneck|*', 'other'}
        ..removeAll(hideKeysOf(wrap));
      expect(isHiddenBy(wrap, keys), isFalse);
      expect(keys, {'other'});
    });

    testWidgets('the Hidden list names the card an any-widget key hides', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HiddenIssuesPage(
            hiddenKeys: const ['wrap_layout_bottleneck|*'],
            issues: [_issue('wrap_layout_bottleneck', widgetName: 'Wrap')],
            configSuppressions: const {},
            suppressedCount: 0,
            onRestore: (_) {},
            onRestoreAll: () {},
            onClose: () {},
          ),
        ),
      );
      expect(find.text('Title wrap_layout_bottleneck'), findsOneWidget);
      expect(find.text('Not detected right now'), findsNothing);
    });

    testWidgets('an any-widget key names a card it still hides', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HiddenIssuesPage(
            hiddenKeys: const ['wrap_layout_bottleneck|*'],
            issues: [
              _issue(
                'wrap_layout_bottleneck',
                widgetName: 'Wrap',
                severity: IssueSeverity.critical,
              ).copyWith(title: 'Critical wrap'),
              _issue(
                'wrap_layout_bottleneck',
                widgetName: 'Wrap',
              ).copyWith(title: 'Warning wrap'),
            ],
            configSuppressions: const {},
            suppressedCount: 0,
            onRestore: (_) {},
            onRestoreAll: () {},
            onClose: () {},
          ),
        ),
      );
      expect(find.text('Warning wrap'), findsOneWidget);
      expect(find.text('Shown again: now critical'), findsNothing);
    });

    testWidgets('the Hidden list marks a card hidden at warning that is now '
        'critical', (tester) async {
      final hiddenAtWarning = hideKeyFor(_issue('jank', widgetName: 'Feed'));
      await tester.pumpWidget(
        MaterialApp(
          home: HiddenIssuesPage(
            hiddenKeys: [hiddenAtWarning],
            issues: [
              _issue(
                'jank',
                widgetName: 'Feed',
                severity: IssueSeverity.critical,
              ),
            ],
            configSuppressions: const {},
            suppressedCount: 0,
            onRestore: (_) {},
            onRestoreAll: () {},
            onClose: () {},
          ),
        ),
      );
      expect(find.text('Title jank'), findsOneWidget);
      expect(find.text('Shown again: now critical'), findsOneWidget);
      expect(find.text(hiddenAtWarning), findsNothing);
    });
  });

  group('An expanded card outlives its issue', () {
    testWidgets('it stays, marked, with no crosshair; collapsing it lets it '
        'go and the empty state show', (tester) async {
      controller.issuesNotifier.value = [
        _issue('lay', category: IssueCategory.layout, widgetName: 'Lay'),
      ];
      await pumpCard(tester);
      await expand(tester, 'lay');
      expect(crosshair(), findsOneWidget);

      controller.issuesNotifier.value = const [];
      await tester.pump();
      expect(find.text('Title lay'), findsOneWidget);
      expect(find.text('Not detected right now'), findsOneWidget);
      expect(crosshair(), findsNothing);
      expect(find.byType(SleuthStatusBox), findsNothing);

      await expand(tester, 'lay');
      expect(find.text('Title lay'), findsNothing);
      expect(find.byType(SleuthStatusBox), findsOneWidget);
    });

    testWidgets('it turns live again when the issue comes back', (
      tester,
    ) async {
      controller.issuesNotifier.value = [_issue('a'), _issue('b')];
      await pumpCard(tester);
      await expand(tester, 'a');
      controller.issuesNotifier.value = [_issue('b')];
      await tester.pump();
      expect(find.text('Not detected right now'), findsOneWidget);

      controller.issuesNotifier.value = [_issue('a'), _issue('b')];
      await tester.pump();
      expect(find.text('Not detected right now'), findsNothing);
      expect(expandedIssueCards(), findsOneWidget);
      expect(find.text('Title a'), findsOneWidget);
    });
  });

  group('Showing X of Y', () {
    testWidgets('counts cards, not ids, under a severity filter', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('dup', widgetName: 'A'),
        _issue('dup', widgetName: 'B'),
        _issue('crit', severity: IssueSeverity.critical),
      ];
      await pumpCard(tester);
      await tapChip(tester, 'critical');
      expect(find.text('Showing 2 of 3'), findsOneWidget);
      // A screen reader hears the new count.
      expect(
        find.ancestor(
          of: find.text('Showing 2 of 3'),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && w.properties.liveRegion == true,
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Show all'));
      await tester.pump();
      expect(find.textContaining('Showing'), findsNothing);
      expect(find.text('Title crit'), findsOneWidget);
      await drainToasts(tester);
    });

    testWidgets('a scan that only flips the row keeps the list mounted '
        'and scrolled', (tester) async {
      final warnings = [for (var i = 0; i < 20; i++) _issue('w$i')];
      controller.issuesNotifier.value = [
        ...warnings,
        _issue('crit', severity: IssueSeverity.critical),
      ];
      await pumpCard(tester);
      await tapChip(tester, 'critical');
      expect(find.text('Showing 20 of 21'), findsOneWidget);

      final scrollable = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      final state = tester.state<ScrollableState>(scrollable);
      state.position.jumpTo(60);
      await tester.pump();

      // The critical issue goes away: the same cards show, the row goes.
      controller.issuesNotifier.value = [...warnings];
      await tester.pump();
      expect(find.textContaining('Showing'), findsNothing);
      expect(tester.state<ScrollableState>(scrollable), same(state));
      expect(state.position.pixels, 60);
      await drainToasts(tester);
    });

    testWidgets('hidden cards do not narrow; the More menu counts them', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('dup', widgetName: 'A'),
        _issue('dup', widgetName: 'B'),
      ];
      controller.overlayUiState
        ..hide('dup|A')
        ..hide('stale');
      await pumpCard(tester);
      expect(find.textContaining('Showing'), findsNothing);
      expect(find.text('1 warning'), findsOneWidget);
    });
  });

  group('Status row', () {
    testWidgets('sits above the list at 48 px and two collapsed rows fit at '
        'the minimum card height', (tester) async {
      tester.view.physicalSize = const Size(800, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      controller.issuesNotifier.value = [
        for (final id in ['a', 'b', 'c', 'd', 'e']) _issue(id),
      ];
      // Wide enough for the category and confidence badges to sit beside
      // the title (the test font is wider than platform fonts), so the
      // rows are single-line collapsed rows.
      controller.overlayUiState.setCardGeometry(
        offset: null,
        width: 480,
        height: null,
        windowState: CardWindowState.normal,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(
              controller: controller,
              onClose: () {},
              isDebugMode: false,
            ),
          ),
        ),
      );
      await tester.pump();

      final card = tester.getRect(
        find.byWidgetPredicate((w) => w is Material && w.elevation == 8),
      );
      expect(card.height, 300); // 400 * 0.55 is below the minimum

      final chipRect = tester.getRect(chip('warning'));
      final list = tester.getRect(find.byType(ListView));
      expect(chipRect.height, 48);
      // The list starts below the row and its 1 px divider; nothing of
      // the row lies over it.
      expect(list.top, greaterThanOrEqualTo(chipRect.bottom + 1));

      final rows = [
        for (final e in find.byType(IssueCard).evaluate())
          (e.renderObject! as RenderBox).localToGlobal(Offset.zero) &
              (e.renderObject! as RenderBox).size,
      ];
      expect(
        rows.where((r) => r.top < list.bottom && r.bottom > list.top).length,
        greaterThanOrEqualTo(2),
      );
      // A debug run adds the debug banner; without it (profile builds)
      // both rows fit entirely.
      final banner = find.byType(SleuthDebugBanner);
      final bannerHeight = banner.evaluate().isEmpty
          ? 0.0
          : tester.getSize(banner).height;
      expect(
        rows[1].bottom - list.top,
        lessThanOrEqualTo(list.height + bannerHeight),
      );
    });

    testWidgets('the frame rate sits at the end of the row', (tester) async {
      controller.issuesNotifier.value = [_issue('a')];
      await pumpCard(tester);
      final fps = tester.getRect(find.textContaining('fps'));
      final row = tester.getRect(chip('warning'));
      expect(fps.center.dy, closeTo(row.center.dy, 1));
      expect(fps.left, greaterThan(row.right));
    });
  });

  group('Hidden issues row and Hidden list', () {
    testWidgets('the More menu has no Hidden issues row at 0', (tester) async {
      controller.issuesNotifier.value = [_issue('a')];
      await pumpCard(tester);
      await openMoreMenu(tester);
      expect(moreMenuRow('Hidden issues'), findsNothing);
    });

    testWidgets('the row counts hidden and suppressed issues and opens the '
        'Hidden list; restore and restore all', (tester) async {
      controller.issuesNotifier.value = [_issue('a'), _issue('b')];
      controller.suppressedCountNotifier.value = 3;
      controller.overlayUiState
        ..hide('a')
        ..hide('b')
        ..hide('gone');
      await pumpCard(tester);

      await openMoreMenu(tester);
      expect(find.bySemanticsLabel('Hidden issues, 6'), findsOneWidget);
      await tester.tap(moreMenuRow('Hidden issues'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(HiddenIssuesPage), findsOneWidget);
      expect(find.text('Title a'), findsOneWidget);
      expect(find.text('Not detected right now'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Restore Title a'));
      await tester.pump();
      expect(controller.overlayUiState.hiddenKeys, {'b', 'gone'});

      await tester.tap(find.bySemanticsLabel('Restore all hidden issues'));
      await tester.pump();
      expect(controller.overlayUiState.hiddenKeys, isEmpty);
      expect(find.text('Nothing hidden.'), findsOneWidget);
    });

    testWidgets('Restore all offers Undo, which hides the same keys again '
        'in their order', (tester) async {
      controller.issuesNotifier.value = [_issue('a'), _issue('b'), _issue('c')];
      controller.overlayUiState
        ..hide('c')
        ..hide('a');
      await pumpCard(tester);
      await openFromMoreMenu(tester, 'Hidden issues');

      await tester.tap(find.bySemanticsLabel('Restore all hidden issues'));
      await tester.pump();
      expect(controller.overlayUiState.hiddenKeys, isEmpty);
      expect(find.text('2 issues restored'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(controller.overlayUiState.hiddenKeys.toList(), ['c', 'a']);
      await drainToasts(tester);
    });

    testWidgets('the Hidden list follows issues and the suppressed count '
        'while open', (tester) async {
      controller.issuesNotifier.value = [_issue('b')];
      controller.overlayUiState.hide('a');
      await pumpCard(tester);
      await openFromMoreMenu(tester, 'Hidden issues');
      expect(find.text('Not detected right now'), findsOneWidget);

      controller.issuesNotifier.value = [_issue('a'), _issue('b')];
      controller.suppressedCountNotifier.value = 4;
      await tester.pump();
      expect(find.text('Title a'), findsOneWidget);
      expect(find.text('Not detected right now'), findsNothing);
      expect(find.textContaining('4 removed before ranking'), findsOneWidget);
    });

    testWidgets('config suppressions are listed without a restore action', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HiddenIssuesPage(
            hiddenKeys: const [],
            issues: const [],
            configSuppressions: const {'rebuild_debug_*'},
            suppressedCount: 2,
            onRestore: (_) {},
            onRestoreAll: () {},
            onClose: () {},
          ),
        ),
      );
      expect(find.text('rebuild_debug_*'), findsOneWidget);
      expect(find.text('set in SleuthConfig'), findsOneWidget);
      expect(find.textContaining('Restore'), findsNothing);
    });
  });

  group('Copy details', () {
    testWidgets('Copy puts the details on the clipboard and confirms', (
      tester,
    ) async {
      final issue = _issue('a');
      controller.issuesNotifier.value = [issue];
      await pumpCard(tester);
      await expand(tester, 'a');
      await tapVisible(tester, find.bySemanticsLabel('Copy details'));
      await tester.pump();

      final setData = platformCalls.where(
        (c) => c.method == 'Clipboard.setData',
      );
      expect(setData, hasLength(1));
      expect(
        (setData.single.arguments as Map)['text'],
        issue.toClipboardText(),
      );
      expect(
        platformCalls.any((c) => c.method == 'HapticFeedback.vibrate'),
        isTrue,
      );
      expect(find.text('Copied'), findsOneWidget);
      await drainToasts(tester);
    });

    testWidgets('a clipboard failure shows "Couldn\'t copy" and does not '
        'throw', (tester) async {
      failClipboard = true;
      controller.issuesNotifier.value = [_issue('a')];
      await pumpCard(tester);
      await expand(tester, 'a');
      await tapVisible(tester, find.bySemanticsLabel('Copy details'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text("Couldn't copy"), findsOneWidget);
      await drainToasts(tester);
    });

    testWidgets('long-press on the title copies', (tester) async {
      controller.issuesNotifier.value = [_issue('a')];
      await pumpCard(tester);
      await tester.longPress(find.text('Title a'));
      await tester.pump();
      expect(
        platformCalls.where((c) => c.method == 'Clipboard.setData'),
        hasLength(1),
      );
      expect(find.text('Copied'), findsOneWidget);
      await drainToasts(tester);
    });
  });

  group('Severity toggles', () {
    testWidgets('turning critical off surfaces its collapsed effects', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('root', severity: IssueSeverity.critical),
        _issue('child', rootCauseIds: ['root']),
      ];
      await pumpCard(tester);
      expect(find.text('Title child'), findsNothing);

      await tapChip(tester, 'critical');
      expect(find.text('Title root'), findsNothing);
      expect(find.text('Title child'), findsOneWidget);
      // One card shown by default (child collapsed under root), one now:
      // nothing is narrowed, so no "Showing X of Y".
      expect(find.textContaining('Showing'), findsNothing);
    });

    testWidgets('turning critical off counts the surfaced effect on the '
        'warning chip', (tester) async {
      controller.issuesNotifier.value = [
        _issue(
          'root',
          severity: IssueSeverity.critical,
          downstreamIds: ['child'],
        ),
        _issue('child', rootCauseIds: ['root']),
      ];
      await pumpCard(tester);
      expect(chip('warning'), findsNothing);

      await tapChip(tester, 'critical');
      expect(find.text('Title child'), findsOneWidget);
      expect(find.bySemanticsLabel('1 warning, on'), findsOneWidget);
      expect(
        find.bySemanticsLabel('1 critical, off, tap to show'),
        findsOneWidget,
      );
    });

    testWidgets('turning off the highlighted card\'s severity clears the '
        'highlight', (tester) async {
      controller.issuesNotifier.value = [
        _issue('lay', category: IssueCategory.layout, widgetName: 'Lay'),
        _issue('crit', severity: IssueSeverity.critical),
      ];
      await pumpCard(tester);
      await tester.tap(crosshair());
      await tester.pump();
      expect(controller.pendingIssueSelection, isNotNull);
      controller.selectedHighlightNotifier.value = const WidgetHighlight(
        rect: Rect.fromLTWH(0, 0, 10, 10),
        widgetName: 'Lay',
        severity: IssueSeverity.warning,
        detectorName: 'LayoutDetector',
      );
      await tester.pump();

      await tapChip(tester, 'warning');
      expect(find.text('Title lay'), findsNothing);
      expect(controller.pendingIssueSelection, isNull);
      expect(controller.selectedHighlightNotifier.value, isNull);

      // Shown again, the card is no longer ticked.
      await tapChip(tester, 'warning');
      expect(crosshairOn(tester, crosshair()), isFalse);
      await drainToasts(tester);
    });

    testWidgets('the last enabled severity stays on', (tester) async {
      controller.issuesNotifier.value = [_issue('w')];
      await pumpCard(tester);
      // Only the warning chip renders; turn the others off first.
      controller.overlayUiState
        ..toggleSeverity(IssueSeverity.critical)
        ..toggleSeverity(IssueSeverity.ok);
      await tester.pump();

      await tapChip(tester, 'warning');
      expect(controller.overlayUiState.severityFilter, {IssueSeverity.warning});
      expect(find.text('Keep at least one severity'), findsOneWidget);
      await drainToasts(tester);
    });

    // OK has no chip without OK cards, so it cannot be the one left on.
    testWidgets('the last chip that shows cards stays on', (tester) async {
      controller.issuesNotifier.value = [
        _issue('w'),
        _issue('c', severity: IssueSeverity.critical),
      ];
      await pumpCard(tester);

      await tapChip(tester, 'critical');
      await drainToasts(tester);
      await tapChip(tester, 'warning');
      expect(
        controller.overlayUiState.severityFilter,
        containsAll([IssueSeverity.warning, IssueSeverity.ok]),
      );
      expect(find.text('Title w'), findsOneWidget);
      expect(find.text('Keep at least one severity'), findsOneWidget);
      await drainToasts(tester);
    });

    testWidgets('toggling with a card expanded clears the expansion without '
        'asserting', (tester) async {
      controller.issuesNotifier.value = [
        _issue('a'),
        _issue('b', severity: IssueSeverity.critical),
      ];
      await pumpCard(tester);
      await expand(tester, 'a');
      expect(expandedIssueCards(), findsOneWidget);

      await tapChip(tester, 'critical');
      expect(tester.takeException(), isNull);
      expect(expandedIssueCards(), findsNothing);
      final card = tester.widget<IssueCard>(find.byType(IssueCard));
      expect(card.initiallyExpanded, isFalse);

      // Expanding again starts a fresh freeze zone.
      await expand(tester, 'a');
      expect(expandedIssueCards(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('chip labels, 48 dp width and selected border', (tester) async {
      controller.issuesNotifier.value = [
        _issue('c', severity: IssueSeverity.critical),
        _issue('w'),
      ];
      await pumpCard(tester);
      expect(find.bySemanticsLabel('1 warning, on'), findsOneWidget);
      expect(tester.getSize(chip('warning')).width, greaterThanOrEqualTo(48));

      const theme = SleuthThemeData();
      final border = pillBorder(tester, 'warning');
      expect(border.color, theme.severityWarning);
      expect(border.width, 1.5);
      expect(chipGlyph('warning', Icons.warning), findsOneWidget);

      await tapChip(tester, 'warning');
      expect(
        find.bySemanticsLabel('1 warning, off, tap to show'),
        findsOneWidget,
      );
      // Off: the outlined icon and a quaternary outline.
      expect(chipGlyph('warning', Icons.warning), findsNothing);
      expect(chipGlyph('warning', Icons.warning_amber), findsOneWidget);
      expect(pillBorder(tester, 'warning').color, theme.textQuaternary);
      await drainToasts(tester);
    });

    for (final (name, theme) in [
      ('dark', const SleuthThemeData()),
      ('light', const SleuthThemeData.light()),
      ('highContrastDark', const SleuthThemeData.highContrastDark()),
      ('highContrastLight', const SleuthThemeData.highContrastLight()),
    ]) {
      testWidgets('$name: a selected chip border keeps 3:1 against the card', (
        tester,
      ) async {
        controller.issuesNotifier.value = [
          _issue('c', severity: IssueSeverity.critical),
          _issue('w'),
          _issue('o', severity: IssueSeverity.ok),
        ];
        await pumpCard(tester, theme: theme);
        for (final (severity, icon) in [
          ('critical', Icons.error),
          ('warning', Icons.warning),
          ('ok', Icons.check_circle),
        ]) {
          expect(chipGlyph(severity, icon), findsOneWidget);
          final border = pillBorder(tester, severity).color;
          for (final host in const [Color(0xFF000000), Color(0xFFFFFFFF)]) {
            final card = composite(theme.cardBackground, host);
            expect(
              wcagContrast(composite(border, card), card),
              greaterThanOrEqualTo(3),
              reason: '$severity over $host',
            );
          }
        }
      });
    }

    testWidgets('light: chips tell critical from warning by a red and an '
        'orange outline and icon', (tester) async {
      controller.issuesNotifier.value = [
        _issue('c', severity: IssueSeverity.critical),
        _issue('w'),
      ];
      const theme = SleuthThemeData.light();
      await pumpCard(tester, theme: theme);
      expect(pillBorder(tester, 'critical').color, const Color(0xFFDC2626));
      expect(pillBorder(tester, 'warning').color, const Color(0xFFD97706));
      expect(
        tester.widget<Icon>(chipGlyph('critical', Icons.error)).color,
        const Color(0xFFDC2626),
      );
      expect(
        tester.widget<Icon>(chipGlyph('warning', Icons.warning)).color,
        const Color(0xFFD97706),
      );
      // The counts keep the darker text shades.
      final critical = tester.widget<Text>(
        find.descendant(of: chip('critical'), matching: find.byType(Text)),
      );
      expect(
        critical.style!.color,
        theme.badgeTextOn(
          theme.severityCritical,
          tinted: theme.severityCriticalText,
        ),
      );
    });

    testWidgets('chips report selection to screen readers', (tester) async {
      controller.issuesNotifier.value = [_issue('w')];
      await pumpCard(tester);
      expect(
        tester.getSemantics(chip('warning')),
        matchesSemantics(
          label: '1 warning, on',
          isButton: true,
          hasSelectedState: true,
          isSelected: true,
          hasTapAction: true,
        ),
      );
    });
  });

  group('Empty states', () {
    testWidgets('no issues detected', (tester) async {
      await pumpCard(tester);
      expect(find.byType(SleuthStatusBox), findsOneWidget);
    });

    testWidgets('nothing matches the severity filter; Reset', (tester) async {
      controller.issuesNotifier.value = [
        _issue('w'),
        _issue('c', severity: IssueSeverity.critical),
      ];
      await pumpCard(tester);
      await tapChip(tester, 'critical');
      // The warning card goes; only the critical one, filtered out, is left.
      controller.issuesNotifier.value = [
        _issue('c', severity: IssueSeverity.critical),
      ];
      await tester.pump();
      expect(find.text('No issues match the severity filter'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Reset'));
      await tester.pump();
      expect(find.text('Title c'), findsOneWidget);
      await drainToasts(tester);
    });

    testWidgets('all issues hidden; Show hidden opens the list', (
      tester,
    ) async {
      controller.issuesNotifier.value = [_issue('a'), _issue('b')];
      controller.overlayUiState
        ..hide('a')
        ..hide('b');
      await pumpCard(tester);
      expect(find.text('All 2 issues hidden'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Show hidden'));
      await tester.pump();
      expect(find.byType(HiddenIssuesPage), findsOneWidget);
    });
  });

  group('Accessibility', () {
    testWidgets('highlight checkbox and close button are labelled', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('lay', category: IssueCategory.layout, widgetName: 'Lay'),
      ];
      await pumpCard(tester);
      expect(find.bySemanticsLabel('Show Lay on screen'), findsOneWidget);
      expect(find.bySemanticsLabel('Close Sleuth'), findsOneWidget);
    });

    testWidgets('Learn more and Ask AI have 48 dp hit boxes and labels', (
      tester,
    ) async {
      var learnMore = 0;
      var askAi = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IssueCard(
                issue: _issue('a'),
                initiallyExpanded: true,
                onCopy: () {},
                onHide: () {},
                onLearnMore: () => learnMore++,
                onAskAi: () => askAi++,
              ),
            ),
          ),
        ),
      );
      for (final label in ['Learn more', 'Ask AI']) {
        final size = tester.getSize(find.bySemanticsLabel(label));
        expect(size.height, greaterThanOrEqualTo(48), reason: label);
        expect(size.width, greaterThanOrEqualTo(48), reason: label);
      }
      await tapVisible(tester, find.bySemanticsLabel('Learn more'));
      await tapVisible(tester, find.bySemanticsLabel('Ask AI'));
      expect((learnMore, askAi), (1, 1));
    });

    testWidgets('new actions have 48 dp hit boxes', (tester) async {
      controller.issuesNotifier.value = [_issue('a')];
      controller.overlayUiState.hide('x');
      await pumpCard(tester);
      await expand(tester, 'a');
      for (final label in ['Copy details', 'Hide']) {
        final size = tester.getSize(find.bySemanticsLabel(label));
        expect(size.height, greaterThanOrEqualTo(48), reason: label);
        expect(size.width, greaterThanOrEqualTo(48), reason: label);
      }
      expect(tester.getSize(chip('warning')).height, greaterThanOrEqualTo(48));

      await openMoreMenu(tester);
      expect(
        tester.getSize(find.bySemanticsLabel('Hidden issues, 1')).height,
        greaterThanOrEqualTo(48),
      );
    });
  });
}
