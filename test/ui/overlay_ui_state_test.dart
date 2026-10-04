import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';

PerformanceIssue _issue(
  String id, {
  IssueSeverity severity = IssueSeverity.warning,
  String? widgetName,
  List<String>? rootCauseIds,
  bool withStableId = true,
}) => PerformanceIssue(
  severity: severity,
  category: IssueCategory.build,
  confidence: IssueConfidence.likely,
  title: 'title $id',
  detail: 'detail',
  fixHint: 'fix',
  stableId: withStableId ? id : null,
  widgetName: widgetName,
  rootCauseIds: rootCauseIds,
);

void main() {
  group('OverlayUiState JSON', () {
    test('round-trips every persisted field', () {
      final state = OverlayUiState()
        ..triggerAnchor = (edge: TriggerEdge.left, fraction: 0.25)
        ..setCardGeometry(
          offset: const Offset(12, 80),
          width: 320,
          height: 410,
          windowState: CardWindowState.minimized,
          restoreOffset: const Offset(10, 90),
          restoreWidth: 300,
          restoreHeight: 400,
        )
        ..hide('a')
        ..hide('b|Foo')
        ..toggleSeverity(IssueSeverity.ok);

      final json = jsonDecode(jsonEncode(state.toJson()));
      final copy = OverlayUiState.fromJson(json as Map<String, Object?>);

      expect(copy.triggerAnchor, (edge: TriggerEdge.left, fraction: 0.25));
      expect(copy.cardOffset, const Offset(12, 80));
      expect(copy.cardWidth, 320);
      expect(copy.cardHeight, 410);
      expect(copy.windowState, CardWindowState.minimized);
      expect(copy.restoreOffset, const Offset(10, 90));
      expect(copy.restoreWidth, 300);
      expect(copy.restoreHeight, 400);
      expect(copy.hiddenKeys.toList(), ['a', 'b|Foo']);
      expect(copy.severityFilter, {
        IssueSeverity.critical,
        IssueSeverity.warning,
      });
      expect(copy.toJson(), state.toJson());
    });

    test('only schemaVersion yields defaults', () {
      final state = OverlayUiState.fromJson({'schemaVersion': 1});
      expect(state.triggerAnchor, isNull);
      expect(state.cardOffset, isNull);
      expect(state.cardWidth, isNull);
      expect(state.cardHeight, isNull);
      expect(state.windowState, CardWindowState.normal);
      expect(state.hiddenKeys, isEmpty);
      expect(state.severityFilter, IssueSeverity.values.toSet());
      expect(state.dashboardOpen, isFalse);
    });

    test('dashboardOpen is session only', () {
      final state = OverlayUiState()..dashboardOpen = true;
      expect(state.toJson().containsKey('dashboardOpen'), isFalse);
      state.loadJson({'schemaVersion': 1});
      expect(state.dashboardOpen, isTrue);
    });

    test('unknown keys are ignored', () {
      final state = OverlayUiState.fromJson({
        'schemaVersion': 1,
        'futureField': {'x': 1},
        'hiddenKeys': ['k'],
      });
      expect(state.hiddenKeys, {'k'});
    });

    test('missing, non-int or newer schemaVersion throws and changes '
        'nothing', () {
      final state = OverlayUiState()..hide('kept');
      for (final bad in <Map<String, Object?>>[
        {},
        {'schemaVersion': '1'},
        {'schemaVersion': 2},
        {'schemaVersion': 0},
      ]) {
        expect(() => state.loadJson(bad), throwsFormatException);
      }
      expect(state.hiddenKeys, {'kept'});
    });

    test('wrong field types fall back to defaults', () {
      final state = OverlayUiState.fromJson({
        'schemaVersion': 1,
        'triggerAnchor': {'edge': 'top', 'fraction': 0.5},
        'cardOffset': {'dx': 'a', 'dy': 2},
        'cardWidth': -5,
        'cardHeight': 'tall',
        'windowState': 7,
        'hiddenKeys': 'not a list',
        'severityFilter': ['nope'],
      });
      expect(state.triggerAnchor, isNull);
      expect(state.cardOffset, isNull);
      expect(state.cardWidth, isNull);
      expect(state.cardHeight, isNull);
      expect(state.windowState, CardWindowState.normal);
      expect(state.hiddenKeys, isEmpty);
      expect(state.severityFilter, IssueSeverity.values.toSet());
    });

    test('loading keeps only the newest maxHiddenKeys keys', () {
      final keys = [for (var i = 0; i < 250; i++) 'k$i'];
      final state = OverlayUiState.fromJson({
        'schemaVersion': 1,
        'hiddenKeys': keys,
      });
      expect(state.hiddenKeys.length, OverlayUiState.maxHiddenKeys);
      expect(state.hiddenKeys.first, 'k50');
      expect(state.hiddenKeys.last, 'k249');
    });

    test('anchor fraction is clamped to [0, 1]', () {
      final state = OverlayUiState.fromJson({
        'schemaVersion': 1,
        'triggerAnchor': {'edge': 'right', 'fraction': 3.5},
      });
      expect(state.triggerAnchor, (edge: TriggerEdge.right, fraction: 1.0));
      state.triggerAnchor = (edge: TriggerEdge.left, fraction: -2);
      expect(state.triggerAnchor!.fraction, 0.0);
    });

    test('loadJson keeps fields changed since construction', () {
      final state = OverlayUiState()
        ..triggerAnchor = (edge: TriggerEdge.left, fraction: 0.2)
        ..setCardGeometry(
          offset: const Offset(10, 20),
          width: 300,
          height: 400,
          windowState: CardWindowState.normal,
        );
      state.loadJson({
        'schemaVersion': 1,
        'triggerAnchor': {'edge': 'right', 'fraction': 0.9},
        'cardOffset': {'dx': 1, 'dy': 2},
        'cardWidth': 500,
        'windowState': 'maximized',
        'hiddenKeys': ['loaded'],
        'severityFilter': ['critical'],
      });
      expect(state.triggerAnchor, (edge: TriggerEdge.left, fraction: 0.2));
      expect(state.cardOffset, const Offset(10, 20));
      expect(state.cardWidth, 300);
      expect(state.windowState, CardWindowState.normal);
      // Untouched fields are loaded.
      expect(state.hiddenKeys, {'loaded'});
      expect(state.severityFilter, {IssueSeverity.critical});
    });

    test('loadJson merges hidden keys hidden before it, newest last', () {
      final state = OverlayUiState()
        ..hide('a')
        ..hide('b');
      state.loadJson({
        'schemaVersion': 1,
        'hiddenKeys': ['b', 'x', 'y'],
      });
      expect(state.hiddenKeys.toList(), ['x', 'y', 'a', 'b']);
    });

    test('a non-finite anchor fraction clears the anchor', () {
      final state = OverlayUiState()
        ..triggerAnchor = (edge: TriggerEdge.left, fraction: 0.5)
        ..triggerAnchor = (edge: TriggerEdge.left, fraction: double.nan);
      expect(state.triggerAnchor, isNull);
    });
  });

  group('OverlayUiState hidden keys', () {
    test('hiding past the cap evicts the oldest key', () {
      final state = OverlayUiState();
      for (var i = 0; i <= OverlayUiState.maxHiddenKeys; i++) {
        state.hide('k$i');
      }
      expect(state.hiddenKeys.length, OverlayUiState.maxHiddenKeys);
      expect(state.hiddenKeys.contains('k0'), isFalse);
      expect(state.hiddenKeys.last, 'k${OverlayUiState.maxHiddenKeys}');
    });

    test('re-hiding a key makes it the newest', () {
      final state = OverlayUiState()
        ..hide('a')
        ..hide('b')
        ..hide('a');
      expect(state.hiddenKeys.toList(), ['b', 'a']);
    });

    test('unhide and restoreAll notify only on change', () {
      final state = OverlayUiState()..hide('a');
      var notified = 0;
      state.addListener(() => notified++);
      expect(state.unhide('missing'), isFalse);
      expect(notified, 0);
      expect(state.unhide('a'), isTrue);
      expect(notified, 1);
      state.restoreAll();
      expect(notified, 1);
    });

    test('hide key adds the widget name when present', () {
      expect(OverlayUiState.hideKeyFor(_issue('x')), 'x');
      expect(
        OverlayUiState.hideKeyFor(_issue('x', widgetName: 'Foo')),
        'x|Foo',
      );
      expect(
        OverlayUiState.hideKeyFor(_issue('x', withStableId: false)),
        'title x',
      );
    });
  });

  group('OverlayUiState severity filter', () {
    test('the last enabled severity cannot be turned off', () {
      final state = OverlayUiState();
      expect(state.toggleSeverity(IssueSeverity.ok), isTrue);
      expect(state.toggleSeverity(IssueSeverity.warning), isTrue);
      expect(state.toggleSeverity(IssueSeverity.critical), isFalse);
      expect(state.severityFilter, {IssueSeverity.critical});
      state.resetSeverityFilter();
      expect(state.isSeverityFiltered, isFalse);
    });

    test(
      'visibleIssues filters severity before collapsing and hides after',
      () {
        final root = _issue('root', severity: IssueSeverity.critical);
        final child = _issue('child', rootCauseIds: ['root']);
        final other = _issue('other');
        final state = OverlayUiState();

        expect(state.visibleIssues([root, child, other]), [root, other]);

        // Critical off: the child of the filtered-out root surfaces.
        state.toggleSeverity(IssueSeverity.critical);
        expect(state.visibleIssues([root, child, other]), [child, other]);

        // Hiding the root takes its collapsed child with it.
        state
          ..resetSeverityFilter()
          ..hide('root');
        expect(state.visibleIssues([root, child, other]), [other]);
        state.unhide('root');
        expect(state.visibleIssues([root, child, other]), [root, other]);
      },
    );
  });
}
