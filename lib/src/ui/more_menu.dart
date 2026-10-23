import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import 'focus_ink_well.dart';
import 'motion.dart';
import 'overlay_ui_state.dart';
import 'sleuth_theme.dart';

/// What the More menu shows, read once when it opens.
typedef MoreMenuValues = ({
  /// Time to first frame, or null before it is measured.
  double? ttffMs,

  /// Rebuilds counted on the current route, or null when there are none.
  int? rebuildTotal,

  /// Whether the run counts rebuilds per route at all. Without it the
  /// Rebuild stats row reads "Off" rather than waiting for counts.
  bool rebuildCounting,

  /// Issues hidden from the overlay or suppressed by the config.
  int hiddenCount,
});

/// The panel the header's More button opens inside the card.
///
/// The overlay sits outside the app's `Navigator`, so a route-based menu
/// cannot open there; the card shows this panel over a scrim instead. It
/// is built only while open and does not listen to scan updates.
class SleuthMoreMenu extends StatefulWidget {
  const SleuthMoreMenu({
    super.key,
    this.semanticsKey,
    required this.values,
    required this.themeMode,
    required this.focusScope,
    required this.maxHeight,
    required this.onStartup,
    required this.onRebuildStats,
    required this.onHiddenIssues,
    required this.onEncyclopedia,
    required this.onGuide,
    required this.onCopySnapshot,
    required this.onThemeMode,
  });

  /// Key of the panel's semantics node, so the card can move screen
  /// reader focus to it.
  final Key? semanticsKey;

  final MoreMenuValues values;
  final SleuthThemeMode themeMode;

  /// Keyboard focus stays inside this scope while the menu is open.
  final FocusScopeNode focusScope;

  /// The panel scrolls above this height.
  final double maxHeight;

  final VoidCallback onStartup;
  final VoidCallback onRebuildStats;
  final VoidCallback onHiddenIssues;
  final VoidCallback onEncyclopedia;
  final VoidCallback onGuide;
  final VoidCallback onCopySnapshot;

  /// Applies a theme mode; the menu stays open.
  final ValueChanged<SleuthThemeMode> onThemeMode;

  @override
  State<SleuthMoreMenu> createState() => _SleuthMoreMenuState();
}

