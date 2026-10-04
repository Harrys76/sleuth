import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/hidden_issues_page.dart';
import 'package:sleuth/src/ui/issue_card.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';

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
  Future<void> pumpCard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
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

  /// The summary-bar chip for [severity] ("N severity, on" / "..., off, ...").
  Finder chip(String severity) => find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.selected != null &&
        (w.properties.label?.contains(' $severity, ') ?? false),
  );

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
      await tester.tap(find.bySemanticsLabel('Hide this issue'));
      await tester.pump();

      expect(find.text('Title root'), findsNothing);
      expect(find.text('Title child'), findsNothing);
      expect(find.text('Title other'), findsOneWidget);
      expect(find.text('Issue hidden'), findsOneWidget);
      expect(find.text('1 hidden'), findsOneWidget);
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
      expect(find.byIcon(Icons.push_pin), findsNWidgets(2));

      await tester.tap(find.bySemanticsLabel('Hide this issue').first);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Title a'), findsNothing);
      expect(find.byIcon(Icons.push_pin), findsOneWidget);

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
      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(tester.takeException(), isNull);
      await drainToasts(tester);
    });

    testWidgets('hiding the highlighted issue clears the highlight', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('lay', category: IssueCategory.layout),
      ];
      await pumpCard(tester);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(controller.pendingIssueSelection, isNotNull);

      await expand(tester, 'lay');
      await tester.tap(find.bySemanticsLabel('Hide this issue'));
      await tester.pump();
      expect(controller.pendingIssueSelection, isNull);
      expect(controller.selectedHighlightNotifier.value, isNull);
      await drainToasts(tester);
    });

    testWidgets('losing the highlighted issue clears the highlight', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('lay', category: IssueCategory.layout),
      ];
      await pumpCard(tester);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(controller.pendingIssueSelection, isNotNull);

      controller.issuesNotifier.value = [_issue('other')];
      await tester.pump();
      expect(controller.pendingIssueSelection, isNull);
      await drainToasts(tester);
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

      // The ranker reorders everything below the expanded card.
      controller.issuesNotifier.value = [
        for (final id in ['a', 'e', 'd', 'c', 'b']) _issue(id),
      ];
      await tester.pump();
      const ids = ['a', 'b', 'c', 'd', 'e'];
      expect(rowOrder(tester, ids), ['a', 'e', 'd', 'c', 'b']);

      await expand(tester, 'c');
      expect(rowOrder(tester, ids), ['a', 'e', 'd', 'c', 'b']);

      // And on the next issues update.
      controller.issuesNotifier.value = [
        for (final id in ['b', 'c', 'd', 'e', 'a']) _issue(id),
      ];
      await tester.pump();
      expect(rowOrder(tester, ids), ['a', 'e', 'd', 'c', 'b']);
      expect(find.byIcon(Icons.push_pin), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('Undo of a card hidden above the expanded card brings it '
        'back below the frozen zone', (tester) async {
      controller.issuesNotifier.value = [_issue('x'), _issue('a'), _issue('y')];
      await pumpCard(tester);
      await expand(tester, 'a');
      await expand(tester, 'x');

      // Hide x (the first expanded card's action row).
      await tester.tap(find.bySemanticsLabel('Hide this issue').first);
      await tester.pump();
      expect(rowOrder(tester, ['x', 'a', 'y']), ['a', 'y']);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(rowOrder(tester, ['x', 'a', 'y']), ['a', 'x', 'y']);
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      expect(tester.takeException(), isNull);
      await drainToasts(tester);
    });
  });

  group('Showing X of Y', () {
    testWidgets('counts cards, not ids: one of two widgets hidden', (
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
      expect(find.text('Showing 1 of 2'), findsOneWidget);
    });

    testWidgets('a stale hidden key does not narrow', (tester) async {
      controller.issuesNotifier.value = [_issue('a'), _issue('b')];
      controller.overlayUiState.hide('stale');
      await pumpCard(tester);
      expect(find.textContaining('Showing'), findsNothing);
      expect(find.text('2 confirmed'), findsOneWidget);
    });
  });

  group('Summary bar', () {
    testWidgets('takes 36 px from the list and two collapsed rows fit at '
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

      final chipTop = tester.getTopLeft(chip('warning')).dy;
      final list = tester.getRect(find.byType(ListView));
      expect(list.top - chipTop, 36);
      // The chip's hit box is still 48 tall.
      expect(tester.getSize(chip('warning')).height, 48);

      final rows = [
        for (final e in find.byType(IssueCard).evaluate())
          (e.renderObject! as RenderBox).localToGlobal(Offset.zero) &
              (e.renderObject! as RenderBox).size,
      ];
      expect(
        rows.where((r) => r.top < list.bottom && r.bottom > list.top).length,
        greaterThanOrEqualTo(2),
      );
      // Tests run in debug mode, which adds the debug-mode warning banner;
      // without it (profile builds) both rows fit entirely.
      final debugBanner = tester.getSize(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_WarningBanners',
        ),
      );
      expect(
        rows[1].bottom - list.top,
        lessThanOrEqualTo(list.height + debugBanner.height),
      );
    });

    testWidgets('a tap just below the bar beside the chips reaches the list', (
      tester,
    ) async {
      controller.issuesNotifier.value = [_issue('a')];
      await pumpCard(tester);
      final list = tester.getRect(find.byType(ListView));
      final title = tester.getRect(find.text('Title a'));
      // Inside the chips' 48 px band, right of the chips.
      await tester.tapAt(Offset(title.right - 2, list.top + 6));
      await tester.pump();
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
    });
  });

  group('Footer and Hidden list', () {
    test('footer label omits zero parts', () {
      expect(hiddenFooterLabel(0, 0), isNull);
      expect(hiddenFooterLabel(2, 0), '2 hidden');
      expect(hiddenFooterLabel(0, 3), '3 suppressed');
      expect(hiddenFooterLabel(2, 3), '2 hidden · 3 suppressed');
    });

    testWidgets('footer opens the Hidden list; restore and restore all', (
      tester,
    ) async {
      controller.issuesNotifier.value = [_issue('a'), _issue('b')];
      controller.suppressedCountNotifier.value = 3;
      controller.overlayUiState
        ..hide('a')
        ..hide('b')
        ..hide('gone');
      await pumpCard(tester);

      await tester.tap(find.text('3 hidden · 3 suppressed'));
      await tester.pump();
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

    testWidgets('the Hidden list follows issues and the suppressed count '
        'while open', (tester) async {
      controller.issuesNotifier.value = [_issue('b')];
      controller.overlayUiState.hide('a');
      await pumpCard(tester);
      await tester.tap(find.text('1 hidden'));
      await tester.pump();
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
      await tester.tap(find.bySemanticsLabel('Copy issue details'));
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
      await tester.tap(find.bySemanticsLabel('Copy issue details'));
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

      await tester.tap(chip('critical'));
      await tester.pump();
      expect(find.text('Title root'), findsNothing);
      expect(find.text('Title child'), findsOneWidget);
      // One card shown by default (child collapsed under root), one now:
      // nothing is narrowed, so no "Showing X of Y".
      expect(find.textContaining('Showing'), findsNothing);
    });

    testWidgets('the last enabled severity stays on', (tester) async {
      controller.issuesNotifier.value = [_issue('w')];
      await pumpCard(tester);
      // Only the warning chip renders; turn the others off first.
      controller.overlayUiState
        ..toggleSeverity(IssueSeverity.critical)
        ..toggleSeverity(IssueSeverity.ok);
      await tester.pump();

      await tester.tap(chip('warning'));
      await tester.pump();
      expect(controller.overlayUiState.severityFilter, {IssueSeverity.warning});
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
      expect(find.byIcon(Icons.push_pin), findsOneWidget);

      await tester.tap(chip('critical'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.push_pin), findsNothing);
      final card = tester.widget<IssueCard>(find.byType(IssueCard));
      expect(card.initiallyExpanded, isFalse);

      // Expanding again starts a fresh freeze zone.
      await expand(tester, 'a');
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
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

      final pill = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: chip('warning'),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final border = (pill.decoration as BoxDecoration).border! as Border;
      expect(border.top.color.a, closeTo(0.6, 0.01));

      // A tap in the part of the hit box that overlaps the list toggles.
      final list = tester.getRect(find.byType(ListView));
      await tester.tapAt(
        Offset(tester.getCenter(chip('warning')).dx, list.top + 8),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('1 warning, off, tap to show'),
        findsOneWidget,
      );
      await drainToasts(tester);
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
      expect(find.textContaining('No issues detected'), findsOneWidget);
    });

    testWidgets('nothing matches the severity filter; Reset', (tester) async {
      controller.issuesNotifier.value = [_issue('w')];
      await pumpCard(tester);
      await tester.tap(chip('warning'));
      await tester.pump();
      expect(find.text('No issues match the severity filter'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Reset'));
      await tester.pump();
      expect(find.text('Title w'), findsOneWidget);
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
        _issue('lay', category: IssueCategory.layout),
      ];
      await pumpCard(tester);
      expect(
        find.bySemanticsLabel('Highlight widget on screen'),
        findsOneWidget,
      );
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
      for (final label in [
        'Learn more about this issue',
        'Ask AI about this issue',
      ]) {
        final size = tester.getSize(find.bySemanticsLabel(label));
        expect(size.height, greaterThanOrEqualTo(48), reason: label);
        expect(size.width, greaterThanOrEqualTo(48), reason: label);
      }
      await tester.tap(find.bySemanticsLabel('Learn more about this issue'));
      await tester.tap(find.bySemanticsLabel('Ask AI about this issue'));
      expect((learnMore, askAi), (1, 1));
    });

    testWidgets('new actions have 48 dp hit boxes', (tester) async {
      controller.issuesNotifier.value = [_issue('a')];
      controller.overlayUiState.hide('x');
      await pumpCard(tester);
      await expand(tester, 'a');
      for (final label in [
        'Copy issue details',
        'Hide this issue',
        '1 hidden. Show hidden issues',
      ]) {
        final size = tester.getSize(find.bySemanticsLabel(label));
        expect(size.height, greaterThanOrEqualTo(48), reason: label);
      }
      for (final label in ['Copy issue details', 'Hide this issue']) {
        expect(
          tester.getSize(find.bySemanticsLabel(label)).width,
          greaterThanOrEqualTo(48),
          reason: label,
        );
      }
      expect(tester.getSize(chip('warning')).height, greaterThanOrEqualTo(48));
    });
  });
}
