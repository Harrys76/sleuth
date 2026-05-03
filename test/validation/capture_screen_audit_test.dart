// Source-grep audit for capture-screen wiring invariants. Capture screens
// are operator-internal demos with no widget-test coverage; this file is
// the minimum safe net against silent refactor regressions on
// load-bearing fields and guards that the operator workflow depends on.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Capture-screen wiring audit', () {
    // Cross-leg short-circuit on persistent post-process `rewriteError`.
    // Without all three elements present, the operator either burns
    // retry budgets across multiple legs on the same shape-drift bug
    // OR loses the cross-leg gate entirely (per-leg short-circuit
    // alone allows next leg to start a fresh retry budget on identical
    // failures).
    group('persistent rewriteError cross-leg flag', () {
      const wiredScreens = <String>[
        'example/lib/demos/memory_pressure_capture_screen.dart',
        'example/lib/demos/platform_channel_capture_screen.dart',
      ];

      for (final path in wiredScreens) {
        test('$path has the field, setter, and entry guard', () {
          final f = File(path);
          expect(f.existsSync(), isTrue,
              reason: '$path must exist; capture screens are part of the '
                  'operator workflow contract.');
          final src = f.readAsStringSync();

          expect(src.contains('bool _persistentRewriteError = false;'), isTrue,
              reason: '$path must declare '
                  '`bool _persistentRewriteError = false;` at the State '
                  'class level. Removing the field disables the '
                  'cross-leg short-circuit so an operator who hits a '
                  'persistent _replaceExpectedObserved shape drift on '
                  'one leg burns retry budgets on every other leg before '
                  'restarting.');

          expect(src.contains('_persistentRewriteError = true;'), isTrue,
              reason: '$path must set '
                  '`_persistentRewriteError = true;` at the rewriteError '
                  'catch site (the same `else if (rewriteError != null)` '
                  'block that exhausts the per-leg retry budget). '
                  'Without the setter, the entry guard is unreachable.');

          expect(src.contains('if (_persistentRewriteError)'), isTrue,
              reason: '$path must guard the top of `_runLeg` with '
                  '`if (_persistentRewriteError) { ... return; }` '
                  'BEFORE any per-leg work. A guard placed after the '
                  '`if (_busy) return;` line still works, but moving '
                  'it below the captureMode-OFF check or below the '
                  'per-leg budget guard would let a fresh leg run a '
                  'wasted scenario before the gate fires.');
        });
      }
    });
  });
}