class _SleuthMoreMenuState extends State<SleuthMoreMenu>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    startEntrance(context, _fade);
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final values = widget.values;
    final ttff = values.ttffMs;
    final rebuilds = values.rebuildTotal;
    final radius = BorderRadius.circular(theme.radiusXxl);
    Widget separator() => Padding(
      padding: EdgeInsets.symmetric(vertical: theme.spacingXxs),
      child: SizedBox(
        height: 1,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(color: theme.cardDivider),
        ),
      ),
    );
    return FadeTransition(
      opacity: _fade,
      // The panel is in the semantics tree from its first frame, when the
      // card moves screen reader focus to it.
      alwaysIncludeSemantics: true,
      child: FocusScope(
        node: widget.focusScope,
        autofocus: true,
        child: Semantics(
          key: widget.semanticsKey,
          container: true,
          explicitChildNodes: true,
          label: 'More',
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: theme.cardBackground,
              border: Border.all(color: theme.border),
              borderRadius: radius,
              boxShadow: [
                BoxShadow(
                  color: theme.shadow,
                  blurRadius: 28,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: Material(
                type: MaterialType.transparency,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: widget.maxHeight),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.symmetric(vertical: theme.spacingXs),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _MenuRow(
                          icon: Icons.rocket_launch_outlined,
                          label: 'Startup',
                          value: ttff == null
                              ? 'Not measured yet'
                              : 'TTFF ${ttff.round()} ms',
                          semanticsValue: ttff == null
                              ? null
                              : 'time to first frame ${ttff.round()} '
                                    'milliseconds',
                          onTap: ttff == null ? null : widget.onStartup,
                        ),
                        _MenuRow(
                          icon: Icons.autorenew,
                          label: 'Rebuild stats',
                          value: rebuilds != null
                              ? _grouped(rebuilds)
                              : values.rebuildCounting
                              ? 'No counts yet'
                              : 'Off',
                          onTap: rebuilds == null
                              ? null
                              : widget.onRebuildStats,
                        ),
                        if (values.hiddenCount > 0)
                          _MenuRow(
                            icon: Icons.visibility_off_outlined,
                            label: 'Hidden issues',
                            value: '${values.hiddenCount}',
                            onTap: widget.onHiddenIssues,
                          ),
                        separator(),
                        _MenuRow(
                          icon: Icons.menu_book_outlined,
                          label: 'Encyclopedia',
                          onTap: widget.onEncyclopedia,
                        ),
                        _MenuRow(
                          icon: Icons.help_outline,
                          label: 'Guide',
                          onTap: widget.onGuide,
                        ),
                        separator(),
                        _MenuRow(
                          icon: Icons.content_copy_outlined,
                          label: 'Copy snapshot',
                          onTap: widget.onCopySnapshot,
                        ),
                        separator(),
                        _ThemeRow(
                          mode: widget.themeMode,
                          onChanged: widget.onThemeMode,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// [n] with thousands separators: 2389 reads 2,389.
  static String _grouped(int n) {
    final digits = '$n';
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }
}

/// A full-width menu command, at least 48 px tall. A null [onTap] draws it
/// disabled.
class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.value,
    this.semanticsValue,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? value;

  /// [value] as a screen reader should say it, when the shown text
  /// abbreviates.
  final String? semanticsValue;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    final enabled = onTap != null;
    final value = this.value;
    final spoken = semanticsValue ?? value;
    return Semantics(
      button: true,
      enabled: enabled,
      label: spoken == null ? label : '$label, $spoken',
      onTap: onTap,
      excludeSemantics: true,
      child: SleuthFocusInkWell(
        onTap: onTap,
        borderRadius: BorderRadius.zero,
        builder: (context, showFocus) => SleuthFocusOutline(
          show: showFocus,
          color: theme.checkboxActive,
          borderRadius: BorderRadius.zero,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: theme.spacingLg),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 16,
                    color: enabled ? theme.textSecondary : theme.textQuaternary,
                  ),
                  SizedBox(width: theme.spacingMd),
                  // The value sits at the end, or under the label when the
                  // two do not fit on one line.
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: theme.spacingSm),
                      child: Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: theme.spacingMd,
                        children: [
                          Text(
                            label,
                            style: TextStyle(
                              color: enabled
                                  ? theme.textPrimary
                                  : theme.textTertiary,
                              fontSize: theme.fontLg,
                            ),
                          ),
                          if (value != null)
                            Text(
                              value,
                              style: TextStyle(
                                color: theme.textTertiary,
                                fontSize: theme.fontMd,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Theme as a three-way switch: Auto, Light and Dark. The current choice
/// is filled and outlined, with a filled icon, so the result of a tap
/// shows before it.
class _ThemeRow extends StatelessWidget {
  const _ThemeRow({required this.mode, required this.onChanged});

  final SleuthThemeMode mode;
  final ValueChanged<SleuthThemeMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = SleuthTheme.of(context);
    // iOS reads the current choice of a radio group from the selected
    // flag, as RawRadio sets it; Android reads the checked state.
    final readsSelected = switch (defaultTargetPlatform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };
    final segmentRadius = BorderRadius.circular(theme.radiusMd);
    final focusRadius = BorderRadius.circular(theme.radiusLg);
    Widget segment(
      SleuthThemeMode value,
      String name,
      Widget Function(bool on) face,
    ) {
      final on = mode == value;
      return Semantics(
        button: true,
        inMutuallyExclusiveGroup: true,
        checked: on,
        selected: readsSelected ? on : null,
        label: '$name theme',
        onTap: () => onChanged(value),
        excludeSemantics: true,
        child: SleuthFocusInkWell(
          onTap: () => onChanged(value),
          borderRadius: focusRadius,
          builder: (context, showFocus) => SizedBox(
            width: 48,
            height: 48,
            child: Center(
              // The focus outline sits 1 px outside the segment.
              child: SleuthFocusOutline(
                show: showFocus,
                color: theme.checkboxActive,
                borderRadius: focusRadius,
                child: SizedBox(
                  width: 48,
                  height: 34,
                  child: Center(
                    child: SizedBox(
                      width: 44,
                      height: 30,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: on
                              ? theme.checkboxActive.withValues(alpha: 0.24)
                              : null,
                          border: on
                              ? Border.all(
                                  color: theme.checkboxActive,
                                  width: 1.5,
                                )
                              : null,
                          borderRadius: segmentRadius,
                        ),
                        child: Center(child: face(on)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    Widget icon(IconData data) =>
        Icon(data, size: 15, color: theme.textSecondary);
    return Padding(
      padding: EdgeInsets.only(left: theme.spacingLg, right: theme.spacingXs),
      child: Row(
        children: [
          Icon(Icons.contrast, size: 16, color: theme.textSecondary),
          SizedBox(width: theme.spacingMd),
          Expanded(
            child: Text(
              'Theme',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: theme.fontLg,
              ),
            ),
          ),
          // The outline is 32 px tall; each segment takes taps over 48 px.
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 3 * 48,
                height: 32,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.cardDivider),
                    borderRadius: BorderRadius.circular(theme.radiusLg),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  segment(
                    SleuthThemeMode.system,
                    'Auto',
                    (on) => Text(
                      'Auto',
                      style: TextStyle(
                        color: on ? theme.textPrimary : theme.textSecondary,
                        fontSize: theme.fontBase,
                        fontWeight: on ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                  segment(
                    SleuthThemeMode.light,
                    'Light',
                    (on) =>
                        icon(on ? Icons.light_mode : Icons.light_mode_outlined),
                  ),
                  segment(
                    SleuthThemeMode.dark,
                    'Dark',
                    (on) =>
                        icon(on ? Icons.dark_mode : Icons.dark_mode_outlined),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}
