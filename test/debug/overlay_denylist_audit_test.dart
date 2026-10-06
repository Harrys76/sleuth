// IDE analyzer false-positive: dart:core RegExp uses @Deprecated.implement
// (fires only on subclassing). Remove when analyzer-server recognizes the
// implement-only kind.
// ignore_for_file: deprecated_member_use
// v0.15.1 hotfix CI audit: framework and overlay widgets must not be
// counted as user widgets in profile mode.
//
// The `_frameworkWidgetDenyList` in `debug_instrumentation_coordinator.dart`
// must stay in lockstep with the widgets Sleuth's own overlay actually uses,
// or the self-measurement bug fixed in v0.15.1 silently returns. This test
// enforces parity by reading the real `lib/src/ui/**/*.dart` source tree and
// comparing what's there against the denylist.
//
// Two checks run:
//
// 1. **Overlay classes**: every `class X extends …Widget` defined under
//    `lib/src/ui/` (stateless, stateful, inherited, render-object or any
//    other `*Widget` base) MUST appear in the denylist. Adding a new
//    overlay widget without adding it to the denylist re-exposes Sleuth to
//    self-measurement.
//
// 2. **Framework widgets**: every capitalised constructor call under
//    `lib/src/ui/` (comments and string literals stripped) that does not
//    name a class defined in `lib/` MUST be either in the denylist (a
//    widget) or in [_nonWidgetTypes] (a value, controller or other
//    non-widget type). A new framework widget in the overlay fails the
//    audit until it is classified.
//
// When this test fails, do NOT silence it by editing the test — fix the
// denylist in `debug_instrumentation_coordinator.dart` and re-run.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';

/// Types constructed under `lib/src/ui/` that are not widgets, so the
/// framework-widget check skips them. A name missing from both this set
/// and the denylist fails the audit: classify it here only when it is not
/// a widget.
const _nonWidgetTypes = <String>{
  'Alignment',
  'AlwaysStoppedAnimation',
  'AnimationController',
  'Border',
  'BorderSide',
  'BoxConstraints',
  'BoxDecoration',
  'BoxShadow',
  'ClipboardData',
  'Color',
  'CurvedAnimation',
  'CustomSemanticsAction',
  'Duration',
  'FocusNode',
  'FocusScopeNode',
  'FocusSemanticEvent',
  'FormatException',
  'Function',
  'GlobalKey',
  'HttpException',
  'InputDecoration',
  'IntTween',
  'Interval',
  'LinearGradient',
  'LinkedHashSet',
  'Locale',
  'ObjectKey',
  'Offset',
  'OutlineInputBorder',
  'OverlayEntry',
  'Paint',
  'Path',
  'RegExp',
  'RoundedRectangleBorder',
  'ScrollController',
  'Size',
  'StringBuffer',
  'TextEditingController',
  'TextPainter',
  'TextSpan',
  'TextStyle',
  'Timer',
  'Tween',
  'UnmodifiableSetView',
  'ValueKey',
  'ValueNotifier',
};

/// Framework widgets apps use widely. Denylisting one would drop the app's
/// own rebuilds of it from the profile drain, so the overlay uses
/// Sleuth-named equivalents instead and these names stay off the list.
const _appOwnedFrameworkWidgets = <String>{
  'AnimatedContainer',
  'AnimatedSwitcher',
  'CustomSingleChildLayout',
  'ListenableBuilder',
  'MergeSemantics',
};

/// Regex matching a class definition that extends a widget base class.
/// Captures the class name in group 1.
///
/// The optional `(?:<[\w,\s<>?]*>)?` clause tolerates a generic parameter
/// list on the class being declared (e.g.
/// `class _FooCard<T extends Bar> extends StatelessWidget`). Without it,
/// any future overlay widget that takes a type parameter would silently
/// fall out of the audit set and Sleuth would measure itself again. The
/// character class is intentionally permissive (`[\w,\s<>?]`) so nested
/// generic bounds still match.
final _overlayClassRegex = RegExp(
  r'^class\s+(\w+)(?:<[\w,\s<>?]*>)?\s+extends\s+\w*Widget\b',
  multiLine: true,
);

/// A class, enum, typedef or extension type declared at the top level.
final _declarationRegex = RegExp(
  r'^(?:(?:abstract|base|final|interface|sealed|mixin)\s+)*'
  r'(?:class|enum|typedef|extension\s+type)\s+(\w+)',
  multiLine: true,
);

