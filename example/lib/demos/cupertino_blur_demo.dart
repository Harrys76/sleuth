import 'dart:typed_data' show Float64List;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';

// ─────────────────────────────────────────
// Demo: Cupertino Blur
// Triggers: GpuPressure `expensive_gpu_nodes` for the blurs that cost raster
// time; checks the blur strength Sleuth reads in profile builds
// ─────────────────────────────────────────

/// Cupertino chrome that blurs what scrolls under it, plus one panel per
/// filter shape.
///
/// * The navigation bar and the tab bar blur the content behind them while
///   they are translucent. "Opaque bars" gives both an opaque background,
///   which switches their blur off.
/// * "Show alert" opens a `CupertinoAlertDialog`, which blurs the page.
/// * The panels below use a blur of sigma 2 (too weak to report), sigma 20,
///   a blur composed with a matrix (sigma unknown, reported), two weak
///   blurs composed (sigma 1 then 2 draws sigma 2.24, reported), a
///   configured blur of sigma 1.5, and a disabled sigma-20 blur (nothing
///   drawn, nothing reported).
class CupertinoBlurDemo extends StatefulWidget {
  const CupertinoBlurDemo({super.key});

  @override
  State<CupertinoBlurDemo> createState() => _CupertinoBlurDemoState();
}

class _CupertinoBlurDemoState extends State<CupertinoBlurDemo> {
  bool _opaqueBars = false;
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final barColor = _opaqueBars ? CupertinoColors.systemBackground : null;
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Cupertino Blur'),
        backgroundColor: barColor,
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: const Icon(CupertinoIcons.back),
        ),
      ),
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 104, 16, 16),
              children: [
                Row(
                  children: [
                    const Expanded(child: Text('Opaque bars')),
                    CupertinoSwitch(
                      value: _opaqueBars,
                      onChanged: (v) => setState(() => _opaqueBars = v),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                CupertinoButton.filled(
                  onPressed: _showAlert,
                  child: const Text('Show alert'),
                ),
                const SizedBox(height: 16),
                _BlurPanel(
                  label: 'Blur sigma 2 (too weak to report)',
                  filter: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                ),
                _BlurPanel(
                  label: 'Blur sigma 20',
                  filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                ),
                _BlurPanel(
                  label: 'Blur sigma 20 composed with a scale',
                  filter: ui.ImageFilter.compose(
                    outer: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    inner: ui.ImageFilter.matrix(
                      Float64List.fromList(<double>[
                        1.2, 0, 0, 0, //
                        0, 1.2, 0, 0, //
                        0, 0, 1, 0, //
                        0, 0, 0, 1, //
                      ]),
                    ),
                  ),
                ),
                _BlurPanel(
                  label: 'Blurs sigma 1 and 2 composed',
                  filter: ui.ImageFilter.compose(
                    outer: ui.ImageFilter.blur(sigmaX: 1, sigmaY: 1),
                    inner: ui.ImageFilter.blur(sigmaX: 2, sigmaY: 2),
                  ),
                ),
                const _BlurPanel(
                  label: 'Configured blur sigma 1.5',
                  filterConfig: ImageFilterConfig.blur(
                    sigmaX: 1.5,
                    sigmaY: 1.5,
                  ),
                ),
                _BlurPanel(
                  label: 'Disabled blur sigma 20',
                  filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  enabled: false,
                ),
              ],
            ),
          ),
          CupertinoTabBar(
            currentIndex: _tab,
            backgroundColor: barColor,
            onTap: (i) => setState(() => _tab = i),
            items: const [
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.square_stack),
                label: 'Panels',
              ),
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.info),
                label: 'About',
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showAlert() {
    showCupertinoDialog<void>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Blurred page'),
        content: const Text('The dialog blurs the page behind it.'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// A colored grid with one [BackdropFilter] over it. The filter's child
/// has more than five descendants, so an expensive filter is reported.
class _BlurPanel extends StatelessWidget {
  const _BlurPanel({
    required this.label,
    this.filter,
    this.filterConfig,
    this.enabled = true,
  });

  final String label;
  final ui.ImageFilter? filter;
  final ImageFilterConfig? filterConfig;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('Line one'),
          const Text('Line two'),
          const Text('Line three'),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 140,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _ColorGrid(),
            ClipRect(
              child: filterConfig != null
                  ? BackdropFilter(
                      filterConfig: filterConfig,
                      enabled: enabled,
                      child: content,
                    )
                  : BackdropFilter(
                      filter: filter!,
                      enabled: enabled,
                      child: content,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorGrid extends StatelessWidget {
  const _ColorGrid();

  static const _colors = [
    CupertinoColors.systemRed,
    CupertinoColors.systemOrange,
    CupertinoColors.systemYellow,
    CupertinoColors.systemGreen,
    CupertinoColors.systemBlue,
    CupertinoColors.systemPurple,
  ];

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final color in _colors) Expanded(child: ColoredBox(color: color)),
      ],
    );
  }
}
