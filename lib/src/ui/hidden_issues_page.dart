import 'package:flutter/material.dart';

import '../models/performance_issue.dart';
import 'overlay_filters.dart';
import 'sleuth_theme.dart';
import 'text_scale_clamp.dart';

/// Full-screen list of issues hidden from the overlay.
///
/// Runtime-hidden entries (hidden from a card) can be restored one by one
/// or all at once. Patterns from `SleuthConfig.suppressedIssues` are
/// listed read-only: they are removed before ranking and only change in
/// code.
class HiddenIssuesPage extends StatelessWidget {
  const HiddenIssuesPage({
    super.key,
    required this.hiddenKeys,
    required this.issues,
    required this.configSuppressions,
    required this.suppressedCount,
    required this.onRestore,
    required this.onRestoreAll,
    required this.onClose,
  });

  /// Runtime-hidden keys, oldest first.
  final List<String> hiddenKeys;

  /// Current issues, used to show titles for hidden keys.
  final List<PerformanceIssue> issues;

  /// Patterns from `SleuthConfig.suppressedIssues`.
  final Set<String> configSuppressions;

  /// Issues removed by [configSuppressions] in the last aggregation.
  final int suppressedCount;

  final ValueChanged<String> onRestore;
  final VoidCallback onRestoreAll;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final byKey = <String, PerformanceIssue>{
      for (final i in issues) hideKeyFor(i): i,
    };
    // Newest first: the issue just hidden is at the top.
    final keys = hiddenKeys.reversed.toList();
    final patterns = configSuppressions.toList()..sort();

    // Route semantics: screen readers announce the page name and keep
    // focus inside the page.
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: 'Hidden issues',
      child: Material(
        color: theme.pageBackground,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.all(theme.spacingMd),
                child: Row(
                  children: [
                    Semantics(
                      label: 'Back',
                      button: true,
                      child: GestureDetector(
                        onTap: onClose,
                        behavior: HitTestBehavior.opaque,
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: Center(
                            child: Icon(
                              Icons.arrow_back,
                              color: theme.textPrimary,
                              size: 22,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Icon(
                      Icons.visibility_off_outlined,
                      color: theme.textTertiary,
                      size: 18,
                    ),
                    SizedBox(width: theme.spacingXs),
                    Expanded(
                      child: Text(
                        'Hidden issues',
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: theme.fontXl,
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (keys.isNotEmpty)
                      _TextAction(
                        label: 'Restore all',
                        semanticsLabel: 'Restore all hidden issues',
                        onTap: onRestoreAll,
                      ),
                  ],
                ),
              ),
              Divider(color: theme.border, height: 1),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    theme.spacingXl,
                    theme.spacingLg,
                    theme.spacingXl,
                    theme.spacingXl,
                  ),
                  children: [
                    _sectionTitle('Hidden in the overlay', theme),
                    Padding(
                      padding: EdgeInsets.only(bottom: theme.spacingSm),
                      child: Text(
                        'Only the overlay hides these. Exports, snapshots and '
                        'budgets still include them.',
                        style: TextStyle(
                          color: theme.textTertiary,
                          fontSize: theme.fontSm,
                        ),
                      ),
                    ),
                    if (keys.isEmpty)
                      _emptyLine('Nothing hidden.', theme)
                    else
                      for (final key in keys)
                        _HiddenRow(
                          title: byKey[key]?.title ?? key,
                          subtitle: byKey[key] == null
                              ? 'Not detected right now'
                              : key,
                          onRestore: () => onRestore(key),
                        ),
                    SizedBox(height: theme.spacingXl),
                    _sectionTitle('Suppressed in SleuthConfig', theme),
                    Padding(
                      padding: EdgeInsets.only(bottom: theme.spacingSm),
                      child: Text(
                        suppressedCount == 0
                            ? 'Removed before ranking. Set in SleuthConfig.'
                            : '$suppressedCount removed before ranking. '
                                  'Set in SleuthConfig.',
                        style: TextStyle(
                          color: theme.textTertiary,
                          fontSize: theme.fontSm,
                        ),
                      ),
                    ),
                    if (patterns.isEmpty)
                      _emptyLine('No suppression patterns.', theme)
                    else
                      for (final p in patterns)
                        Padding(
                          padding: EdgeInsets.symmetric(
                            vertical: theme.spacingXs,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.lock_outline,
                                color: theme.textQuaternary,
                                size: 14,
                              ),
                              SizedBox(width: theme.spacingSm),
                              Expanded(
                                child: Text(
                                  p,
                                  style: TextStyle(
                                    color: theme.textSecondary,
                                    fontSize: theme.fontMd,
                                  ),
                                ),
                              ),
                              SizedBox(width: theme.spacingSm),
                              Flexible(
                                child: Text(
                                  'set in SleuthConfig',
                                  style: TextStyle(
                                    color: theme.textQuaternary,
                                    fontSize: theme.fontXs,
                                  ),
                                  textAlign: TextAlign.right,
                                ),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text, SleuthThemeData theme) => Padding(
    padding: EdgeInsets.only(bottom: theme.spacingXs),
    child: Text(
      text,
      style: TextStyle(
        color: theme.textPrimary,
        fontSize: theme.fontBase,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _emptyLine(String text, SleuthThemeData theme) => Padding(
    padding: EdgeInsets.symmetric(vertical: theme.spacingSm),
    child: Text(
      text,
      style: TextStyle(color: theme.textQuaternary, fontSize: theme.fontMd),
    ),
  );
}

class _HiddenRow extends StatelessWidget {
  const _HiddenRow({
    required this.title,
    required this.subtitle,
    required this.onRestore,
  });

  final String title;
  final String subtitle;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: theme.spacingXxs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: theme.fontMd,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: theme.textTertiary,
                    fontSize: theme.fontXs,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          _TextAction(
            label: 'Restore',
            semanticsLabel: 'Restore $title',
            onTap: onRestore,
          ),
        ],
      ),
    );
  }
}

class _TextAction extends StatelessWidget {
  const _TextAction({
    required this.label,
    required this.semanticsLabel,
    required this.onTap,
  });

  final String label;
  final String semanticsLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    return Semantics(
      label: semanticsLabel,
      button: true,
      onTap: onTap,
      container: true,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: theme.spacingSm),
            child: Center(
              widthFactor: 1,
              // Button labels stop growing at the chrome limit so the
              // header keeps room for the title.
              child: Text(
                label,
                style: TextStyle(
                  color: theme.checkboxActive,
                  fontSize: theme.fontMd,
                  fontWeight: FontWeight.w600,
                ),
                textScaler: MediaQuery.textScalerOf(
                  context,
                ).clamp(maxScaleFactor: kChromeMaxTextScale),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