/// A capitalised name called as a constructor: `Name(` or `Name<…>(`,
/// not after an identifier character, `.` or `$`.
final _constructorCallRegex = RegExp(
  r'(?<![A-Za-z0-9_.$])([A-Z]\w*)(?:<[^()]*>)?\s*\(',
);

/// [source] without comments and string literal contents, so prose and
/// UI text such as `'Hide (3)'` do not read as constructor calls.
String _stripCommentsAndStrings(String source) => source
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r"'''.*?'''", dotAll: true), '""')
    .replaceAll(RegExp(r'""".*?"""', dotAll: true), '""')
    .replaceAll(RegExp(r'//[^\n]*'), '')
    .replaceAll(RegExp(r"r?'(?:\\.|[^'\\\n])*'"), '""')
    .replaceAll(RegExp(r'r?"(?:\\.|[^"\\\n])*"'), '""');

/// Returns `true` when [name] is used as a widget constructor in [source].
/// A constructor call looks like `Name(` or `Name<…>(`. We exclude method
/// chains (`.Name(`) and type annotations immediately followed by an
/// identifier (`Name myVar`), so `Text.rich(…)` and `final Text t;` don't
/// count.
bool _isWidgetConstructorUsed(String name, String source) {
  // Match on word boundary so 'Text' does not match 'TextField'. The
  // character class `[^A-Za-z0-9_.]` excludes identifier continuation and
  // method-chain dot, so `widget.Text` and `TextStyle` are both rejected.
  final pattern = RegExp(
    r'(?<![A-Za-z0-9_.])' + RegExp.escape(name) + r'(?:<[^()]*>)?\s*\(',
  );
  return pattern.hasMatch(source);
}

/// Locate the package root (containing `pubspec.yaml`) by walking up from
/// the test's current working directory. `flutter test` sets cwd to the
/// package root, but this keeps the test robust if that ever changes.
Directory _packageRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('Could not locate package root from ${Directory.current.path}');
    }
    dir = parent;
  }
}

List<File> _dartFilesUnder(String relative) {
  final root = _packageRoot();
  final dir = Directory('${root.path}/$relative');
  if (!dir.existsSync()) {
    fail('$relative not found at ${dir.path}');
  }
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}

List<File> _uiSourceFiles() => _dartFilesUnder('lib/src/ui');

