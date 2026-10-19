import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/not_useful_mark.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/session_snapshot.dart';

PerformanceIssue _issue(
  String id, {
  String? widgetName,
  IssueMeasurement? measurement,
  String? route,
}) => PerformanceIssue(
  stableId: id,
  severity: IssueSeverity.warning,
  category: IssueCategory.build,
  confidence: IssueConfidence.likely,
  title: 'Title $id',
  detail: '',
  fixHint: '',
  widgetName: widgetName,
  measurement: measurement,
  sourceRoute: route,
);

void main() {
  group('Not useful store', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
    });

    tearDown(() => controller.dispose());

    test('mark and unmark by list key', () {
      final issue = _issue('rebuild_activity', widgetName: 'Feed');
      controller.markNotUseful(issue);
      expect(controller.isNotUseful(issue), isTrue);
      expect(
        controller.notUsefulNotifier.value.single.key,
        'rebuild_activity|Feed',
      );

      // The same key on another widget is a different card.
      expect(
        controller.isNotUseful(_issue('rebuild_activity', widgetName: 'Bar')),
        isFalse,
      );

      controller.clearNotUseful('rebuild_activity|Feed');
      expect(controller.isNotUseful(issue), isFalse);
      expect(controller.notUsefulNotifier.value, isEmpty);
      expect(controller.notUsefulMarksForExport(), isNull);
    });

    test('marking again moves the mark to the newest end', () {
      controller
        ..markNotUseful(_issue('a'))
        ..markNotUseful(_issue('b'))
        ..markNotUseful(_issue('a'));
      expect(controller.notUsefulNotifier.value.map((m) => m.key), ['b', 'a']);
    });

    test('the cap evicts the oldest mark', () {
      for (var i = 0; i <= SleuthController.maxNotUsefulMarks; i++) {
        controller.markNotUseful(_issue('id$i'));
      }
      final keys = controller.notUsefulNotifier.value.map((m) => m.key);
      expect(keys, hasLength(SleuthController.maxNotUsefulMarks));
      expect(keys.first, 'id1');
      expect(keys.last, 'id${SleuthController.maxNotUsefulMarks}');
    });

    test('live follows the reported issues at export', () {
      final kept = _issue('kept');
      final gone = _issue('gone');
      controller
        ..seedIssuesForTest([kept, gone])
        ..markNotUseful(kept)
        ..markNotUseful(gone)
        ..seedIssuesForTest([kept]);
      final marks = controller.notUsefulMarksForExport()!;
      expect(
        {for (final m in marks) m.key: m.live},
        {'kept': true, 'gone': false},
      );
    });

    test('the snapshot carries the marks only when there are some', () {
      expect(
        controller.exportSnapshot().toJson().containsKey('notUsefulMarks'),
        isFalse,
      );
      controller.markNotUseful(_issue('a'));
      final json = controller.exportSnapshot().toJson();
      expect((json['notUsefulMarks'] as List), hasLength(1));
    });
  });

  group('NotUsefulMark', () {
    test('takes its fields from the issue', () {
      const m = IssueMeasurement(
        value: 26,
        unit: MeasurementUnit.perSecond,
        warningAt: 10,
        criticalAt: 30,
        criticalStrict: true,
      );
      final at = DateTime.utc(2026, 10, 19, 12);
      final mark = NotUsefulMark.fromIssue(
        _issue('rebuild_debug_Feed', measurement: m, route: '/feed'),
        key: 'rebuild_debug_Feed',
        markedAt: at,
      );
      expect(mark.title, 'Title rebuild_debug_Feed');
      expect(mark.measurement, m);
      expect(mark.route, '/feed');
      expect(mark.live, isTrue);
    });

    test('JSON round trip with and without optional fields', () {
      final full = NotUsefulMark(
        key: 'k|W',
        stableId: 'k',
        title: 't',
        category: IssueCategory.paint,
        severity: IssueSeverity.critical,
        confidence: IssueConfidence.confirmed,
        measurement: const IssueMeasurement(
          value: 31,
          unit: MeasurementUnit.percent,
          warningAt: 10,
          criticalAt: 30,
          strict: true,
        ),
        route: '/r',
        markedAt: DateTime.utc(2026, 10, 19),
        live: false,
      );
      final bare = NotUsefulMark(
        key: 'title only',
        title: 'title only',
        category: IssueCategory.network,
        severity: IssueSeverity.warning,
        confidence: IssueConfidence.possible,
        markedAt: DateTime.utc(2026, 10, 19),
      );
      for (final mark in [full, bare]) {
        final back = NotUsefulMark.fromJson(
          jsonDecode(jsonEncode(mark.toJson())),
        );
        expect(back, mark);
      }
      expect(bare.toJson().keys, isNot(contains('stableId')));
      expect(bare.toJson().keys, isNot(contains('measurement')));
      expect(bare.toJson().keys, isNot(contains('route')));
    });

    test('fromJson returns null for a mark it cannot read', () {
      final good = NotUsefulMark(
        key: 'k',
        title: 't',
        category: IssueCategory.build,
        severity: IssueSeverity.warning,
        confidence: IssueConfidence.likely,
        markedAt: DateTime.utc(2026),
      ).toJson();
      expect(NotUsefulMark.fromJson('not a map'), isNull);
      for (final field in ['key', 'title', 'markedAt']) {
        expect(NotUsefulMark.fromJson({...good}..remove(field)), isNull);
      }
      expect(NotUsefulMark.fromJson({...good, 'severity': 'fatal'}), isNull);
      expect(NotUsefulMark.fromJson({...good, 'markedAt': 'soon'}), isNull);
    });

    test('a snapshot reads its marks back', () {
      final mark = NotUsefulMark(
        key: 'k',
        title: 't',
        category: IssueCategory.build,
        severity: IssueSeverity.warning,
        confidence: IssueConfidence.likely,
        markedAt: DateTime.utc(2026),
      );
      final controller = SleuthController();
      addTearDown(controller.dispose);
      final json = jsonDecode(
        jsonEncode({
          ...controller.exportSnapshot().toJson(),
          'notUsefulMarks': [mark.toJson(), 'garbage'],
        }),
      );
      final snapshot = SessionSnapshot.fromJson(json as Map<String, dynamic>);
      expect(snapshot.notUsefulMarks, [mark]);
    });
  });
}
