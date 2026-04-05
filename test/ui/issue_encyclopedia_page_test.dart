import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';
import 'package:widget_watchdog/src/ui/issue_card.dart';
import 'package:widget_watchdog/src/ui/issue_encyclopedia_page.dart';
import 'package:widget_watchdog/src/utils/issue_explanation_builder.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  PerformanceIssue makeIssue({
    String? stableId,
    String title = 'Test Issue',
    String detail = 'Detail text',
    String fixHint = 'Fix hint text',
    IssueSeverity severity = IssueSeverity.warning,
    IssueCategory category = IssueCategory.memory,
    IssueConfidence confidence = IssueConfidence.confirmed,
    ObservationSource? observationSource,
    InteractionContext? interactionContext,
    FixEffort? fixEffort,
  }) {
    return PerformanceIssue(
      stableId: stableId,
      title: title,
      detail: detail,
      fixHint: fixHint,
      severity: severity,
      category: category,
      confidence: confidence,
      observationSource: observationSource,
      interactionContext: interactionContext,
      fixEffort: fixEffort,
    );
  }

  group('IssueEncyclopediaPage', () {
    testWidgets('renders page header', (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));

      expect(find.text('Issue Encyclopedia'), findsOneWidget);
    });

    testWidgets('back button calls onClose', (tester) async {
      var closed = false;
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () => closed = true),
      ));

      await tester.tap(find.byIcon(Icons.arrow_back));
      expect(closed, isTrue);
    });

    testWidgets('shows all 8 category group headers', (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      expect(find.text('BUILD & REBUILD'), findsOneWidget);
      expect(find.text('LAYOUT'), findsOneWidget);
      expect(find.text('PAINT & REPAINT'), findsOneWidget);
      expect(find.text('GPU & RASTER'), findsOneWidget);
      expect(find.text('MEMORY'), findsOneWidget);
      expect(find.text('NETWORK'), findsOneWidget);
      expect(find.text('FONT'), findsOneWidget);
      expect(find.text('PLATFORM CHANNELS'), findsOneWidget);
    });

    testWidgets('shows entries by display name', (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      // Sample from different categories
      expect(find.text('Sustained Jank'), findsOneWidget);
      expect(find.text('Heap Near Capacity'), findsOneWidget);
      expect(find.text('Shader Compilation'), findsOneWidget);
    });

    testWidgets('expanding an entry shows explanation sections',
        (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      // Tap to expand "Sustained Jank"
      await tester.tap(find.text('Sustained Jank'));
      await tester.pumpAndSettle();

      expect(find.text('What it is'), findsOneWidget);
      expect(find.text('Reading the data'), findsOneWidget);
      expect(find.text('Why it matters'), findsOneWidget);
      expect(find.text('How to fix'), findsOneWidget);
    });

    testWidgets('collapsing an entry hides explanation sections',
        (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      // Expand
      await tester.tap(find.text('Sustained Jank'));
      await tester.pumpAndSettle();
      expect(find.text('What it is'), findsOneWidget);

      // Collapse
      await tester.tap(find.text('Sustained Jank'));
      await tester.pumpAndSettle();
      expect(find.text('What it is'), findsNothing);
    });

    testWidgets('search filters entries', (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      // Use a specific term that only matches memory entries
      await tester.enterText(find.byType(TextField), 'garbage collector');
      // Wait for debounce (150ms) + settle
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      // GC Pressure entry visible (whatItIs contains "garbage collector")
      expect(find.text('GC Pressure'), findsOneWidget);

      // Non-matching entries hidden
      expect(find.text('Sustained Jank'), findsNothing);
      expect(find.text('Shader Compilation'), findsNothing);
    });

    testWidgets('search hides empty category groups', (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      // "Platform Channel Traffic" is unique to the channel category
      await tester.enterText(
          find.byType(TextField), 'Platform Channel Traffic');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      // Channel category visible
      expect(find.text('PLATFORM CHANNELS'), findsOneWidget);

      // Other categories hidden
      expect(find.text('BUILD & REBUILD'), findsNothing);
      expect(find.text('MEMORY'), findsNothing);
      expect(find.text('PAINT & REPAINT'), findsNothing);
    });

    testWidgets('search shows "No matching issues" when zero results',
        (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'xyznonexistent');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.text('No matching issues'), findsOneWidget);
    });

    testWidgets('clear search shows all entries', (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      // Search to filter
      await tester.enterText(find.byType(TextField), 'heap');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('BUILD & REBUILD'), findsNothing);

      // Clear search
      await tester.enterText(find.byType(TextField), '');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('BUILD & REBUILD'), findsOneWidget);
      expect(find.text('MEMORY'), findsOneWidget);
    });

    testWidgets('scrollToStableId opens with that entry expanded',
        (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(
          onClose: () {},
          scrollToStableId: 'heap_near_capacity',
        ),
      ));
      await tester.pumpAndSettle();

      // The entry should be expanded — explanation sections visible
      final explanation =
          IssueExplanationBuilder.explain('heap_near_capacity')!;
      expect(find.text(explanation.whatItIs), findsOneWidget);
    });

    testWidgets('whenToIgnore hidden when null (heavy_compute)',
        (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      // Expand heavy_compute
      await tester.tap(find.text('Heavy Computation'));
      await tester.pumpAndSettle();

      expect(find.text('What it is'), findsOneWidget);
      expect(find.text('Reading the data'), findsOneWidget);
      expect(find.text('Why it matters'), findsOneWidget);
      expect(find.text('How to fix'), findsOneWidget);
      // heavy_compute has whenToIgnore: null
      expect(find.text('When to ignore'), findsNothing);
    });

    testWidgets('unknown scrollToStableId opens page gracefully',
        (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(
          onClose: () {},
          scrollToStableId: 'nonexistent_detector_xyz',
        ),
      ));
      await tester.pumpAndSettle();

      // Page renders normally, all categories visible
      expect(find.text('Issue Encyclopedia'), findsOneWidget);
      expect(find.text('BUILD & REBUILD'), findsOneWidget);
    });

    testWidgets('Reading the data visible for runtime entry (gc_pressure)',
        (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(
          onClose: () {},
          scrollToStableId: 'gc_pressure',
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Reading the data'), findsOneWidget);
      final explanation = IssueExplanationBuilder.explain('gc_pressure')!;
      expect(find.text(explanation.readingTheData!), findsOneWidget);
    });

    testWidgets('Reading the data hidden for structural entry (non_lazy_list)',
        (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(
          onClose: () {},
          scrollToStableId: 'non_lazy_list',
        ),
      ));
      await tester.pumpAndSettle();

      // non_lazy_list is structural — readingTheData is null
      expect(find.text('Reading the data'), findsNothing);
      // But other sections are visible
      expect(find.text('What it is'), findsOneWidget);
      expect(find.text('Why it matters'), findsOneWidget);
    });

    testWidgets('search matches readingTheData content', (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      // "GC/min" appears only in gc_pressure's readingTheData
      await tester.enterText(find.byType(TextField), 'GC/min');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.text('GC Pressure'), findsOneWidget);
      // Non-matching entries hidden
      expect(find.text('Sustained Jank'), findsNothing);
      expect(find.text('Shader Compilation'), findsNothing);
    });

    testWidgets('renders search bar', (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.search), findsOneWidget);
    });

    testWidgets('clear button resets search', (tester) async {
      await tester.pumpWidget(wrap(
        IssueEncyclopediaPage(onClose: () {}),
      ));
      await tester.pumpAndSettle();

      // Search to filter
      await tester.enterText(find.byType(TextField), 'garbage collector');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('Sustained Jank'), findsNothing);

      // Tap clear button
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      // All entries visible again
      expect(find.text('BUILD & REBUILD'), findsOneWidget);
      expect(find.text('Sustained Jank'), findsOneWidget);
    });
  });

  group('IssueCard onLearnMore', () {
    testWidgets('Learn more link visible when onLearnMore is provided',
        (tester) async {
      await tester.pumpWidget(wrap(
        SingleChildScrollView(
          child: IssueCard(
            issue: makeIssue(stableId: 'heap_near_capacity'),
            initiallyExpanded: true,
            onLearnMore: () {},
          ),
        ),
      ));

      expect(find.text('Learn more about this issue'), findsOneWidget);
    });

    testWidgets('Learn more link hidden when onLearnMore is null',
        (tester) async {
      await tester.pumpWidget(wrap(
        SingleChildScrollView(
          child: IssueCard(
            issue: makeIssue(stableId: 'heap_near_capacity'),
            initiallyExpanded: true,
          ),
        ),
      ));

      expect(find.text('Learn more about this issue'), findsNothing);
    });

    testWidgets('tapping Learn more calls callback', (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(
        SingleChildScrollView(
          child: IssueCard(
            issue: makeIssue(stableId: 'heap_near_capacity'),
            initiallyExpanded: true,
            onLearnMore: () => tapped = true,
          ),
        ),
      ));

      await tester.tap(find.text('Learn more about this issue'));
      expect(tapped, isTrue);
    });
  });
}
