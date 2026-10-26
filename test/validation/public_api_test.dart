// Pins Sleuth's public top-level names: every export in the two public
// libraries has a `show` list, and the shown names plus the barrel's own
// declarations match test/validation/_fixtures/public_api_1_0_0.txt.
//
// A new export fails here until the fixture lists it, and so does a
// removed one. Only top-level names are pinned: the dart_apitool CI job
// checks members once 1.0.0 is published, and review does until then.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _libraries = ['sleuth.dart', 'validation.dart'];
const _fixture = 'test/validation/_fixtures/public_api_1_0_0.txt';

/// Source of [path] with line comments removed, so a commented-out export
/// is not read as one.
String _code(String path) => File(
  path,
).readAsLinesSync().where((l) => !l.trimLeft().startsWith('//')).join('\n');

final _export = RegExp(r"export\s+'([^']+)'([^;]*);");

/// Each export of [library]: its URI and its shown names, null when the
/// export has no `show` list.
List<(String, List<String>?)> _exports(String library) => [
  for (final m in _export.allMatches(_code('lib/$library')))
    (m.group(1)!, _shown(m.group(2)!)),
];

List<String>? _shown(String combinators) {
  final show = RegExp(r'^\s*show\s+([\w\s,]+)$').firstMatch(combinators);
  if (show == null) return null;
  return [
    for (final name in show.group(1)!.split(','))
      if (name.trim().isNotEmpty) name.trim(),
  ];
}

/// Public top-level names declared in [library] itself.
Set<String> _declared(String library) => {
  for (final m in RegExp(
    r'^(?:(?:abstract|base|final|interface|sealed|mixin)\s+)*'
    r'(?:class|enum|mixin|typedef|extension(?:\s+type)?)\s+([A-Za-z]\w*)',
    multiLine: true,
  ).allMatches(_code('lib/$library')))
    m.group(1)!,
};

/// `library name` lines for every public top-level name.
Set<String> _surface() => {
  for (final library in _libraries) ...{
    for (final (_, shown) in _exports(library))
      for (final name in shown ?? const <String>[]) '$library $name',
    for (final name in _declared(library)) '$library $name',
  },
};

Set<String> _pinned() => {
  for (final line in File(_fixture).readAsLinesSync())
    if (line.trim().isNotEmpty && !line.startsWith('#')) line.trim(),
};

void main() {
  test('every export of the public libraries has a show list', () {
    final missing = [
      for (final library in _libraries)
        for (final (uri, shown) in _exports(library))
          if (shown == null) '$library: $uri',
    ];
    expect(missing, isEmpty, reason: 'Add a `show` list to each export.');
  });

  test('the public names match the pinned list', () {
    final surface = _surface();
    final pinned = _pinned();
    expect(
      surface.difference(pinned),
      isEmpty,
      reason: 'New public names: add them to $_fixture.',
    );
    expect(
      pinned.difference(surface),
      isEmpty,
      reason: 'Pinned names no longer exported: removing one is breaking.',
    );
  });

  test('no name is exported from both libraries', () {
    final byName = <String, Set<String>>{};
    for (final line in _surface()) {
      final [library, name] = line.split(' ');
      (byName[name] ??= {}).add(library);
    }
    expect([
      for (final e in byName.entries)
        if (e.value.length > 1) e.key,
    ], isEmpty);
  });

  test('the parser reads show lists and declarations', () {
    expect(_shown(" show A, B,\n    C"), ['A', 'B', 'C']);
    expect(_shown(''), isNull);
    expect(_shown(' hide A'), isNull);
    expect(_declared('sleuth.dart'), {'Sleuth'});
  });
}
