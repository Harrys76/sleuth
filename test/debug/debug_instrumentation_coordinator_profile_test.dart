// Profile-mode coordinator tests — spec v15 M12.
//
// **Important:** widget tests run under `kDebugMode == true`, so the full
// profile-mode wiring used in production (`kProfileMode == true` plus the
// framework's `debugProfileBuildsEnabledUserWidgets` heavy-flags path)
// CANNOT be validated here. These tests exercise the coordinator's state
// machine, canonicalization logic, and `FlutterTimeline`-drain path — the
// only real profile-mode validation is the M1 probe
// (`example/lib/rebuild_stats_probe.dart`) run under
// `fvm flutter run --profile` against a physical device.
//
// Coverage:
// - `installProfileMode` flips `FlutterTimeline.debugCollectionEnabled`.
// - Refuses to install when already `true` (DevTools / second-Sleuth
//   conflict, KDD-1 + R20).
// - `uninstallProfileMode` and `dispose` restore the prior flag value.
// - Double-install (same mode) is an idempotent no-op.
// - `snapshot()` drains via `canonicalizeTypeName`, aggregates by name.
// - Elapsed-time correctness across drains.
// - `canonicalizeTypeName` unit coverage for deny-list, regex, generics.
//
// **tearDown isolation:** every test `setUp` captures
// `FlutterTimeline.debugCollectionEnabled`, and every `tearDown` drains
// the buffer and restores the flag to its prior value so static-buffer
// state cannot spill across tests.

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';

