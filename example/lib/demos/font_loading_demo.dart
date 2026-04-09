import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 13: Font Loading Stress
// Triggers: FontLoading detector (>3 custom fonts)
// ─────────────────────────────────────────

/// Demonstrates loading many custom font families on a single screen.
/// Each family triggers a separate font load and increases binary size,
/// memory, and first-paint jank.
class FontLoadingDemo extends StatelessWidget {
  const FontLoadingDemo({super.key});

  // ❌ 5 distinct custom font families — triggers threshold of >3.
  static const _badFonts = [
    'Lobster',
    'Pacifico',
    'DancingScript',
    'IndieFlower',
    'GreatVibes',
  ];

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Font Loading Stress',
      description:
          '❌ BAD: ${_badFonts.length} different custom font families on one '
          'screen. Each family is a separate asset load, a separate raster '
          'cache, and more work during first-paint.\n'
          '✅ FIX: Limit to 1–2 families and vary weight/size instead. When '
          'custom fonts are unavoidable, pre-load them at splash time via '
          'FontLoader.\n\n'
          '▶ Flip to Fixed Pattern — the same screen rendered using the '
          'default font at varied weights. The FontLoading detector should '
          'go quiet.',
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          for (final font in _badFonts)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      font,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'The quick brown fox jumps over the lazy dog',
                      style: TextStyle(fontFamily: font, fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      fixedBody: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: const [
          _FixedRow(label: 'Default w400', weight: FontWeight.w400),
          _FixedRow(label: 'Default w500', weight: FontWeight.w500),
          _FixedRow(label: 'Default w600', weight: FontWeight.w600),
          _FixedRow(label: 'Default w700', weight: FontWeight.w700),
          _FixedRow(label: 'Default w800', weight: FontWeight.w800),
        ],
      ),
    );
  }
}

class _FixedRow extends StatelessWidget {
  const _FixedRow({required this.label, required this.weight});

  final String label;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: Text(
              'The quick brown fox jumps over the lazy dog',
              style: TextStyle(fontSize: 16, fontWeight: weight),
            ),
          ),
        ],
      ),
    );
  }
}
