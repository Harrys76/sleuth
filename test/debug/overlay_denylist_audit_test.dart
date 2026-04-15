// v0.15.1 hotfix CI audit — KDD-10 Framework widget contamination.
//
// The `_frameworkWidgetDenyList` in `debug_instrumentation_coordinator.dart`
// must stay in lockstep with the widgets Sleuth's own overlay actually uses,
// or the self-measurement bug fixed in v0.15.1 silently returns. This test
// enforces parity by reading the real `lib/src/ui/**/*.dart` source tree and
// comparing what's there against the denylist.
//
// Two checks run:
//
// 1. **Overlay classes**: every `class X extends (Stateless|Stateful|
//    Inherited)Widget` defined under `lib/src/ui/` MUST appear in the
//    denylist. Adding a new overlay widget without adding it to the denylist
//    re-exposes Sleuth to self-measurement.
//
// 2. **Framework widgets**: a curated set of high-traffic Flutter framework
//    widgets is checked against the UI source — any that appear as a
//    constructor call MUST also be in the denylist. This catches the case
//    where someone wraps an overlay in, say, an `AnimatedContainer` that
//    wasn't previously used.
//
// When this test fails, do NOT silence it by editing the test — fix the
// denylist in `debug_instrumentation_coordinator.dart` and re-run.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';

/// High-traffic Flutter framework widgets that, if used anywhere under
/// `lib/src/ui/`, must be in `_frameworkWidgetDenyList`. This list is the
/// tripwire: if you introduce a new kind of framework widget into the
/// overlay (say, `StreamBuilder` or `AnimatedSwitcher`), add it here AND
/// to the denylist so future audits keep parity.
const _frameworkCandidates = <String>{
  'Align',
  'AnimatedBuilder',
  'AnimatedContainer',
  'AnimatedCrossFade',
  'AnimatedDefaultTextStyle',
  'AnimatedOpacity',
  'AnimatedPadding',
  'AnimatedPositioned',
  'AnimatedRotation',
  'AnimatedScale',
  'AnimatedSize',
  'AnimatedSlide',
  'AnimatedSwitcher',
  'AppBar',
  'AspectRatio',
  'BackdropFilter',
  'Baseline',
  'Builder',
  'Card',
  'Center',
  'Checkbox',
  'Chip',
  'CircularProgressIndicator',
  'ClipOval',
  'ClipPath',
  'ClipRRect',
  'ClipRect',
  'ColoredBox',
  'Column',
  'ConstrainedBox',
  'Container',
  'CustomPaint',
  'CustomScrollView',
  'DecoratedBox',
  'DefaultTextEditingShortcuts',
  'DefaultTextStyle',
  'Directionality',
  'Divider',
  'ElevatedButton',
  'Expanded',
  'FadeTransition',
  'FilledButton',
  'FittedBox',
  'Flex',
  'Flexible',
  'FloatingActionButton',
  'Focus',
  'FocusScope',
  'FutureBuilder',
  'GestureDetector',
  'GridView',
  'Hero',
  'Icon',
  'IconButton',
  'IgnorePointer',
  'InkResponse',
  'InkWell',
  'IntrinsicHeight',
  'IntrinsicWidth',
  'LayoutBuilder',
  'LimitedBox',
  'LinearProgressIndicator',
  'ListTile',
  'ListView',
  'Listener',
  'Localizations',
  'Material',
  'MouseRegion',
  'NotificationListener',
  'Offstage',
  'Opacity',
  'OutlinedButton',
  'Overlay',
  'Padding',
  'PageView',
  'Placeholder',
  'PopScope',
  'Positioned',
  'RefreshIndicator',
  'RepaintBoundary',
  'RichText',
  'RotatedBox',
  'Row',
  'SafeArea',
  'Scaffold',
  'Scrollbar',
  'SelectableText',
  'Semantics',
  'ShaderMask',
  'SingleChildScrollView',
  'SizedBox',
  'SlideTransition',
  'SnackBar',
  'Spacer',
  'Stack',
  'StatefulBuilder',
  'StreamBuilder',
  'TabBar',
  'TabBarView',
  'Text',
  'TextButton',
  'TextField',
  'Theme',
  'Tooltip',
  'Transform',
  'TweenAnimationBuilder',
  'ValueListenableBuilder',
  'Wrap',
};