void main() {
  late bool prevDebugCollectionEnabled;

  setUp(() {
    prevDebugCollectionEnabled = FlutterTimeline.debugCollectionEnabled;
  });

  tearDown(() {
    // Drain any events the test left in the buffer before restoring the
    // flag. `debugCollect` throws when collection is disabled, so guard.
    if (FlutterTimeline.debugCollectionEnabled) {
      try {
        FlutterTimeline.debugCollect();
      } catch (_) {
        // Best-effort cleanup — swallow anything pathological.
      }
    }
    FlutterTimeline.debugCollectionEnabled = prevDebugCollectionEnabled;
  });

  group('DebugInstrumentationCoordinator profile mode', () {
    test('installProfileMode flips debugCollectionEnabled to true', () {
      FlutterTimeline.debugCollectionEnabled = false;
      final coordinator = DebugInstrumentationCoordinator();

      coordinator.installProfileMode();

      expect(FlutterTimeline.debugCollectionEnabled, isTrue);
      expect(coordinator.isProfileModeInstalled, isTrue);

      coordinator.dispose();
    });

    test('installProfileMode throws StateError when flag already true', () {
      FlutterTimeline.debugCollectionEnabled = true;
      final coordinator = DebugInstrumentationCoordinator();

      expect(
        () => coordinator.installProfileMode(),
        throwsA(isA<StateError>()),
      );
      expect(coordinator.isProfileModeInstalled, isFalse);
      // Flag must still be `true` — we refused to install, so we must not
      // have changed the caller's state.
      expect(FlutterTimeline.debugCollectionEnabled, isTrue);

      coordinator.dispose();
    });

    test('uninstallProfileMode restores prior debugCollectionEnabled value',
        () {
      FlutterTimeline.debugCollectionEnabled = false;
      final coordinator = DebugInstrumentationCoordinator();

      coordinator.installProfileMode();
      expect(FlutterTimeline.debugCollectionEnabled, isTrue);

      coordinator.uninstallProfileMode();
      expect(FlutterTimeline.debugCollectionEnabled, isFalse);
      expect(coordinator.isProfileModeInstalled, isFalse);

      coordinator.dispose();
    });

    test('double installProfileMode is a silent no-op', () {
      FlutterTimeline.debugCollectionEnabled = false;
      final coordinator = DebugInstrumentationCoordinator();

      coordinator.installProfileMode();
      // Second install must NOT throw and must NOT re-enter the install body.
      // This is the hot-restart tolerance branch (controller wiring may call
      // install twice across reassemble).
      coordinator.installProfileMode();

      expect(FlutterTimeline.debugCollectionEnabled, isTrue);
      expect(coordinator.isProfileModeInstalled, isTrue);

      coordinator.dispose();
    });

    test(
        'installProfileMode is a no-op after install() (debug mode already on)',
        () {
      FlutterTimeline.debugCollectionEnabled = false;
      final coordinator = DebugInstrumentationCoordinator();
      // Install the debug-mode path first (callbacks). This moves
      // `_installedMode` to `debug`, so a subsequent `installProfileMode`
      // hits the idempotent early-return.
      coordinator.install();

      coordinator.installProfileMode();

      // Flag must remain untouched — debug path installed, profile refused.
      expect(FlutterTimeline.debugCollectionEnabled, isFalse);
      expect(coordinator.isProfileModeInstalled, isFalse);

      coordinator.dispose();
    });

    test(
        'snapshot drains FlutterTimeline buffer, aggregates, and filters '
        'via canonicalization', () {
      FlutterTimeline.debugCollectionEnabled = false;
      final coordinator = DebugInstrumentationCoordinator();
      coordinator.installProfileMode();

      // Emit a mix of events: valid type names, denylisted frame scopes,
      // and parameterized generics. The coordinator must canonicalize +
      // filter correctly and produce an aggregated map.
      FlutterTimeline.startSync('ProductCard');
      FlutterTimeline.finishSync();
      FlutterTimeline.startSync('ProductCard');
      FlutterTimeline.finishSync();
      FlutterTimeline.startSync('BUILD'); // denylisted
      FlutterTimeline.finishSync();
      FlutterTimeline.startSync('Provider<SomeModel>'); // generic stripped
      FlutterTimeline.finishSync();
      FlutterTimeline.startSync('Provider<OtherModel>'); // same key after strip
      FlutterTimeline.finishSync();
      FlutterTimeline.startSync('Foo Bar'); // non-identifier, dropped
      FlutterTimeline.finishSync();

      final snapshot = coordinator.snapshot();

      expect(snapshot.source, RebuildCountSource.flutterTimeline);
      expect(snapshot.rebuildCounts['ProductCard'], 2);
      expect(snapshot.rebuildCounts['Provider'], 2,
          reason: 'Provider<SomeModel> and Provider<OtherModel> must merge');
      expect(snapshot.rebuildCounts.containsKey('BUILD'), isFalse);
      expect(snapshot.rebuildCounts.containsKey('Foo Bar'), isFalse);
      // Profile path leaves paint + ancestor chains empty — those come from
      // the debug-callback path only.
      expect(snapshot.paintCounts, isEmpty);
      expect(snapshot.totalPaintCount, 0);
      expect(snapshot.ancestorChains, isEmpty);

      coordinator.dispose();
    });

    test(
        'snapshot with empty buffer returns zero counts tagged flutterTimeline',
        () {
      FlutterTimeline.debugCollectionEnabled = false;
      final coordinator = DebugInstrumentationCoordinator();
      coordinator.installProfileMode();

      final snapshot = coordinator.snapshot();

      expect(snapshot.source, RebuildCountSource.flutterTimeline);
      expect(snapshot.rebuildCounts, isEmpty);

      coordinator.dispose();
    });

    test('snapshot elapsed advances across successive drains', () {
      FlutterTimeline.debugCollectionEnabled = false;
      var tick = DateTime(2024);
      DateTime clock() {
        tick = tick.add(const Duration(milliseconds: 100));
        return tick;
      }

      final coordinator = DebugInstrumentationCoordinator(clock: clock);
      coordinator.installProfileMode();

      final a = coordinator.snapshot();
      final b = coordinator.snapshot();
      final c = coordinator.snapshot();

      // Each successive snapshot must observe a positive elapsed delta —
      // the coordinator resets `_lastSnapshotTime` on every drain.
      expect(a.elapsed, greaterThan(Duration.zero));
      expect(b.elapsed, greaterThan(Duration.zero));
      expect(c.elapsed, greaterThan(Duration.zero));

      coordinator.dispose();
    });

    test('dispose tears down profile mode and restores flag', () {
      FlutterTimeline.debugCollectionEnabled = false;
      final coordinator = DebugInstrumentationCoordinator();
      coordinator.installProfileMode();
      expect(FlutterTimeline.debugCollectionEnabled, isTrue);

      coordinator.dispose();

      expect(FlutterTimeline.debugCollectionEnabled, isFalse);
      expect(coordinator.isProfileModeInstalled, isFalse);
    });

    test('second install after uninstall restores clean state', () {
      FlutterTimeline.debugCollectionEnabled = false;
      final coordinator = DebugInstrumentationCoordinator();

      coordinator.installProfileMode();
      coordinator.uninstallProfileMode();
      expect(FlutterTimeline.debugCollectionEnabled, isFalse);

      // Reinstalling must succeed — flag is clean again.
      coordinator.installProfileMode();
      expect(FlutterTimeline.debugCollectionEnabled, isTrue);
      expect(coordinator.isProfileModeInstalled, isTrue);

      coordinator.dispose();
    });
  });

  group('canonicalizeTypeName', () {
    test('passes simple user type names unchanged', () {
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('ProductCard'),
        'ProductCard',
      );
    });

    test('strips generic parameters from parameterized types', () {
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('Provider<Foo>'),
        'Provider',
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName(
            'Consumer<Bar<Baz>>'),
        'Consumer',
      );
    });

    test('rejects denylisted frame scopes', () {
      expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName('BUILD'), isNull,
          reason: 'BUILD is a framework frame scope, not a widget type');
      expect(DebugInstrumentationCoordinator.canonicalizeTypeName('LAYOUT'),
          isNull);
      expect(DebugInstrumentationCoordinator.canonicalizeTypeName('PAINT'),
          isNull);
      expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName('FINALIZE TREE'),
          isNull);
      expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName(
              'Preparing Hot Reload (widgets)'),
          isNull);
      // v0.15.1 follow-up (KDD-10b): identifier-shaped frame scopes that
      // were missing from the original denylist and leaked into the
      // Rebuild Stats drilldown as fake "widgets" with one entry per
      // frame (~60/sec at 60 FPS). Each is sourced from a
      // `FlutterTimeline.startSync(...)` call inside the Flutter SDK
      // (see the comment on `_denyList` for file:line references).
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('POST_FRAME'),
        isNull,
        reason: 'POST_FRAME is the post-frame-callbacks phase scope, not a '
            'widget type — scheduler/binding.dart:1353',
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('COMPOSITING'),
        isNull,
        reason: 'COMPOSITING is the layer-tree upload phase scope, not a '
            'widget type — rendering/view.dart:349',
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('SEMANTICS'),
        isNull,
        reason: 'SEMANTICS is the semantics-tree phase scope, not a widget '
            'type — rendering/object.dart:1440',
      );
    });

    test(
        'frame-phase scopes with the (root) suffix are dropped by the '
        'identifier-shape regex layer (defense in depth for the variants '
        'in `_denyList`)', () {
      // Flutter's rendering/object.dart appends ` (root)` to LAYOUT,
      // PAINT, SEMANTICS, and UPDATING COMPOSITING BITS for the root
      // RenderObject. These contain spaces and parens, so the identifier
      // regex layer (`^_?[A-Z][A-Za-z0-9_]*(<.*>)?$`) drops them before
      // they ever reach the explicit denylist or the framework set.
      // This test pins that contract: if the regex is ever loosened, the
      // variants must already be in `_denyList` or the drilldown will
      // re-fill with framework noise.
      for (final scope in const [
        'LAYOUT (root)',
        'PAINT (root)',
        'SEMANTICS (root)',
        'UPDATING COMPOSITING BITS',
        'UPDATING COMPOSITING BITS (root)',
        'Semantics.updateChildren',
        'Semantics.ensureGeometry',
        'Semantics.ensureSemanticsNode',
        'Framework initialization',
        'Preparing Hot Reload (layout)',
      ]) {
        expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName(scope),
          isNull,
          reason: '$scope must be dropped (framework phase scope, not a '
              'widget). Either the explicit denylist or the identifier '
              'regex must reject it.',
        );
      }
    });

    test('rejects non-identifier shapes via regex', () {
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('Foo Bar'),
        isNull,
        reason: 'space is not allowed in identifiers',
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('finalize tree'),
        isNull,
        reason: 'lowercase start fails the regex',
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName(''),
        isNull,
        reason: 'empty string is not an identifier',
      );
    });

    test('rejects RenderObject runtime-type names', () {
      // When `debugProfileLayoutsEnabled` or `debugProfilePaintsEnabled`
      // is on, `RenderObject.layout()` / `paint()` dumps
      // `FlutterTimeline.startSync('${runtimeType}')` into the same buffer
      // the Rebuild Stats drilldown reads (flutter/src/rendering/object.dart:
      // 2665 and 3369). Those flags are `false` by default in
      // `DebugInstrumentationConfig`, but can leak on when DevTools or
      // another plugin flips them — so canonicalization must drop `Render*`
      // names defensively. Otherwise the drilldown fills with render-tree
      // leaf-node scopes and buries the actual widget hotspots.
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('RenderPadding'),
        isNull,
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('RenderFlex'),
        isNull,
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('RenderParagraph'),
        isNull,
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName(
            'RenderConstrainedBox'),
        isNull,
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName(
            'RenderSemanticsAnnotations'),
        isNull,
      );
      // Private render objects are also filtered.
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName(
            '_RenderCustomPainter'),
        isNull,
      );
    });

    test('admits Sliver* widget types (not RenderObjects)', () {
      // `Sliver*` user-facing widgets (`SliverList`, `SliverPadding`,
      // `SliverAppBar`, `SliverToBoxAdapter`, `SliverFillRemaining`, …)
      // must still pass the Render filter because they are real widgets
      // the user writes and wants attributed in the rebuild drilldown.
      // Only `RenderSliver*` subclasses are RenderObjects.
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('SliverList'),
        'SliverList',
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('SliverPadding'),
        'SliverPadding',
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('SliverAppBar'),
        'SliverAppBar',
      );
      // But RenderSliver* is a RenderObject subclass → filtered.
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName(
            'RenderSliverList'),
        isNull,
      );
    });

    test(
        'admits user widget names that happen to share a Render prefix '
        'substring', () {
      // Only a *leading* `Render` or `_Render` prefix is filtered; user
      // widgets like `RendererProfile` (unusual but not reserved) would
      // still match `Render…`. Document the known boundary: Dart
      // convention reserves `Render*` for `RenderObject` subclasses, so
      // we don't try to disambiguate — any leading `Render` is treated
      // as a RenderObject name.
      //
      // Non-leading matches are fine: `MyRenderBadge` passes because the
      // prefix check anchors to position 0 (or 1 after `_`).
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('MyRenderBadge'),
        'MyRenderBadge',
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('_MyRenderBadge'),
        '_MyRenderBadge',
      );
    });

    test('admits private (underscored) Dart type names', () {
      // Private Dart classes (`_BadDashboard`, `_MetricCard`) are the most
      // common hotspot shape in real apps — a page defines its rows, cards,
      // and charts as private classes in the same file. The Flutter
      // framework emits them through
      // `FlutterTimeline.startSync('${runtimeType}')` unconditionally when
      // `debugProfileBuildsEnabledUserWidgets` is on (DevTools' native
      // Rebuild Stats tab shows them too). The previous regex `^[A-Z]`
      // silently dropped them, making Sleuth's drilldown miss the very
      // widgets the user most wants to see. `^_?[A-Z]` admits them.
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('_BadDashboard'),
        '_BadDashboard',
      );
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('_MetricCard'),
        '_MetricCard',
      );
      // Generic stripping still applies to private generics.
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('_Wrapper<Foo>'),
        '_Wrapper',
      );
    });

    test('still rejects non-identifier shapes even with leading underscore',
        () {
      // Lowercase after underscore is not a Dart type identifier.
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('_privateField'),
        isNull,
      );
      // Plain leading lowercase still rejected.
      expect(
        DebugInstrumentationCoordinator.canonicalizeTypeName('_'),
        isNull,
      );
    });

    // v0.15.1 hotfix KDD-10: every entry in the framework + Sleuth-overlay
    // denylist must canonicalize to null so the profile-mode drain never
    // attributes self-contamination to the active session. The audit test
    // in `test/debug/overlay_denylist_audit_test.dart` enforces the set's
    // PARITY with the UI source tree; these tests enforce the set's
    // BEHAVIOR through `canonicalizeTypeName`. Both layers are required —
    // parity without behavior would allow a misplaced early-return to
    // silently let entries through.
    group('framework widget denylist (KDD-10)', () {
      test('every denylist entry is dropped by canonicalizeTypeName', () {
        final denyList =
            DebugInstrumentationCoordinator.debugFrameworkWidgetDenyList;
        final leaked = <String>[];
        for (final entry in denyList) {
          final result =
              DebugInstrumentationCoordinator.canonicalizeTypeName(entry);
          if (result != null) leaked.add('$entry → $result');
        }
        expect(
          leaked,
          isEmpty,
          reason: 'These denylist entries passed through canonicalizeTypeName '
              'instead of being dropped, which means Sleuth will self-measure '
              'them in profile mode (KDD-10 regression):\n'
              '  ${leaked..sort()}',
        );
      });

      test('denylist collapses generics before checking set membership', () {
        // `ValueListenableBuilder<int>` must reduce to `ValueListenableBuilder`
        // and then get dropped. If the denylist check runs BEFORE generic
        // stripping, the parameterized form slips through and Sleuth
        // self-measures its own progress indicators.
        expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName(
              'ValueListenableBuilder<int>'),
          isNull,
        );
        expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName(
              'NotificationListener<ScrollNotification>'),
          isNull,
        );
        // Sleuth-internal overlay widgets are non-generic but the same
        // filter path must still drop them.
        expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName(
              'FloatingIssuesCard'),
          isNull,
        );
        expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName('_StatusRow'),
          isNull,
        );
      });

      test('user widgets with similar-looking names still pass through', () {
        // Regression guard: the denylist is a SET lookup, so we must not
        // accidentally prefix-match or substring-match. A user widget named
        // `ContainerPro` or `MyText` is NOT in the denylist and must still
        // be counted as a real hotspot.
        expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName('ContainerPro'),
          'ContainerPro',
        );
        expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName('MyText'),
          'MyText',
        );
        expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName('PaddedCard'),
          'PaddedCard',
        );
        // A private widget whose name doesn't collide with an overlay
        // entry must still pass. `_FloatingIssuesCard` (extra underscore
        // prefix equivalent) is NOT in the set — the real entry is the
        // public `FloatingIssuesCard`.
        expect(
          DebugInstrumentationCoordinator.canonicalizeTypeName(
              '_MyPrivateCard'),
          '_MyPrivateCard',
        );
      });
    });
  });
}
