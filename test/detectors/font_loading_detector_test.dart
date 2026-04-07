import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/font_loading_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  group('FontLoadingDetector', () {
    late FontLoadingDetector detector;

    setUp(() {
      detector = FontLoadingDetector();
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
              Text('d', style: TextStyle(fontFamily: 'FontD')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('no issues when 3 or fewer custom fonts', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('flags when >3 custom font families detected', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
              Text('d', style: TextStyle(fontFamily: 'FontD')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('4 families'));
      expect(detector.issues.first.observationSource,
          ObservationSource.structural);
    });

    testWidgets('system fonts are not counted', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'Roboto')),
              Text('b', style: TextStyle(fontFamily: 'Arial')),
              Text('c', style: TextStyle(fontFamily: 'Helvetica')),
              Text('d', style: TextStyle(fontFamily: 'Times')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('counts unique families only (deduplication)', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              10,
              (_) => const Text('a', style: TextStyle(fontFamily: 'FontA')),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      // Only 1 unique family, below threshold of >3
      expect(detector.issues, isEmpty);
    });

    testWidgets('RichText root style fontFamily detected', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              const Text('a', style: TextStyle(fontFamily: 'FontA')),
              const Text('b', style: TextStyle(fontFamily: 'FontB')),
              const Text('c', style: TextStyle(fontFamily: 'FontC')),
              // RichText with root-level fontFamily provides the 4th font
              RichText(
                text: const TextSpan(
                  text: 'd',
                  style: TextStyle(fontFamily: 'FontD'),
                ),
              ),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, hasLength(1));
    });

    testWidgets('stableId, confidence, and category', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
              Text('d', style: TextStyle(fontFamily: 'FontD')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issue = detector.issues.first;
      expect(issue.stableId, 'multiple_custom_fonts');
      expect(issue.confidence, IssueConfidence.possible);
      expect(issue.category, IssueCategory.font);
      expect(issue.severity, IssueSeverity.warning);
    });

    testWidgets('no highlights produced', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
              Text('d', style: TextStyle(fontFamily: 'FontD')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isEmpty);
    });

    testWidgets('dispose clears issues', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('a', style: TextStyle(fontFamily: 'FontA')),
              Text('b', style: TextStyle(fontFamily: 'FontB')),
              Text('c', style: TextStyle(fontFamily: 'FontC')),
              Text('d', style: TextStyle(fontFamily: 'FontD')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
    });

    // -----------------------------------------------------------------
    // Custom thresholds
    // -----------------------------------------------------------------

    testWidgets('custom maxFamilies fires at lower count', (tester) async {
      detector = FontLoadingDetector(maxFamilies: 1);
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('A', style: TextStyle(fontFamily: 'Lobster')),
              Text('B', style: TextStyle(fontFamily: 'Pacifico')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, hasLength(1));
    });

    testWidgets('default maxFamilies allows 3 custom fonts', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              Text('A', style: TextStyle(fontFamily: 'Lobster')),
              Text('B', style: TextStyle(fontFamily: 'Pacifico')),
              Text('C', style: TextStyle(fontFamily: 'DancingScript')),
            ],
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    // -----------------------------------------------------------------
    // v11.11: Runtime font loading (google_fonts) detection
    // -----------------------------------------------------------------

    group('runtime font loading detection', () {
      testWidgets('flags font with fontFamilyFallback as runtime-loaded',
          (tester) async {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              'Hello',
              style: TextStyle(
                fontFamily: 'Lato',
                fontFamilyFallback: ['Lato'],
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'runtime_font_loading');
        expect(detector.issues.first.title, contains('Runtime Font Loading'));
        expect(detector.issues.first.title, contains('1 family'));
        expect(detector.issues.first.confidence, IssueConfidence.possible);
      });

      testWidgets('no issue for font without fontFamilyFallback',
          (tester) async {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              'Hello',
              style: TextStyle(fontFamily: 'Lato'),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        // Only 1 custom font — below maxFamilies threshold, no runtime signal
        expect(detector.issues, isEmpty);
      });

      testWidgets('no issue for system font with fontFamilyFallback',
          (tester) async {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              'Hello',
              style: TextStyle(
                fontFamily: 'Roboto',
                fontFamilyFallback: ['Arial'],
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, isEmpty,
            reason: 'System fonts should not trigger runtime loading warning');
      });

      testWidgets('counts multiple runtime-loaded families', (tester) async {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                Text(
                  'A',
                  style: TextStyle(
                    fontFamily: 'Lato',
                    fontFamilyFallback: ['Lato'],
                  ),
                ),
                Text(
                  'B',
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontFamilyFallback: ['Montserrat'],
                  ),
                ),
                Text(
                  'C',
                  style: TextStyle(
                    fontFamily: 'OpenSans',
                    fontFamilyFallback: ['OpenSans'],
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final runtimeIssue = detector.issues
            .firstWhere((i) => i.stableId == 'runtime_font_loading');
        expect(runtimeIssue.title, contains('3 families'));
        expect(runtimeIssue.severity, IssueSeverity.critical);
      });

      testWidgets('warning severity when <= 2 runtime families',
          (tester) async {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                Text(
                  'A',
                  style: TextStyle(
                    fontFamily: 'Lato',
                    fontFamilyFallback: ['Lato'],
                  ),
                ),
                Text(
                  'B',
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontFamilyFallback: ['Montserrat'],
                  ),
                ),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final runtimeIssue = detector.issues
            .firstWhere((i) => i.stableId == 'runtime_font_loading');
        expect(runtimeIssue.severity, IssueSeverity.warning);
      });

      testWidgets('RichText with fontFamilyFallback detected', (tester) async {
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: RichText(
              text: const TextSpan(
                text: 'Hello',
                style: TextStyle(
                  fontFamily: 'Poppins',
                  fontFamilyFallback: ['Poppins'],
                ),
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'runtime_font_loading');
      });

      testWidgets('detail mentions fontFamilyFallback', (tester) async {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              'Hello',
              style: TextStyle(
                fontFamily: 'Lato',
                fontFamilyFallback: ['Lato'],
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        expect(detector.issues.first.detail,
            contains('fontFamilyFallback detected'));
      });

      testWidgets('dispose clears runtime loaded families', (tester) async {
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              'Hello',
              style: TextStyle(
                fontFamily: 'Lato',
                fontFamilyFallback: ['Lato'],
              ),
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));
        expect(detector.issues, isNotEmpty);

        detector.dispose();
        expect(detector.issues, isEmpty);
      });

      testWidgets('runtime_font_loading and multiple_custom_fonts can coexist',
          (tester) async {
        // 1 runtime-loaded + 3 non-runtime custom = 4 total custom fonts
        // Expect: runtime_font_loading (1 family) + multiple_custom_fonts (4)
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                Text(
                  'A',
                  style: TextStyle(
                    fontFamily: 'Lato',
                    fontFamilyFallback: ['Lato'],
                  ),
                ),
                Text('B', style: TextStyle(fontFamily: 'FontB')),
                Text('C', style: TextStyle(fontFamily: 'FontC')),
                Text('D', style: TextStyle(fontFamily: 'FontD')),
              ],
            ),
          ),
        );
        detector.scanTree(tester.element(find.byType(Directionality)));

        final runtimeIssues =
            detector.issues.where((i) => i.stableId == 'runtime_font_loading');
        final multipleIssues =
            detector.issues.where((i) => i.stableId == 'multiple_custom_fonts');

        expect(runtimeIssues, hasLength(1),
            reason: 'Should emit runtime_font_loading for Lato');
        expect(multipleIssues, hasLength(1),
            reason: 'Should emit multiple_custom_fonts for all 4 fonts');
      });
    });
  });
}
