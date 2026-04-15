import 'package:flutter/widgets.dart';

import 'type_name_cache.dart';

/// Names of widgets whose paints are intentional, frame-rate animations.
///
/// This list is the single source of truth shared between the
/// `DebugInstrumentationCoordinator` (which performs per-paint attribution
/// via ancestor + descendant inspection) and the `RepaintDetector` (which
/// surfaces the names in encyclopedia entries and tests). Adding a new
/// owner widget here automatically expands the suppression coverage.
///
/// **What belongs here**: widgets that drive an `AnimationController` or
/// `Tween` and therefore schedule paints at the device refresh rate by
/// design. A `CircularProgressIndicator` is the canonical example —
/// rotating at 60 Hz is the entire point of the widget.
///
/// **What does NOT belong here**: widgets that *can* animate but most often
/// don't (e.g. `Container`, `Padding`). Adding those would mask real bugs.
///
/// **Strip-set interaction**: `widget_location.dart:_frameworkNames` strips
/// many transition widgets (`SlideTransition`, `FadeTransition`,
/// `ScaleTransition`, `RotationTransition`, `SizeTransition`,
/// `FractionalTranslation`, `PositionedTransition`, `DecoratedBoxTransition`,
/// `Builder`, `ListenableBuilder`, `RepaintBoundary`, `AnimatedTheme`,
/// `AnimatedDefaultTextStyle`, `AnimatedPhysicalModel`) from the captured
/// chain entirely. Names that the strip set already removes are useless
/// for the *ascending chain* check; we omit them. The descendant walk
/// inspects raw runtime types and is unaffected by the strip set, but
/// `*Transition` / theme wrappers are not paint leaves and therefore
/// can't be reached as descendants either, so they remain omitted.
///
/// **Implicit animation widgets (`Animated*`)** are NOT in the strip set
/// and survive in chains, so they belong here. They drive per-frame
/// repaints during their tween window — e.g. a card that grows from
/// 100x100 to 300x300 over 300ms paints ~18 frames in a row, comfortably
/// over the 30/sec threshold. Without these entries, every implicit
/// animation in user code triggers a false `repaint_debug_*`.
const Set<String> animationOwnerNames = <String>{
  // --- Material / Cupertino indeterminate progress indicators (4) ---
  // Spin or pulse at the device refresh rate by design.
  'CircularProgressIndicator',
  'LinearProgressIndicator',
  'RefreshProgressIndicator',
  'CupertinoActivityIndicator',
  // RefreshIndicator wraps RefreshProgressIndicator with a drag gesture;
  // the wrapper also drives an animation controller during the bounce-back.
  'RefreshIndicator',

  // --- Generic animation builder patterns (3) ---
  // Listen to a Listenable / ValueListenable / Animation and rebuild on
  // every tick. By construction these are intentional animation drivers.
  'AnimatedBuilder',
  'ValueListenableBuilder',
  'TweenAnimationBuilder',

  // --- Implicit animation widgets (12) ---
  // Each runs an internal AnimationController to tween between old and
  // new property values. Tween durations of 100-300ms produce ~6-18
  // consecutive paints, which trips the 30/sec threshold for the duration
  // of the animation. Without these entries, every implicit animation in
  // user code surfaces as a false `repaint_debug_*`.
  'AnimatedContainer',
  'AnimatedRotation',
  'AnimatedScale',
  'AnimatedSize',
  'AnimatedOpacity',
  'AnimatedAlign',
  'AnimatedPadding',
  'AnimatedPositioned',
  'AnimatedPositionedDirectional',
  'AnimatedSlide',
  'AnimatedSwitcher',
  'AnimatedCrossFade',
  'AnimatedFractionallySizedBox',

  // --- Hero (1) ---
  // Animates a widget between two routes during a Hero transition.
  // The flight shuttle paints every frame for the duration of the
  // transition (~300ms by default).
  'Hero',
};

/// Word-boundary regex over [animationOwnerNames], computed once at
/// module load. The `\b…\b` anchors prevent substring lookalikes from
/// matching: `'CustomAnimatedBuilderUtility'` must NOT match
/// `'AnimatedBuilder'`.
///
/// Used by [chainContainsAnimationOwner] for ascending-chain inspection.
final RegExp animationOwnerRegex = RegExp(
  r'\b(' + animationOwnerNames.join('|') + r')\b',
);

/// Returns true if [chain] contains any [animationOwnerNames] entry as a
/// `\b…\b`-bounded token. Returns false on null/empty input — callers
/// must decide how to interpret "no evidence" (the coordinator falls
/// through to descendant inspection; the detector defaults to fire).
bool chainContainsAnimationOwner(String? chain) {
  if (chain == null || chain.isEmpty) return false;
  return animationOwnerRegex.hasMatch(chain);
}

