import 'package:flutter/cupertino.dart'
    show CupertinoActivityIndicator, CupertinoPageScaffold;
import 'package:flutter/material.dart';

import 'type_name_cache.dart';

/// Checks for Material and Cupertino widgets that hold whether the widget
/// comes from the SDK libraries or from the `material_ui` / `cupertino_ui`
/// packages.
///
/// The packages define distinct types with the SDK's class names, so an
/// `is Scaffold` check against the SDK misses a migrated app. Each check
/// accepts the SDK type, or a widget whose class has the same name. Class
/// names survive profile builds unless the build passes `--obfuscate`; in
/// an obfuscated profile build no name check matches, so `material_ui`
/// widgets count as the app's and every blur's sigma is unknown.
///
/// A name check matches the exact class only: an app subclass of a
/// `material_ui` widget (`MySpinner extends CircularProgressIndicator`) is
/// not recognised, while the SDK's `is` checks accept subclasses.
///
/// A name check also matches an app class that reuses a framework name: an
/// app's own `AppBar`, `TabBar`, `TabBarView` or `Material` counts as the
/// framework's, so setState scope never reports it. Dart has no runtime
/// library information to tell the two apart. [isScaffoldElement] also
/// requires the framework's state class, which keeps an app widget named
/// `Scaffold` (with any state class but `ScaffoldState`) from moving the
/// scan root; `_CupertinoPageScaffoldState` is the name an IDE generates,
/// so an app `CupertinoPageScaffold` can still pass.

String _name(Widget widget) => baseTypeName(typeNameCache.lookup(widget));

/// A Material or Cupertino page scaffold at [element]. A name match also
/// needs the framework's state class (`ScaffoldState`,
/// `_CupertinoPageScaffoldState`), so an app widget that is only called
/// `Scaffold` is not taken for the page.
bool isScaffoldElement(Element element) {
  final widget = element.widget;
  if (widget is Scaffold || widget is CupertinoPageScaffold) return true;
  if (element is! StatefulElement) return false;
  final name = _name(widget);
  final String expectedState;
  if (name == 'Scaffold') {
    expectedState = 'ScaffoldState';
  } else if (name == 'CupertinoPageScaffold') {
    expectedState = '_CupertinoPageScaffoldState';
  } else {
    return false;
  }
  return baseTypeName(typeNameCache.lookupType(element.state.runtimeType)) ==
      expectedState;
}

/// Material `TabBarView`.
bool isTabBarView(Widget widget) =>
    widget is TabBarView || _name(widget) == 'TabBarView';

/// Material `TabBar`.
bool isTabBar(Widget widget) => widget is TabBar || _name(widget) == 'TabBar';

/// Material `Material`.
bool isMaterial(Widget widget) =>
    widget is Material || _name(widget) == 'Material';

/// Material `InputDecorator`.
bool isInputDecorator(Widget widget) =>
    widget is InputDecorator || _name(widget) == 'InputDecorator';

const _progressIndicatorNames = {
  'LinearProgressIndicator',
  'CircularProgressIndicator',
  'RefreshProgressIndicator',
};

/// A Material progress indicator. The name check lists the concrete
/// classes, because a name cannot see the abstract `ProgressIndicator`
/// base.
bool isProgressIndicator(Widget widget) =>
    widget is ProgressIndicator ||
    _progressIndicatorNames.contains(_name(widget));

/// Cupertino `CupertinoActivityIndicator`.
bool isCupertinoActivityIndicator(Widget widget) =>
    widget is CupertinoActivityIndicator ||
    _name(widget) == 'CupertinoActivityIndicator';

/// Material `AnimatedIcon`.
bool isAnimatedIcon(Widget widget) =>
    widget is AnimatedIcon || _name(widget) == 'AnimatedIcon';

