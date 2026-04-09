import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 9: KeepAlive Overuse
// Triggers: KeepAlive detector (>5 active clients in TabBarView)
// ─────────────────────────────────────────

/// Demonstrates over-use of `AutomaticKeepAliveClientMixin` inside a
/// `TabBarView`. Every tab opts in, so Flutter retains all tab subtrees
/// in memory even after the user swipes away. The detector flags any
/// PageView/TabBarView with more than 5 **active** keep-alive clients.
///
/// The fix keeps only the first two tabs alive (the "form" rows where
/// losing state would frustrate the user) and lets the framework recycle
/// the rest.
class KeepAliveDemo extends StatefulWidget {
  const KeepAliveDemo({super.key});

  @override
  State<KeepAliveDemo> createState() => _KeepAliveDemoState();
}

class _KeepAliveDemoState extends State<KeepAliveDemo>
    with SingleTickerProviderStateMixin {
  static const _tabCount = 10;

  late final TabController _tabController;
  bool _isFixed = false;

  /// Guards concurrent invocations of [_prewarmBadTabs] so rapid toggles
  /// don't stack multiple prewarm loops on top of each other.
  bool _prewarming = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabCount, vsync: this);
    _prewarmBadTabs();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  /// Briefly cycles the TabController through every tab so each
  /// `_KeepAliveTab` actually mounts, runs `AutomaticKeepAliveClientMixin
  /// .initState`, and dispatches its `KeepAliveNotification`. Without
  /// this, `TabBarView` only materializes the currently-visible page, so
  /// the KeepAlive detector would see at most 1–2 active keep-alives —
  /// far below the threshold of 5 — and the anti-pattern would never
  /// surface until the user manually swiped through every tab.
  ///
  /// We step one tab per frame so `TabBarView._warpToAdjacentTab`
  /// actually runs for each transition (non-adjacent jumps skip
  /// intermediate pages). Setting the index directly (as opposed to
  /// `animateTo`) uses the no-duration code path, so each hop commits
  /// in a single frame.
  void _prewarmBadTabs() {
    if (_prewarming || _isFixed) return;
    _prewarming = true;
    var nextIndex = 1;
    void step() {
      if (!mounted || _isFixed) {
        _prewarming = false;
        return;
      }
      if (nextIndex < _tabCount) {
        _tabController.index = nextIndex;
        nextIndex++;
        WidgetsBinding.instance.addPostFrameCallback((_) => step());
      } else {
        _tabController.index = 0;
        _prewarming = false;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => step());
  }

  void _handleToggle(bool isFixed) {
    _isFixed = isFixed;
    if (!isFixed) {
      // Returning to the bad path — the previous `_BadTabs` subtree was
      // unmounted by the DemoScaffold ternary, so every tab State (and
      // thus every `KeepAliveNotification`) was lost. Cycle through the
      // tabs again so the detector sees all $_tabCount active
      // keep-alives.
      _prewarmBadTabs();
    }
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'KeepAlive Overuse',
      description:
          '❌ BAD: $_tabCount tabs, each using AutomaticKeepAliveClientMixin '
          'with wantKeepAlive: true. Flutter retains every tab subtree in '
          'memory after you swipe away, and the detector flags "more than '
          '5 keep-alive clients" in the TabBarView.\n'
          '✅ FIX: Only opt tabs into AutomaticKeepAlive when they hold '
          'expensive state that re-creating would hurt (a form with user '
          'input, an in-flight download, a video). Here the first two '
          'tabs act like stateful forms and stay alive; the rest are '
          'recycled when off-screen.\n\n'
          '▶ Flip to Fixed Pattern — only 2 tabs are kept alive, below '
          'the threshold, so the detector goes quiet.',
      onToggle: _handleToggle,
      body: _BadTabs(controller: _tabController),
      fixedBody: _FixedTabs(controller: _tabController),
    );
  }
}

/// ❌ Bad path: every tab opts into keep-alive.
class _BadTabs extends StatelessWidget {
  const _BadTabs({required this.controller});

  final TabController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: controller,
          isScrollable: true,
          tabs: [
            for (var i = 0; i < _KeepAliveDemoState._tabCount; i++)
              Tab(text: 'Tab ${i + 1}'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: controller,
            children: [
              for (var i = 0; i < _KeepAliveDemoState._tabCount; i++)
                _KeepAliveTab(label: 'Tab ${i + 1}', keepAlive: true),
            ],
          ),
        ),
      ],
    );
  }
}

/// ✅ Fixed path: only the first two tabs opt into keep-alive.
class _FixedTabs extends StatelessWidget {
  const _FixedTabs({required this.controller});

  final TabController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: controller,
          isScrollable: true,
          tabs: [
            for (var i = 0; i < _KeepAliveDemoState._tabCount; i++)
              Tab(text: i < 2 ? 'Form ${i + 1}' : 'Tab ${i + 1}'),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: controller,
            children: [
              for (var i = 0; i < _KeepAliveDemoState._tabCount; i++)
                _KeepAliveTab(
                  label: i < 2 ? 'Form tab ${i + 1}' : 'Tab ${i + 1}',
                  keepAlive: i < 2,
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _KeepAliveTab extends StatefulWidget {
  const _KeepAliveTab({required this.label, required this.keepAlive});

  final String label;
  final bool keepAlive;

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by the mixin
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            widget.keepAlive ? Icons.all_inclusive : Icons.circle_outlined,
            size: 64,
            color: widget.keepAlive ? Colors.orange : Colors.grey,
          ),
          const SizedBox(height: 12),
          Text(
            widget.label,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            widget.keepAlive
                ? 'wantKeepAlive: true — retained across tab swipes'
                : 'wantKeepAlive: false — recycled when off-screen',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