void main() {
  group('overlay denylist audit (v0.15.1)', () {
    late List<File> uiFiles;
    late Map<File, String> uiSources;

    setUpAll(() {
      uiFiles = _uiSourceFiles();
      uiSources = {for (final f in uiFiles) f: f.readAsStringSync()};
      expect(
        uiFiles,
        isNotEmpty,
        reason: 'lib/src/ui/ must contain at least one .dart file',
      );
    });

    test('_overlayClassRegex captures generic class declarations', () {
      // Regression guard: if the regex ever stops matching generic class
      // declarations, a future overlay widget like
      // `class _FooCard<T extends Bar> extends StatelessWidget` will silently
      // vanish from the audit set and Sleuth would measure itself again.
      const fixture = '''
class _NonGeneric extends StatelessWidget {}
class _WithGeneric<T> extends StatefulWidget {}
class _WithBound<T extends Bar> extends StatelessWidget {}
class _WithNested<T extends Bar<Baz>> extends StatelessWidget {}
class _WithMulti<A, B extends Foo> extends InheritedWidget {}
class _Blocker extends SingleChildRenderObjectWidget {}
class _Slotted extends SlottedMultiChildRenderObjectWidget<_Slot, RenderBox> {}
class _NotAWidget extends ChangeNotifier {}
class _WidgetLike extends WidgetsBindingObserver {}
''';
      final names = _overlayClassRegex
          .allMatches(fixture)
          .map((m) => m.group(1)!)
          .toSet();
      expect(
        names,
        equals({
          '_NonGeneric',
          '_WithGeneric',
          '_WithBound',
          '_WithNested',
          '_WithMulti',
          '_Blocker',
          '_Slotted',
        }),
        reason:
            '_overlayClassRegex must match both plain and generic '
            'class declarations or the audit will miss future overlay '
            'widgets that take type parameters.',
      );
    });

    test('every overlay widget class is in the denylist', () {
      final overlayClasses = <String>{};
      for (final entry in uiSources.entries) {
        for (final match in _overlayClassRegex.allMatches(entry.value)) {
          overlayClasses.add(match.group(1)!);
        }
      }

      expect(
        overlayClasses,
        isNotEmpty,
        reason: 'Expected to find at least one overlay widget class',
      );

      final denyList =
          DebugInstrumentationCoordinator.debugFrameworkWidgetDenyList;
      final missing = overlayClasses.difference(denyList);

      expect(
        missing,
        isEmpty,
        reason:
            'These Sleuth overlay widget classes are NOT in '
            '`_frameworkWidgetDenyList`, so Sleuth will self-measure them '
            'in profile mode. Add them to the denylist in '
            'lib/src/debug/debug_instrumentation_coordinator.dart:\n'
            '  ${missing.toList()..sort()}',
      );
    });

    test('constructor calls in comments and strings are ignored', () {
      const fixture = '''
// A Hide(3) note.
final a = Text('Hide (3)');
final b = Row(children: [Icon(x)]);
''';
      final names = _constructorCallRegex
          .allMatches(_stripCommentsAndStrings(fixture))
          .map((m) => m.group(1)!)
          .toSet();
      expect(names, {'Text', 'Row', 'Icon'});
    });

    test('every framework widget used under lib/src/ui/ is in the '
        'denylist', () {
      final denyList =
          DebugInstrumentationCoordinator.debugFrameworkWidgetDenyList;
      final declaredInLib = <String>{
        for (final f in _dartFilesUnder('lib'))
          for (final m in _declarationRegex.allMatches(f.readAsStringSync()))
            m.group(1)!,
      };
      final called = <String>{
        for (final src in uiSources.values)
          for (final m in _constructorCallRegex.allMatches(
            _stripCommentsAndStrings(src),
          ))
            m.group(1)!,
      };
      expect(called, contains('Text'));

      final unclassified =
          called
              .difference(declaredInLib)
              .difference(denyList)
              .difference(_nonWidgetTypes)
              .toList()
            ..sort();
      expect(
        unclassified,
        isEmpty,
        reason:
            'These types are constructed inside lib/src/ui/ but are '
            'neither in `_frameworkWidgetDenyList` nor known non-widget '
            'types. Add a widget to the denylist in '
            'lib/src/debug/debug_instrumentation_coordinator.dart; add a '
            'non-widget type to `_nonWidgetTypes` in this test:\n'
            '  $unclassified',
      );

      final staleNonWidgets = _nonWidgetTypes.difference(called).toList()
        ..sort();
      expect(
        staleNonWidgets,
        isEmpty,
        reason: 'No longer constructed under lib/src/ui/: $staleNonWidgets',
      );
    });

    test('app-owned framework widgets are neither denylisted nor used by '
        'the overlay', () {
      final denyList =
          DebugInstrumentationCoordinator.debugFrameworkWidgetDenyList;
      expect(denyList.intersection(_appOwnedFrameworkWidgets), isEmpty);
      final used = <String>{
        for (final name in _appOwnedFrameworkWidgets)
          if (uiSources.values.any(
            (src) => _isWidgetConstructorUsed(name, src),
          ))
            name,
      };
      expect(
        used,
        isEmpty,
        reason:
            'The overlay must use a Sleuth-named class instead of these '
            'widgets (see SleuthListenableBuilder):\n  $used',
      );
    });

    test('every framework entry in the denylist still corresponds to a UI '
        'source usage (catches stale entries)', () {
      // An overlay-widget-class prefix filter: if an entry looks like a
      // Sleuth-internal widget class (either matches an overlay class or
      // starts with underscore followed by uppercase), skip the framework
      // usage audit for it. Framework widgets never start with `_`.
      final overlayClasses = <String>{
        for (final entry in uiSources.entries)
          for (final match in _overlayClassRegex.allMatches(entry.value))
            match.group(1)!,
      };

      final denyList =
          DebugInstrumentationCoordinator.debugFrameworkWidgetDenyList;
      final staleFrameworkEntries = <String>{};

      for (final entry in denyList) {
        if (entry.startsWith('_')) continue; // private overlay class
        if (overlayClasses.contains(entry)) continue; // public overlay class
        final used = uiSources.values.any(
          (src) => _isWidgetConstructorUsed(entry, src),
        );
        if (!used) staleFrameworkEntries.add(entry);
      }

      expect(
        staleFrameworkEntries,
        isEmpty,
        reason:
            'These framework-widget denylist entries are no longer '
            'used anywhere under lib/src/ui/. If the widget was '
            'intentionally removed from the overlay, remove it from '
            '`_frameworkWidgetDenyList` too so the denylist stays '
            'minimal and auditable:\n'
            '  ${staleFrameworkEntries.toList()..sort()}',
      );
    });
  });
}
