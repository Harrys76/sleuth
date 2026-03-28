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