/// Bounded-depth descendant walk from [root] looking for any element
/// whose widget runtime-type name is in [animationOwnerNames].
///
/// Uses [typeNameCache] for runtime-type lookup (zero per-element string
/// allocation in the steady state) and aborts as soon as a match is
/// found. Total cost is bounded by [maxVisits] regardless of subtree
/// fan-out, so this is safe to call from the paint hot path even when
/// the leaf widget is a large layout container.
///
/// **Why descendant inspection?** When a `CircularProgressIndicator` is
/// mounted *without* a wrapping `RepaintBoundary`, the dirty mark
/// propagates UP to the nearest layer-owning ancestor (commonly
/// `Center` or `Stack`). The framework calls `_handleProfilePaint`
/// with that ancestor as the leaf, so the captured ancestor chain
/// walks UP from the ancestor — `CircularProgressIndicator` is a
/// *descendant* of the leaf, not an ancestor, and the chain check
/// alone misses it. The descendant walk closes that gap.
///
/// **Generic stripping:** `runtimeType.toString()` includes type
/// parameters (e.g. `'ValueListenableBuilder<double>'`,
/// `'TweenAnimationBuilder<double>'`), but [animationOwnerNames] stores
/// the un-parameterised form. Before each Set lookup we slice off
/// anything from the first `<` onward — a single `indexOf` call that
/// branches over `substring` only when a generic is present, so
/// monomorphic types stay zero-allocation in the steady state.
///
/// Cost analysis at 60 Hz with `maxVisits=32`: 60 × 32 = 1,920 element
/// visits per second per repainting widget. Each visit is a Map lookup
/// in [typeNameCache] plus an `indexOf('<')` plus a Set membership test.
/// Negligible.
bool hasAnimationOwnerDescendant(
  Element root, {
  int maxVisits = 32,
  int maxDepth = 4,
}) {
  // Local mutable state instead of recursion-with-closure, to keep the
  // hot path allocation-free.
  var visits = 0;
  var found = false;

  void walk(Element element, int depth) {
    if (found || visits >= maxVisits || depth > maxDepth) return;
    visits++;
    final rawName = typeNameCache.lookup(element.widget);
    // Strip generics: `Foo<X>` → `Foo`. Only allocates when the type is
    // actually generic; non-generic names hit the indexOf == -1 branch
    // and pass through unchanged.
    final ltIdx = rawName.indexOf('<');
    final name = ltIdx == -1 ? rawName : rawName.substring(0, ltIdx);
    if (animationOwnerNames.contains(name)) {
      found = true;
      return;
    }
    element.visitChildren((child) {
      if (!found) walk(child, depth + 1);
    });
  }

  walk(root, 0);
  return found;
}

/// Bounded-depth ancestor walk from [element] looking for any element
/// whose widget runtime-type name is in [animationOwnerNames].
///
/// **Why a dedicated ancestor walk?** `buildAncestorChain` (in
/// `widget_location.dart`) caps at `maxDepth: 6` because its output is a
/// human-readable source-location string — anything deeper becomes
/// unreadable. But for ownership *detection* we don't care about
/// readability, we care about catching framework owners that nest deeply.
/// `RefreshProgressIndicator` is the canonical case: its painted leaf is
/// `CustomPaint`, and the wrapping `AnimatedBuilder` owner sits ~13
/// ancestors away through Material's internal layers
/// (`Transform > Opacity > Padding > Material > NotificationListener >
/// internal CustomPaint > PhysicalShape > SizedBox > Padding >
/// _SemanticsWrapper > AnimatedBuilder > RefreshProgressIndicator`). The
/// chain-string walk runs out at `Transform` and never reaches the
/// `AnimatedBuilder`. The descendant walk also misses it because the
/// owner is *upstream* of the painted leaf, not downstream.
///
/// Uses [Element.visitAncestorElements], which short-circuits when the
/// visitor returns `false`. Each visit does one [typeNameCache] lookup
/// plus a generic-strip plus a Set membership test — same per-step cost
/// as the descendant walk.
///
/// **Generic stripping:** identical to [hasAnimationOwnerDescendant] —
/// `runtimeType.toString()` includes type parameters (e.g.
/// `'ValueListenableBuilder<double>'`); we slice off everything from the
/// first `<` onward before the Set lookup.
///
/// Cost analysis at 60 Hz with `maxDepth=16`: 60 × 16 = 960 ancestor
/// visits per second per repainting widget. Same shape as the descendant
/// walk's budget. Negligible.
bool hasAnimationOwnerAncestor(Element element, {int maxDepth = 16}) {
  var depth = 0;
  var found = false;
  element.visitAncestorElements((ancestor) {
    if (depth >= maxDepth) return false;
    depth++;
    final rawName = typeNameCache.lookup(ancestor.widget);
    // Strip generics: `Foo<X>` → `Foo`. Same trick as the descendant walk.
    final ltIdx = rawName.indexOf('<');
    final name = ltIdx == -1 ? rawName : rawName.substring(0, ltIdx);
    if (animationOwnerNames.contains(name)) {
      found = true;
      return false;
    }
    return true;
  });
  return found;
}

/// Combined check: true iff [element]'s ancestor chain string contains
/// an animation owner OR a bounded-depth ancestor walk from [element]
/// reaches one OR a bounded-depth descendant walk from [element] reaches
/// one.
///
/// This is the canonical attribution function used by
/// `DebugInstrumentationCoordinator._handleProfilePaint` to decide whether
/// a single paint event was driven by an intentional animation.
///
/// **Three legs, ordered cheapest-first:**
/// 1. [chainContainsAnimationOwner] — string regex over the cached chain.
///    Catches the common case (e.g. `CircularProgressIndicator` directly
///    wrapped in `RepaintBoundary`).
/// 2. [hasAnimationOwnerAncestor] — typed ancestor walk independent of
///    the chain depth budget. Catches deeply-nested framework owners
///    (e.g. `RefreshProgressIndicator` → AnimatedBuilder ~13 levels up).
/// 3. [hasAnimationOwnerDescendant] — typed descendant walk. Catches the
///    KDD-3 gap where a `CircularProgressIndicator` mounted *without* a
///    wrapping `RepaintBoundary` propagates its dirty mark UP to a
///    plain ancestor like `Center`, which becomes the leaf in the paint
///    callback — the owner is then a *child* of the captured leaf.
bool isAnimationOwnedPaint(Element element, String? chain) {
  if (chainContainsAnimationOwner(chain)) return true;
  if (hasAnimationOwnerAncestor(element)) return true;
  return hasAnimationOwnerDescendant(element);
}
