import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/hidden_issues_page.dart';
import 'package:sleuth/src/ui/issue_card.dart';

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

  /// The summary-bar chip for [severity] ("N severity. Shown. ...").
  Finder chip(String severity) => find.byWidgetPredicate(
    (w) =>
        w is Semantics &&
        w.properties.selected != null &&
        (w.properties.label?.contains(' $severity. ') ?? false),
  );

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
      expect(find.text('Showing 1 of 2'), findsOneWidget);
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

    testWidgets('chips report selection to screen readers', (tester) async {
      controller.issuesNotifier.value = [_issue('w')];
      await pumpCard(tester);
      expect(
        tester.getSemantics(chip('warning')),
        matchesSemantics(
          label: '1 warning. Shown. Tap to toggle',
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
