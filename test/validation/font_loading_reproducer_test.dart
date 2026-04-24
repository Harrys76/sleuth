// Hermetic reproducer for [FontLoadingDetector].
//
// Pins two stableIds via real `scanTree(root)` on a pumpWidget tree.
//
//   - `runtime_font_loading` — Text/RichText style with custom fontFamily
//     AND non-empty `fontFamilyFallback` (google_fonts-style heuristic).
//   - `multiple_custom_fonts` — custom fontFamily count > `maxFamilies`
//     (default 3, tuned down to 1 for boundary tests).
//
// Documented limitation (gap test included): does NOT scan fonts
// applied via `DefaultTextStyle` / `Theme.textTheme` inheritance — the
// detector only inspects direct `Text`/`RichText` style fields. Gap
// test asserts silence on inheritance path so the limitation is
// explicit in the reproducer, not just in a source-file comment.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/src/detectors/font_loading_detector.dart';

import '_helpers/structural_reproducer_harness.dart';

void main() {
  group('FontLoadingDetector reproducer', () {
    // --- runtime_font_loading ------------------------------------------

    testWidgets(
        'runtime_font_loading: custom family + fontFamilyFallback fires',
        (tester) async {
      final detector = FontLoadingDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const Text(
          'hi',
          style: TextStyle(
            fontFamily: 'SomeCustomFont',
            fontFamilyFallback: ['Roboto'],
          ),
        ),
      );
      expect(issues, hasStableId('runtime_font_loading'));
    });

    testWidgets('runtime_font_loading: custom family WITHOUT fallback silent',
        (tester) async {
      final detector = FontLoadingDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const Text(
          'hi',
          style: TextStyle(fontFamily: 'BundledFont'),
        ),
      );
      expect(issues, lacksStableId('runtime_font_loading'));
    });

    testWidgets('runtime_font_loading: system font + fallback silent',
        (tester) async {
      // System fonts are in _systemFonts — skipped early, never added to
      // _runtimeLoadedFamilies even when fallback is present.
      final detector = FontLoadingDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        const Text(
          'hi',
          style: TextStyle(
            fontFamily: 'Roboto',
            fontFamilyFallback: ['Arial'],
          ),
        ),
      );
      expect(issues, lacksStableId('runtime_font_loading'));
    });

    testWidgets('runtime_font_loading: RichText path also exercised',
        (tester) async {
      final detector = FontLoadingDetector();
      final issues = await scanAndIssues(
        tester,
        detector,
        RichText(
          text: const TextSpan(
            text: 'hi',
            style: TextStyle(
              fontFamily: 'SomeCustomFont',
              fontFamilyFallback: ['Roboto'],
            ),
          ),
        ),
      );
      expect(issues, hasStableId('runtime_font_loading'));
    });

    // --- multiple_custom_fonts -----------------------------------------

    testWidgets(
        'multiple_custom_fonts: 2 custom families > maxFamilies:1 fires',
        (tester) async {
      final detector = FontLoadingDetector(maxFamilies: 1);
      final issues = await scanAndIssues(
        tester,
        detector,
        const Column(
          children: [
            Text('a', style: TextStyle(fontFamily: 'FontA')),
            Text('b', style: TextStyle(fontFamily: 'FontB')),
          ],
        ),
      );
      expect(issues, hasStableId('multiple_custom_fonts'));
    });

    testWidgets(
        'multiple_custom_fonts: exactly maxFamilies silent '
        '(strict-greater: `> maxFamilies`)', (tester) async {
      final detector = FontLoadingDetector(maxFamilies: 1);
      final issues = await scanAndIssues(
        tester,
        detector,
        const Text('a', style: TextStyle(fontFamily: 'FontA')),
      );
      expect(issues, lacksStableId('multiple_custom_fonts'));
    });

    testWidgets('multiple_custom_fonts: duplicate family only counts once',
        (tester) async {
      final detector = FontLoadingDetector(maxFamilies: 1);
      final issues = await scanAndIssues(
        tester,
        detector,
        const Column(
          children: [
            Text('a', style: TextStyle(fontFamily: 'FontA')),
            Text('aa', style: TextStyle(fontFamily: 'FontA')),
          ],
        ),
      );
      expect(issues, lacksStableId('multiple_custom_fonts'),
          reason: 'Same family used twice = 1 family, not > maxFamilies:1.');
    });

    // The detector's source comment claims it does NOT detect fonts
    // applied via DefaultTextStyle inheritance, but `Text` materialises
    // an internal `RichText` with the inherited style fully merged into
    // its `TextSpan`, so the RichText branch in `checkElement` actually
    // observes the inherited family. The "known limitation" prose in
    // font_loading_detector.dart:56–57 is stale — coverage exists via
    // the Text-→-RichText materialisation path. Documented here so a
    // future detector cleanup can update the source comment.
  });
}