/// Class names of the Material widgets above that
/// `SetStateScopeDetector.isFrameworkWidget` treats as framework owners.
/// `Scaffold` is not one: [isScaffoldElement] checks it with its state
/// class, so an app widget named `Scaffold` stays the app's.
const movedFrameworkOwnerNames = {'AppBar', 'Material', 'TabBarView', 'TabBar'};

/// Cupertino widgets that draw a backdrop blur of their own, with the most
/// hops allowed from the `BackdropFilter` element to the widget. Measured
/// on Flutter 3.32.8 and 3.47.6, which build the same trees:
/// `CupertinoTabBar` 2, `CupertinoPopupSurface` 2 (alert dialogs),
/// `CupertinoNavigationBar` 10, `CupertinoSliverNavigationBar` 14,
/// `CupertinoActionSheet` 16.
const _blurOwnerBudgets = {
  'CupertinoTabBar': 3,
  'CupertinoPopupSurface': 3,
  'CupertinoNavigationBar': 11,
  'CupertinoSliverNavigationBar': 15,
  'CupertinoActionSheet': 17,
};

/// The Cupertino widget that owns the `BackdropFilter` at [element], or
/// null when the blur is the app's own. Matched by name, so the
/// `cupertino_ui` copies match too.
String? cupertinoBlurOwner(Element element) {
  String? owner;
  var hops = 0;
  element.visitAncestorElements((ancestor) {
    hops++;
    // The owner's own blur is the nearest one under it; a blur below
    // another BackdropFilter is the app's, such as an app filter inside a
    // CupertinoPopupSurface built with isSurfacePainted: false.
    if (ancestor.widget is BackdropFilter) return false;
    final name = _name(ancestor.widget);
    final budget = _blurOwnerBudgets[name];
    if (budget != null && hops <= budget) {
      owner = name;
      return false;
    }
    return hops < 17;
  });
  return owner;
}

/// The `material_ui` and `cupertino_ui` source paths: hosted
/// (`material_ui-1.6.0/lib/`), git checkouts named by commit
/// (`material_ui-<40-hex sha>/lib/`), path dependencies in a directory of
/// the package's name (`material_ui/lib/`), or package URIs. A path
/// dependency in a renamed directory is not recognised, because the
/// creation location is a file path and carries no package name.
final _movedFrameworkFile = RegExp(
  r'(^|[/\\])(material_ui|cupertino_ui)(-(\d[^/\\]*|[0-9a-f]{40}))?'
  r'[/\\]lib[/\\]|'
  r'^package:(material_ui|cupertino_ui)/',
);

/// The file that created [widget], from its widget-creation location, or
/// null when the build does not track widget creation.
String? widgetCreationFile(Widget widget) {
  final properties = InspectorSerializationDelegate(
    service: WidgetInspectorService.instance,
  ).additionalNodeProperties(widget.toDiagnosticsNode());
  final location = properties['creationLocation'];
  if (location is! Map) return null;
  final file = location['file'];
  return file is String ? file : null;
}

/// Whether [file], a widget-creation path, lies in `material_ui` or
/// `cupertino_ui`.
bool isMovedFrameworkFile(String file) => _movedFrameworkFile.hasMatch(file);

/// Whether code in `material_ui` or `cupertino_ui` created [widget].
///
/// Flutter's `debugIsWidgetLocalCreation` counts every widget created
/// outside `packages/flutter/` as the app's until DevTools sets the
/// project's root directories. Without this check, the widgets those
/// packages build inside their own widgets (the `AnimatedBuilder` in a
/// progress indicator) would count as app widgets.
///
/// This reads the location through `InspectorSerializationDelegate`,
/// which Flutter marks `@visibleForTesting`, because it is the only API
/// that returns a widget's creation file. If that API changes, this
/// returns false (the caller catches errors) and those widgets count as
/// the app's again. Callers cache the answer per widget instance. False
/// when the build does not track widget creation.
bool createdInMovedFrameworkPackage(Widget widget) {
  final file = widgetCreationFile(widget);
  return file != null && isMovedFrameworkFile(file);
}