/// Regex matching a class definition that extends a widget base class.
/// Captures the class name in group 1.
///
/// The optional `(?:<[\w,\s<>?]*>)?` clause tolerates a generic parameter
/// list on the class being declared (e.g.
/// `class _FooCard<T extends Bar> extends StatelessWidget`). Without it,
/// any future overlay widget that takes a type parameter would silently
/// fall out of the audit set and re-expose KDD-10 self-measurement. The
/// character class is intentionally permissive (`[\w,\s<>?]`) so nested
/// generic bounds still match.
final _overlayClassRegex = RegExp(
    r'^class\s+(\w+)(?:<[\w,\s<>?]*>)?\s+extends\s+(?:Stateless|Stateful|Inherited)Widget',
    multiLine: true);

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

List<File> _uiSourceFiles() {
  final root = _packageRoot();
  final uiDir = Directory('${root.path}/lib/src/ui');
  if (!uiDir.existsSync()) {
    fail('lib/src/ui not found at ${uiDir.path}');
  }
  return uiDir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();
}

void main() {
  group('overlay denylist audit (KDD-10 / v0.15.1)', () {
    late List<File> uiFiles;
    late Map<File, String> uiSources;

    setUpAll(() {
      uiFiles = _uiSourceFiles();
      uiSources = {
        for (final f in uiFiles) f: f.readAsStringSync(),
      };
      expect(uiFiles, isNotEmpty,
          reason: 'lib/src/ui/ must contain at least one .dart file');
    });

    test('_overlayClassRegex captures generic class declarations', () {
      // Regression guard: if the regex ever stops matching generic class
      // declarations, a future overlay widget like
      // `class _FooCard<T extends Bar> extends StatelessWidget` will silently
      // vanish from the audit set and re-expose KDD-10 self-measurement.
      const fixture = '''
class _NonGeneric extends StatelessWidget {}
class _WithGeneric<T> extends StatefulWidget {}
class _WithBound<T extends Bar> extends StatelessWidget {}
class _WithNested<T extends Bar<Baz>> extends StatelessWidget {}
class _WithMulti<A, B extends Foo> extends InheritedWidget {}
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
        }),
        reason: '_overlayClassRegex must match both plain and generic '
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

      expect(overlayClasses, isNotEmpty,
          reason: 'Expected to find at least one overlay widget class');

      final denyList =
          DebugInstrumentationCoordinator.debugFrameworkWidgetDenyList;
      final missing = overlayClasses.difference(denyList);

      expect(
        missing,
        isEmpty,
        reason: 'These Sleuth overlay widget classes are NOT in '
            '`_frameworkWidgetDenyList`, so Sleuth will self-measure them '
            'in profile mode (KDD-10). Add them to the denylist in '
            'lib/src/debug/debug_instrumentation_coordinator.dart:\n'
            '  ${missing.toList()..sort()}',
      );
    });

    test(
        'every framework widget used under lib/src/ui/ is in the '
        'denylist', () {
      final denyList =
          DebugInstrumentationCoordinator.debugFrameworkWidgetDenyList;
      final usedButNotDenied = <String>{};

      for (final candidate in _frameworkCandidates) {
        final usedSomewhere = uiSources.values
            .any((src) => _isWidgetConstructorUsed(candidate, src));
        if (usedSomewhere && !denyList.contains(candidate)) {
          usedButNotDenied.add(candidate);
        }
      }

      expect(
        usedButNotDenied,
        isEmpty,
        reason: 'These Flutter framework widgets are used inside '
            'lib/src/ui/ but are NOT in `_frameworkWidgetDenyList`. Add '
            'them to the denylist in '
            'lib/src/debug/debug_instrumentation_coordinator.dart:\n'
            '  ${usedButNotDenied.toList()..sort()}',
      );
    });

    test(
        'every framework entry in the denylist still corresponds to a UI '
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
        final used =
            uiSources.values.any((src) => _isWidgetConstructorUsed(entry, src));
        if (!used) staleFrameworkEntries.add(entry);
      }

      expect(
        staleFrameworkEntries,
        isEmpty,
        reason: 'These framework-widget denylist entries are no longer '
            'used anywhere under lib/src/ui/. If the widget was '
            'intentionally removed from the overlay, remove it from '
            '`_frameworkWidgetDenyList` too so the denylist stays '
            'minimal and auditable:\n'
            '  ${staleFrameworkEntries.toList()..sort()}',
      );
    });
  });
}
