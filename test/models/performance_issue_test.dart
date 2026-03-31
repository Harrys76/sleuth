import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

void main() {
  group('PerformanceIssue routeName', () {
    const base = PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Test Issue',
      detail: 'detail',
      fixHint: 'fix',
    );

    test('routeName defaults to null', () {
      expect(base.routeName, isNull);
    });

    test('routeName preserved in copyWith when not overridden', () {
      final withRoute = base.copyWith(routeName: '/home');
      final copied = withRoute.copyWith(title: 'Changed');
      expect(copied.routeName, '/home');
    });

    test('routeName overridden in copyWith', () {
      final withRoute = base.copyWith(routeName: '/home');
      final changed = withRoute.copyWith(routeName: '/settings');
      expect(changed.routeName, '/settings');
    });

    test('toString includes routeName when present', () {
      final withRoute = base.copyWith(routeName: '/home');
      expect(withRoute.toString(), contains('route: /home'));
    });

    test('toString omits routeName when null', () {
      expect(base.toString(), isNot(contains('route:')));
    });
  });

  group('PerformanceIssue observationSource', () {
    const base = PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Test Issue',
      detail: 'detail',
      fixHint: 'fix',
    );

    test('observationSource defaults to null', () {
      expect(base.observationSource, isNull);
    });

    test('observationSource preserved in copyWith when not overridden', () {
      final withSource =
          base.copyWith(observationSource: ObservationSource.vmTimeline);
      final copied = withSource.copyWith(title: 'Changed');
      expect(copied.observationSource, ObservationSource.vmTimeline);
    });

    test('observationSource overridden in copyWith', () {
      final withSource =
          base.copyWith(observationSource: ObservationSource.vmTimeline);
      final changed =
          withSource.copyWith(observationSource: ObservationSource.structural);
      expect(changed.observationSource, ObservationSource.structural);
    });

    test('toString includes observationSource when present', () {
      final withSource =
          base.copyWith(observationSource: ObservationSource.debugCallback);
      expect(withSource.toString(),
          contains('source: ObservationSource.debugCallback'));
    });

    test('toString omits observationSource when null', () {
      expect(base.toString(), isNot(contains('source:')));
    });
  });

  group('PerformanceIssue interactionContext', () {
    const base = PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Test Issue',
      detail: 'detail',
      fixHint: 'fix',
    );

    test('interactionContext defaults to null', () {
      expect(base.interactionContext, isNull);
    });

    test('interactionContext preserved in copyWith when not overridden', () {
      final withCtx =
          base.copyWith(interactionContext: InteractionContext.scrolling);
      final copied = withCtx.copyWith(title: 'Changed');
      expect(copied.interactionContext, InteractionContext.scrolling);
    });

    test('interactionContext overridden in copyWith', () {
      final withCtx =
          base.copyWith(interactionContext: InteractionContext.scrolling);
      final changed =
          withCtx.copyWith(interactionContext: InteractionContext.idle);
      expect(changed.interactionContext, InteractionContext.idle);
    });

    test('toString includes interactionContext when present', () {
      final withCtx =
          base.copyWith(interactionContext: InteractionContext.scrolling);
      expect(withCtx.toString(),
          contains('interaction: InteractionContext.scrolling'));
    });

    test('toString omits interactionContext when null', () {
      expect(base.toString(), isNot(contains('interaction:')));
    });
  });

  group('PerformanceIssue ancestorChain', () {
    const base = PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Test Issue',
      detail: 'detail',
      fixHint: 'fix',
    );

    test('ancestorChain defaults to null', () {
      expect(base.ancestorChain, isNull);
    });

    test('ancestorChain preserved in copyWith when not overridden', () {
      final withChain = base.copyWith(ancestorChain: 'MyPage > Column > Image');
      final copied = withChain.copyWith(title: 'Changed');
      expect(copied.ancestorChain, 'MyPage > Column > Image');
    });

    test('ancestorChain overridden in copyWith', () {
      final withChain = base.copyWith(ancestorChain: 'MyPage > Column > Image');
      final changed =
          withChain.copyWith(ancestorChain: 'OtherPage > Row > Text');
      expect(changed.ancestorChain, 'OtherPage > Row > Text');
    });

    test('toString includes ancestorChain when present', () {
      final withChain = base.copyWith(ancestorChain: 'MyPage > Column > Image');
      expect(withChain.toString(), contains('chain: MyPage > Column > Image'));
    });

    test('toString omits ancestorChain when null', () {
      expect(base.toString(), isNot(contains('chain:')));
    });

    test('toJson includes ancestorChain when non-null', () {
      final withChain = base.copyWith(ancestorChain: 'MyPage > Column > Image');
      final json = withChain.toJson();
      expect(json['ancestorChain'], 'MyPage > Column > Image');
    });

    test('toJson omits ancestorChain when null', () {
      final json = base.toJson();
      expect(json.containsKey('ancestorChain'), isFalse);
    });

    test('fromJson parses ancestorChain', () {
      final json = base.copyWith(ancestorChain: 'A > B > C').toJson();
      final parsed = PerformanceIssue.fromJson(json);
      expect(parsed.ancestorChain, 'A > B > C');
    });

    test('fromJson handles missing ancestorChain', () {
      final json = base.toJson();
      final parsed = PerformanceIssue.fromJson(json);
      expect(parsed.ancestorChain, isNull);
    });
  });

  group('PerformanceIssue fixEffort', () {
    const base = PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Test Issue',
      detail: 'detail',
      fixHint: 'fix',
    );

    test('fixEffort defaults to null', () {
      expect(base.fixEffort, isNull);
    });

    test('fixEffort preserved in copyWith when not overridden', () {
      final withEffort = base.copyWith(fixEffort: FixEffort.quick);
      final copied = withEffort.copyWith(title: 'Changed');
      expect(copied.fixEffort, FixEffort.quick);
    });

    test('fixEffort overridden in copyWith', () {
      final withEffort = base.copyWith(fixEffort: FixEffort.quick);
      final changed = withEffort.copyWith(fixEffort: FixEffort.involved);
      expect(changed.fixEffort, FixEffort.involved);
    });

    test('toString includes fixEffort when present', () {
      final withEffort = base.copyWith(fixEffort: FixEffort.medium);
      expect(withEffort.toString(), contains('effort: FixEffort.medium'));
    });

    test('toString omits fixEffort when null', () {
      expect(base.toString(), isNot(contains('effort:')));
    });

    test('toJson includes fixEffort when non-null', () {
      final withEffort = base.copyWith(fixEffort: FixEffort.involved);
      final json = withEffort.toJson();
      expect(json['fixEffort'], 'involved');
    });

    test('toJson omits fixEffort when null', () {
      final json = base.toJson();
      expect(json.containsKey('fixEffort'), isFalse);
    });

    test('fromJson parses fixEffort', () {
      final json = base.copyWith(fixEffort: FixEffort.quick).toJson();
      final parsed = PerformanceIssue.fromJson(json);
      expect(parsed.fixEffort, FixEffort.quick);
    });

    test('fromJson handles missing fixEffort', () {
      final json = base.toJson();
      final parsed = PerformanceIssue.fromJson(json);
      expect(parsed.fixEffort, isNull);
    });
  });

  group('PerformanceIssue equality (v6.13)', () {
    const base = PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Test Issue',
      detail: 'detail',
      fixHint: 'fix',
      stableId: 'test_issue',
    );

    test('same stableId → equal regardless of other fields', () {
      final other = base.copyWith(
        severity: IssueSeverity.critical,
        confidence: IssueConfidence.possible,
        title: 'Different Title',
        detail: 'different detail',
      );
      expect(base, equals(other));
    });

    test('different stableId → not equal', () {
      final other = base.copyWith(stableId: 'other_issue');
      expect(base, isNot(equals(other)));
    });

    test('null stableId → not equal to each other', () {
      // Use non-const to avoid Dart const canonicalization (identical instance).
      // ignore: prefer_const_constructors
      final a = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Test Issue',
        detail: 'detail',
        fixHint: 'fix',
      );
      // ignore: prefer_const_constructors
      final b = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Test Issue',
        detail: 'detail',
        fixHint: 'fix',
      );
      expect(a, isNot(equals(b)));
    });

    test('null stableId issue not equal to non-null stableId issue', () {
      const noId = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Test Issue',
        detail: 'detail',
        fixHint: 'fix',
      );
      expect(noId, isNot(equals(base)));
    });

    test('identical reference → equal', () {
      expect(base, equals(base));
    });

    test('Set deduplication by stableId', () {
      final a = base.copyWith(severity: IssueSeverity.critical);
      final b = base.copyWith(severity: IssueSeverity.ok);
      final set = {base, a, b};
      expect(set.length, 1);
    });

    test('hashCode consistent: equal objects produce equal hashCodes', () {
      final other = base.copyWith(title: 'Different Title');
      expect(base.hashCode, equals(other.hashCode));
    });

    test(
        'hashCode distribution: different stableIds produce different hashCodes',
        () {
      final other = base.copyWith(stableId: 'completely_different');
      expect(base.hashCode, isNot(equals(other.hashCode)));
    });

    test('can be used as Map key', () {
      final map = <PerformanceIssue, String>{};
      map[base] = 'first';
      final sameId = base.copyWith(title: 'Updated Title');
      map[sameId] = 'second';
      expect(map.length, 1);
      expect(map[base], 'second');
    });
  });

  group('InteractionContext displayName', () {
    test('idle', () {
      expect(InteractionContext.idle.displayName, 'idle');
    });

    test('scrolling', () {
      expect(InteractionContext.scrolling.displayName, 'scrolling');
    });

    test('navigating', () {
      expect(InteractionContext.navigating.displayName, 'route transition');
    });
  });
}
