import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/issue_card.dart';

import '../helpers/overlay_harness.dart' show expandedIssueCards, tapVisible;

PerformanceIssue _issue(
  String id, {
  IssueSeverity severity = IssueSeverity.warning,
  List<String>? downstreamIds,
  List<String>? rootCauseIds,
  String fixHint = 'Split the widget.',
}) => PerformanceIssue(
  severity: severity,
  category: IssueCategory.build,
  confidence: IssueConfidence.confirmed,
  title: 'Title $id',
  detail: 'Detail $id',
  fixHint: fixHint,
  stableId: id,
  downstreamIds: downstreamIds,
  rootCauseIds: rootCauseIds,
);

void main() {
  late SleuthController controller;
  final clipboard = <String>[];

  setUp(() {
    controller = SleuthController()..initializeDetectorsForTest();
    clipboard.clear();
  });
  tearDown(() => controller.dispose());

  Future<void> pumpCard(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
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

  bool expanded(WidgetTester tester, String id) => tester
      .widget<IssueCard>(
        find.byWidgetPredicate((w) => w is IssueCard && w.issue.stableId == id),
      )
      .initiallyExpanded;

  /// A root whose critical effect shows as its own card: an effect only
  /// folds under a parent at least as severe.
  void rootWithVisibleEffect() {
    controller.issuesNotifier.value = [
      _issue(
        'effect',
        severity: IssueSeverity.critical,
        rootCauseIds: ['root'],
      ),
      _issue('root', downstreamIds: ['effect']),
    ];
  }

  group('a related row opens its card', () {
    testWidgets('a visible target expands', (tester) async {
      rootWithVisibleEffect();
      await pumpCard(tester);
      await tester.tap(find.text('Title root'));
      await tester.pump();

      await tapVisible(tester, find.bySemanticsLabel('Critical: Title effect'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(expanded(tester, 'effect'), isTrue);
      expect(expandedIssueCards(), findsNWidgets(2));
    });

    testWidgets('a target past the end of the built list scrolls into view', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('root', downstreamIds: ['effect']),
        for (var i = 0; i < 30; i++) _issue('filler$i'),
        _issue(
          'effect',
          severity: IssueSeverity.critical,
          rootCauseIds: ['root'],
        ),
      ];
      await pumpCard(tester);
      expect(find.text('Title effect'), findsNothing);
      await tester.tap(find.text('Title root'));
      await tester.pump();

      await tapVisible(tester, find.bySemanticsLabel('Critical: Title effect'));
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final card = find.byWidgetPredicate(
        (w) => w is IssueCard && w.issue.stableId == 'effect',
      );
      expect(card, findsOneWidget);
      expect(expanded(tester, 'effect'), isTrue);
      // On screen: inside the list's viewport.
      final list = tester.getRect(find.byType(ListView));
      expect(list.overlaps(tester.getRect(card)), isTrue);
    });

    testWidgets('a hidden target offers Show, which unhides and opens it', (
      tester,
    ) async {
      rootWithVisibleEffect();
      controller.overlayUiState.hide(
        hideKeyFor(controller.issuesNotifier.value.first),
      );
      await pumpCard(tester);
      expect(find.text('Title effect'), findsNothing);
      await tester.tap(find.text('Title root'));
      await tester.pump();

      await tapVisible(tester, find.bySemanticsLabel('Critical: Title effect'));
      await tester.pump();
      expect(find.text('"Title effect" is hidden'), findsOneWidget);
      await tester.tap(find.text('Show'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.overlayUiState.hiddenKeys, isEmpty);
      expect(expanded(tester, 'effect'), isTrue);
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('a target filtered out by severity offers Show', (
      tester,
    ) async {
      rootWithVisibleEffect();
      controller.overlayUiState.toggleSeverity(IssueSeverity.critical);
      await pumpCard(tester);
      await tester.tap(find.text('Title root'));
      await tester.pump();

      await tapVisible(tester, find.bySemanticsLabel('Critical: Title effect'));
      await tester.pump();
      expect(find.text('"Title effect" is filtered out'), findsOneWidget);
      await tester.tap(find.text('Show'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        controller.overlayUiState.severityFilter,
        contains(IssueSeverity.critical),
      );
      expect(expanded(tester, 'effect'), isTrue);
      // The card the user tapped from stays open.
      expect(expanded(tester, 'root'), isTrue);
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('Show on a target both filtered and hidden turns both off', (
      tester,
    ) async {
      rootWithVisibleEffect();
      controller.overlayUiState
        ..toggleSeverity(IssueSeverity.critical)
        ..hide(hideKeyFor(controller.issuesNotifier.value.first));
      await pumpCard(tester);
      await tester.tap(find.text('Title root'));
      await tester.pump();
      await tapVisible(tester, find.bySemanticsLabel('Critical: Title effect'));
      await tester.pump();
      await tester.tap(find.text('Show'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.overlayUiState.hiddenKeys, isEmpty);
      expect(expanded(tester, 'effect'), isTrue);
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('Show leaves a severity on that the user turned on '
        'meanwhile', (tester) async {
      rootWithVisibleEffect();
      controller.overlayUiState.toggleSeverity(IssueSeverity.critical);
      await pumpCard(tester);
      await tester.tap(find.text('Title root'));
      await tester.pump();
      await tapVisible(tester, find.bySemanticsLabel('Critical: Title effect'));
      await tester.pump();
      controller.overlayUiState.toggleSeverity(IssueSeverity.critical);
      await tester.pump();
      await tester.tap(find.text('Show'));
      await tester.pump();
      expect(
        controller.overlayUiState.severityFilter,
        contains(IssueSeverity.critical),
      );
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('a filtered target that folds under the card once shown '
        'opens inline in it', (tester) async {
      // A warning effect folds under its critical root.
      controller.issuesNotifier.value = [
        _issue(
          'root',
          severity: IssueSeverity.critical,
          downstreamIds: ['effect'],
        ),
        _issue('effect', rootCauseIds: ['root']),
      ];
      controller.overlayUiState.toggleSeverity(IssueSeverity.warning);
      await pumpCard(tester);
      await tester.tap(find.text('Title root'));
      await tester.pump();

      await tapVisible(tester, find.bySemanticsLabel('Warning: Title effect'));
      await tester.pump();
      await tester.tap(find.text('Show'));
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Detail effect'), findsOneWidget);
      expect(find.textContaining('could not be shown'), findsNothing);
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('a target above the source, scrolled out of the built list, '
        'scrolls into view', (tester) async {
      controller.issuesNotifier.value = [
        _issue('root', downstreamIds: ['effect']),
        for (var i = 0; i < 30; i++) _issue('filler$i'),
        _issue(
          'effect',
          severity: IssueSeverity.critical,
          rootCauseIds: ['root'],
        ),
      ];
      await pumpCard(tester);
      await tester.dragUntilVisible(
        find.text('Title effect'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.pump();
      expect(find.text('Title root'), findsNothing);
      await tester.tap(find.text('Title effect'));
      await tester.pump();

      await tapVisible(tester, find.bySemanticsLabel('Warning: Title root'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final card = find.byWidgetPredicate(
        (w) => w is IssueCard && w.issue.stableId == 'root',
      );
      expect(expanded(tester, 'root'), isTrue);
      final list = tester.getRect(find.byType(ListView));
      expect(list.overlaps(tester.getRect(card)), isTrue);
      expect(find.textContaining('could not be shown'), findsNothing);
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<IssueCard>()
            ?.issue
            .stableId,
        'root',
      );
    });

    testWidgets('a target collapsed into the card opens inline', (
      tester,
    ) async {
      controller.issuesNotifier.value = [
        _issue('root', downstreamIds: ['effect']),
        _issue('effect', rootCauseIds: ['root']),
      ];
      await pumpCard(tester);
      expect(find.text('Title effect'), findsNothing);
      await tester.tap(find.text('Title root'));
      await tester.pump();

      expect(find.text('Detail effect'), findsNothing);
      await tapVisible(tester, find.bySemanticsLabel('Warning: Title effect'));
      await tester.pump();
      expect(find.text('Detail effect'), findsOneWidget);
    });
  });

  testWidgets('Not useful marks the issue for exports and unmarks it '
      'quietly', (tester) async {
    controller.issuesNotifier.value = [_issue('root')];
    await pumpCard(tester);
    await tester.tap(find.text('Title root'));
    await tester.pump();

    await tapVisible(tester, find.bySemanticsLabel('Not useful'));
    await tester.pump();
    expect(
      controller.isNotUseful(controller.issuesNotifier.value.single),
      isTrue,
    );
    expect(controller.notUsefulMarksForExport(), hasLength(1));
    expect(find.textContaining('Marked not useful'), findsOneWidget);
    await tester.pump(const Duration(seconds: 15));
    await tester.pump(const Duration(milliseconds: 300));

    await tapVisible(tester, find.bySemanticsLabel('Not useful'));
    await tester.pump();
    expect(
      controller.isNotUseful(controller.issuesNotifier.value.single),
      isFalse,
    );
    expect(controller.notUsefulMarksForExport(), isNull);
    expect(find.textContaining('Marked not useful'), findsNothing);
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('unmarking right after marking takes the toast back', (
    tester,
  ) async {
    controller.issuesNotifier.value = [_issue('root')];
    await pumpCard(tester);
    await tester.tap(find.text('Title root'));
    await tester.pump();
    await tapVisible(tester, find.bySemanticsLabel('Not useful'));
    await tester.pump();
    expect(find.textContaining('Marked not useful'), findsOneWidget);
    await tapVisible(tester, find.bySemanticsLabel('Not useful'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Marked not useful'), findsNothing);
  });

  testWidgets('Hide moves focus to the card that takes its place', (
    tester,
  ) async {
    controller.issuesNotifier.value = [_issue('a'), _issue('b')];
    await pumpCard(tester);
    await tester.tap(find.text('Title a'));
    await tester.pump();
    await tapVisible(tester, find.bySemanticsLabel('Hide'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused, isNotNull);
    final card = focused!.findAncestorWidgetOfExactType<IssueCard>();
    expect(card?.issue.stableId, 'b');
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('hiding the last card moves the screen reader to the header', (
    tester,
  ) async {
    controller.issuesNotifier.value = [_issue('a')];
    await pumpCard(tester);
    await tester.tap(find.text('Title a'));
    await tester.pump();
    final events = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<Object?>(
      SystemChannels.accessibility,
      (message) async {
        if (message is Map && message['type'] == 'focus') events.add(message);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<Object?>(
            SystemChannels.accessibility,
            null,
          ),
    );
    await tapVisible(tester, find.bySemanticsLabel('Hide'));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(events, isNotEmpty);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<IssueCard>(),
      isNull,
    );
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('Hide far down a tall card focuses the next card, built and '
      'in view', (tester) async {
    final longFix = [
      'Move it off the UI isolate:',
      for (var i = 0; i < 40; i++)
        'final r$i = await Isolate.run(() => f$i());',
    ].join('\n');
    controller.issuesNotifier.value = [
      _issue('a', fixHint: longFix),
      _issue('b'),
      for (var i = 0; i < 30; i++) _issue('filler$i'),
    ];
    await pumpCard(tester);
    await tester.tap(find.text('Title a'));
    await tester.pump();
    await tapVisible(tester, find.bySemanticsLabel('Hide'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
      focused?.findAncestorWidgetOfExactType<IssueCard>()?.issue.stableId,
      'b',
    );
    final card = find.byWidgetPredicate(
      (w) => w is IssueCard && w.issue.stableId == 'b',
    );
    expect(
      tester.getRect(find.byType(ListView)).overlaps(tester.getRect(card)),
      isTrue,
    );
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('hiding a card no longer reported offers no Undo', (
    tester,
  ) async {
    controller.issuesNotifier.value = [_issue('a'), _issue('b')];
    await pumpCard(tester);
    await tester.tap(find.text('Title a'));
    await tester.pump();
    controller.issuesNotifier.value = [_issue('b')];
    await tester.pump();
    expect(find.text('Not detected right now'), findsOneWidget);
    await tapVisible(tester, find.bySemanticsLabel('Hide'));
    await tester.pump();
    expect(find.text('Issue hidden'), findsOneWidget);
    expect(find.text('Undo'), findsNothing);
    await tester.pump(const Duration(seconds: 15));
  });

  testWidgets('the Rebuild stats link waits for the screen to count '
      'rebuilds', (tester) async {
    controller.issuesNotifier.value = [_issue('rebuild_activity')];
    await pumpCard(tester);
    await tester.tap(find.text('Title rebuild_activity'));
    await tester.pump();
    expect(find.textContaining('See rebuild stats'), findsNothing);
  });

  testWidgets('Copy code copies the code block and confirms', (tester) async {
    controller.issuesNotifier.value = [
      _issue(
        'root',
        fixHint:
            'Move it off the UI isolate:\n'
            'final r = await Isolate.run(() => parse(d));',
      ),
    ];
    await pumpCard(tester);
    await tester.tap(find.text('Title root'));
    await tester.pump();

    await tapVisible(tester, find.bySemanticsLabel('Copy code'));
    await tester.pump();
    expect(clipboard, ['final r = await Isolate.run(() => parse(d));']);
    expect(find.text('Code copied'), findsOneWidget);
    await tester.pump(const Duration(seconds: 15));
  });
}
