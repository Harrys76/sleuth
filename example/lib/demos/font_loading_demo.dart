import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 13: Font Loading Stress
// Triggers: FontLoading detector (>3 custom fonts)
// ─────────────────────────────────────────
class FontLoadingDemo extends StatelessWidget {
  const FontLoadingDemo({super.key});

  @override
  Widget build(BuildContext context) {
    // ❌ 5 distinct custom font families — triggers threshold of >3
    const customFonts = [
      'Lobster',
      'Pacifico',
      'DancingScript',
      'IndieFlower',
      'GreatVibes',
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Font Loading Stress')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: 5 different custom font families loaded simultaneously.\n'
              '✅ FIX: Limit to 1-2 font families or pre-cache with FontLoader.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          ...customFonts.map(
            (font) => Padding(
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
          ),
        ],
      ),
    );
  }
}
