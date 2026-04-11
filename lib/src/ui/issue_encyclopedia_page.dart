import 'dart:async';

import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
import '../utils/issue_explanation_builder.dart';
import 'sleuth_theme.dart';

/// Full-screen encyclopedia listing all detected issue types, grouped by category.
///
/// Supports search, expandable entries, and scroll-to from "Learn more" links.
/// Replaces the single-issue [IssueDetailPage].
///
/// Follows the [GuidePage] pattern: `Positioned.fill` in the
/// [FloatingIssuesCard] Stack, toggled by a local boolean.
class IssueEncyclopediaPage extends StatefulWidget {
  const IssueEncyclopediaPage({
    super.key,
    required this.onClose,
    this.scrollToStableId,
    this.contextIssue,
  });

  final VoidCallback onClose;

  /// If non-null, the entry with this stableId opens expanded and scrolled-to.
  final String? scrollToStableId;

  /// If non-null, contextual placeholders in the matching entry's template are
  /// substituted with values from this issue (widget name, route, count, etc.).
  final PerformanceIssue? contextIssue;

  @override
  State<IssueEncyclopediaPage> createState() => _IssueEncyclopediaPageState();
}

class _IssueEncyclopediaPageState extends State<IssueEncyclopediaPage>
    with SingleTickerProviderStateMixin {
  /// Sentinel issue used for placeholder substitution when no real context
  /// issue is available. All fields trigger built-in fallbacks in
  /// [IssueExplanationBuilder._substitutePlaceholders].
  static const _fallbackIssue = PerformanceIssue(
    severity: IssueSeverity.warning,
    category: IssueCategory.build,
    confidence: IssueConfidence.possible,
    title: 'several',
    detail: '',
    fixHint: '',
  );

  late final AnimationController _entranceController;
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  String _searchQuery = '';
  final Set<String> _expandedEntries = {};
  Timer? _searchDebounce;

  /// Keys for entry tiles that need scroll-to support.
  final Map<String, GlobalKey> _entryKeys = {};

  /// Whether the initial scroll-to target has completed its scroll.
  bool _scrollTargetScrolled = false;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    )..forward();

    // Pre-expand and prepare scroll-to target.
    if (widget.scrollToStableId != null &&
        IssueExplanationBuilder.allExplanations
            .containsKey(widget.scrollToStableId)) {
      _expandedEntries.add(widget.scrollToStableId!);
      _entryKeys[widget.scrollToStableId!] = GlobalKey();
    }

    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _entranceController.dispose();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged() {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 150), () {
      if (mounted) {
        setState(() => _searchQuery = _searchController.text.toLowerCase());
      }
    });
  }

  void _scrollToTarget() {
    if (_scrollTargetScrolled || widget.scrollToStableId == null) return;
    final key = _entryKeys[widget.scrollToStableId!];
    if (key?.currentContext == null) return;
    _scrollTargetScrolled = true;
    Scrollable.ensureVisible(
      key!.currentContext!,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  /// Returns (or creates) a GlobalKey for the given entry stableId.
  GlobalKey _keyForEntry(String stableId) =>
      _entryKeys.putIfAbsent(stableId, () => GlobalKey());

  bool _matchesSearch(IssueExplanation entry) {
    if (_searchQuery.isEmpty) return true;
    if (entry.displayName.toLowerCase().contains(_searchQuery) ||
        entry.whatItIs.toLowerCase().contains(_searchQuery) ||
        (entry.readingTheData?.toLowerCase().contains(_searchQuery) ?? false) ||
        entry.whyItMatters.toLowerCase().contains(_searchQuery) ||
        entry.howToFix.toLowerCase().contains(_searchQuery) ||
        (entry.whenToIgnore?.toLowerCase().contains(_searchQuery) ?? false)) {
      return true;
    }
    // Search related issue display names.
    final related = entry.relatedIssues;
    if (related != null) {
      for (final id in related) {
        final rel = IssueExplanationBuilder.explain(id);
        if (rel != null &&
            rel.displayName.toLowerCase().contains(_searchQuery)) {
          return true;
        }
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final groups = IssueExplanationBuilder.groupedEntries;
    final keyboardPadding = MediaQuery.viewInsetsOf(context).bottom;

    // Header + search bar fade in first 40%, body from 20%.
    final headerAnim = CurvedAnimation(
      parent: _entranceController,
      curve: const Interval(0.0, 0.4, curve: Curves.easeOutCubic),
    );
    final bodyAnim = CurvedAnimation(
      parent: _entranceController,
      curve: const Interval(0.2, 1.0, curve: Curves.easeOutCubic),
    );

    // Schedule scroll after frame if needed.
    if (widget.scrollToStableId != null && !_scrollTargetScrolled) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToTarget());
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _searchFocusNode.unfocus();
          widget.onClose();
        }
      },
      child: Material(
        color: theme.pageBackground,
        child: SafeArea(
          child: Column(
            children: [
              // ── Header ──────────────────────────────────────────────
              FadeTransition(
                opacity: headerAnim,
                child: Padding(
                  padding: EdgeInsets.all(theme.spacingMd),
                  child: Row(
                    children: [
                      GestureDetector(
                        onTap: () {
                          _searchFocusNode.unfocus();
                          widget.onClose();
                        },
                        behavior: HitTestBehavior.opaque,
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Center(
                            child: Icon(Icons.arrow_back,
                                color: theme.textPrimary, size: 22),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          'Issue Encyclopedia',
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(color: theme.border, height: 1),

              // ── Search bar (pinned) ─────────────────────────────────
              FadeTransition(
                opacity: headerAnim,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(theme.spacingMd, theme.spacingSm,
                      theme.spacingMd, theme.spacingSm),
                  child: _SearchBar(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    theme: theme,
                  ),
                ),
              ),
              Divider(color: theme.border, height: 1),

              // ── Scrollable body ─────────────────────────────────────
              Expanded(
                child: FadeTransition(
                  opacity: bodyAnim,
                  child: _buildBody(groups, theme, keyboardPadding),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    List<({IssueCategory category, List<(String, IssueExplanation)> entries})>
        groups,
    SleuthThemeData theme,
    double keyboardPadding,
  ) {
    // Filter groups by search.
    final filteredGroups = <({
      IssueCategory category,
      List<(String, IssueExplanation)> entries,
      int totalCount,
    })>[];

    for (final group in groups) {
      final filtered =
          group.entries.where((e) => _matchesSearch(e.$2)).toList();
      if (filtered.isNotEmpty) {
        filteredGroups.add((
          category: group.category,
          entries: filtered,
          totalCount: group.entries.length,
        ));
      }
    }

    if (filteredGroups.isEmpty) {
      return Center(
        child: Text(
          'No matching issues',
          style: TextStyle(color: theme.textTertiary, fontSize: 12),
        ),
      );
    }

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(theme.spacingMd, theme.spacingSm,
          theme.spacingMd, 24 + keyboardPadding),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final group in filteredGroups) ...[
            _categoryHeader(
                group.category, group.entries.length, group.totalCount, theme),
            SizedBox(height: theme.spacingSm),
            for (final (stableId, entry) in group.entries) ...[
              _entryTile(stableId, entry, theme),
              SizedBox(height: theme.spacingXs),
            ],
            SizedBox(height: theme.spacingMd),
          ],
        ],
      ),
    );
  }

  Widget _categoryHeader(
    IssueCategory category,
    int visibleCount,
    int totalCount,
    SleuthThemeData theme,
  ) {
    final color = theme.categoryColor(category);
    final name = _categoryDisplayName(category);
    final icon = _categoryIcon(category);
    final countText = _searchQuery.isNotEmpty
        ? '$visibleCount of $totalCount'
        : '$totalCount';

    return Padding(
      padding: EdgeInsets.only(top: theme.spacingSm),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(icon, color: color, size: 14),
          ),
          SizedBox(width: theme.spacingSm),
          Text(
            name,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
          SizedBox(width: theme.spacingXs),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              countText,
              style: TextStyle(
                color: color,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _entryTile(
    String stableId,
    IssueExplanation entry,
    SleuthThemeData theme,
  ) {
    final isExpanded = _expandedEntries.contains(stableId);
    final isScrollTarget = stableId == widget.scrollToStableId;

    // Apply contextual substitution. When a real issue is available (the
    // scroll target), placeholders resolve to its data. For all other entries
    // the static sentinel triggers built-in fallbacks ('the widget',
    // 'several', etc.) so raw `{widgetName}` tokens never render.
    final effectiveEntry = IssueExplanationBuilder.substitute(
      entry,
      isScrollTarget && widget.contextIssue != null
          ? widget.contextIssue!
          : _fallbackIssue,
    );

    return Container(
      key: _entryKeys[stableId] ??
          (isScrollTarget ? _keyForEntry(stableId) : null),
      decoration: BoxDecoration(
        color: theme.sectionBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.border, width: 0.5),
      ),
      child: Column(
        children: [
          // Tappable header
          GestureDetector(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedEntries.remove(stableId);
                } else {
                  _expandedEntries.add(stableId);
                }
              });
            },
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: EdgeInsets.symmetric(
                  horizontal: theme.spacingMd, vertical: theme.spacingSm + 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      effectiveEntry.displayName,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.expand_more,
                      color: theme.textQuaternary,
                      size: 18,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Expandable content — skip AnimatedSize for scroll target on first frame
          if (isScrollTarget && !_scrollTargetScrolled && isExpanded)
            _entryContent(stableId, effectiveEntry, theme)
          else
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              child: isExpanded
                  ? _entryContent(stableId, effectiveEntry, theme)
                  : const SizedBox.shrink(),
            ),
        ],
      ),
    );
  }

  Widget _entryContent(
    String stableId,
    IssueExplanation entry,
    SleuthThemeData theme,
  ) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          theme.spacingMd, 0, theme.spacingMd, theme.spacingMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionBlock('What it is', entry.whatItIs, theme),
          if (entry.readingTheData != null) ...[
            SizedBox(height: theme.spacingSm),
            _readingTheDataBlock(entry.readingTheData!, theme),
          ],
          SizedBox(height: theme.spacingSm),
          _sectionBlock('Why it matters', entry.whyItMatters, theme),
          SizedBox(height: theme.spacingSm),
          _sectionBlock('How to fix', entry.howToFix, theme),
          if (entry.whenToIgnore != null) ...[
            SizedBox(height: theme.spacingSm),
            _sectionBlock('When to ignore', entry.whenToIgnore!, theme),
          ],
          if (entry.relatedIssues != null &&
              entry.relatedIssues!.isNotEmpty) ...[
            SizedBox(height: theme.spacingSm),
            _relatedIssuesBlock(entry.relatedIssues!, theme),
          ],
        ],
      ),
    );
  }

  Widget _relatedIssuesBlock(
    List<String> relatedIds,
    SleuthThemeData theme,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Related issues',
          style: TextStyle(
            color: theme.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        SizedBox(height: theme.spacingXxs),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final id in relatedIds)
              if (IssueExplanationBuilder.explain(id) case final related?)
                GestureDetector(
                  onTap: () {
                    final key = _keyForEntry(id);
                    setState(() => _expandedEntries.add(id));
                    // Scroll to the target after next frame.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      final ctx = key.currentContext;
                      if (ctx != null) {
                        Scrollable.ensureVisible(
                          ctx,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOutCubic,
                        );
                      }
                    });
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: theme.pageBackground,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: theme.border, width: 0.5),
                    ),
                    child: Text(
                      related.displayName,
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 10,
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ],
    );
  }

  Widget _sectionBlock(String title, String body, SleuthThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: theme.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        SizedBox(height: theme.spacingXxs),
        Text(
          body,
          style: TextStyle(
            color: theme.textSecondary,
            fontSize: 11,
            height: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _readingTheDataBlock(String body, SleuthThemeData theme) {
    return Container(
      padding: EdgeInsets.all(theme.spacingMd),
      decoration: BoxDecoration(
        color: theme.pageBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: theme.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Reading the data',
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
          SizedBox(height: theme.spacingXxs),
          Text(
            body,
            style: TextStyle(
              color: theme.textSecondary,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Category metadata ──────────────────────────────────────────────────

  static String _categoryDisplayName(IssueCategory category) =>
      switch (category) {
        IssueCategory.build => 'BUILD & REBUILD',
        IssueCategory.layout => 'LAYOUT',
        IssueCategory.paint => 'PAINT & REPAINT',
        IssueCategory.raster => 'GPU & RASTER',
        IssueCategory.memory => 'MEMORY',
        IssueCategory.network => 'NETWORK',
        IssueCategory.font => 'FONT',
        IssueCategory.channel => 'PLATFORM CHANNELS',
        IssueCategory.startup => 'STARTUP',
      };

  static IconData _categoryIcon(IssueCategory category) => switch (category) {
        IssueCategory.build => Icons.construction_outlined,
        IssueCategory.layout => Icons.view_quilt_outlined,
        IssueCategory.paint => Icons.brush_outlined,
        IssueCategory.raster => Icons.memory_outlined,
        IssueCategory.memory => Icons.sd_storage_outlined,
        IssueCategory.network => Icons.cloud_outlined,
        IssueCategory.font => Icons.text_fields_outlined,
        IssueCategory.channel => Icons.swap_horiz_outlined,
        IssueCategory.startup => Icons.rocket_launch_outlined,
      };
}

// ─── Search bar ────────────────────────────────────────────────────────────

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.theme,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final SleuthThemeData theme;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        style: TextStyle(color: theme.textPrimary, fontSize: 12),
        cursorColor: theme.textTertiary,
        decoration: InputDecoration(
          hintText: 'Search issues...',
          hintStyle: TextStyle(color: theme.textQuaternary, fontSize: 12),
          prefixIcon: Icon(Icons.search, color: theme.textQuaternary, size: 18),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (_, value, __) => value.text.isEmpty
                ? const SizedBox.shrink()
                : GestureDetector(
                    onTap: controller.clear,
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: 36,
                      height: 36,
                      child: Center(
                        child: Icon(Icons.close,
                            color: theme.textQuaternary, size: 16),
                      ),
                    ),
                  ),
          ),
          filled: true,
          fillColor: theme.sectionBackground,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: theme.border, width: 0.5),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: theme.border, width: 0.5),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: theme.textTertiary, width: 1),
          ),
        ),
      ),
    );
  }
}
