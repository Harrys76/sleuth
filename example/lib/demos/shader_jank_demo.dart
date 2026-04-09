import 'dart:ui';

import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 19: Shader Jank
// Triggers: ShaderJank detector (VM-only, ≥100ms shader compile)
// ─────────────────────────────────────────

/// Demonstrates shader compilation jank by navigating to a screen with
/// novel GPU effects that require first-time shader compilation.
class ShaderJankDemo extends StatelessWidget {
  const ShaderJankDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Shader Jank',
      description:
          '❌ BAD: First-time GPU shader compilation causes frame drops.\n'
          '✅ FIX: Pre-warm shaders during splash screen, or use Impeller.\n\n'
          '▶ Tap "Navigate" — the first visit compiles shaders and jank is '
          'visible. Subsequent visits are smooth (shaders are cached).\n\n'
          'Note: Impeller (default on iOS since Flutter 3.16, Android since '
          '3.22) pre-compiles shaders offline. This demo only triggers on '
          'the Skia backend. Use --no-enable-impeller to test.',
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.blur_on, size: 64, color: Colors.grey),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const _ShaderHeavyPage()),
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Navigate to Shader-Heavy Screen'),
            ),
            const SizedBox(height: 16),
            Text(
              'Restart the app to re-trigger shader compilation.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Page packed with novel GPU effects to trigger shader compilation.
class _ShaderHeavyPage extends StatelessWidget {
  const _ShaderHeavyPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shader-Heavy Screen')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Prominent in-page warning: users who skim the outer demo
          // description otherwise discover the Impeller incompatibility
          // only after clicking buttons and seeing nothing happen.
          const _ImpellerWarningBanner(),
          const SizedBox(height: 16),
          // ❌ BackdropFilter — compiles a blur shader on first render
          _buildSection(
            label: 'BackdropFilter (σ=20)',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 150,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.blue.shade400,
                            Colors.purple.shade400,
                          ],
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.landscape,
                          size: 64,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                      child: const Center(
                        child: Text(
                          'Blurred',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ❌ ShaderMask — compiles a gradient masking shader
          _buildSection(
            label: 'ShaderMask (gradient)',
            child: SizedBox(
              height: 150,
              child: Center(
                child: ShaderMask(
                  shaderCallback: (bounds) => const LinearGradient(
                    colors: [Colors.red, Colors.transparent],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ).createShader(bounds),
                  blendMode: BlendMode.dstIn,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.favorite,
                        size: 48,
                        color: Colors.red.shade300,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Gradient Masked',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Fading away...',
                        style: TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ❌ ColorFiltered — compiles a color matrix shader
          _buildSection(
            label: 'ColorFiltered (sepia matrix)',
            child: SizedBox(
              height: 150,
              child: ColorFiltered(
                colorFilter: const ColorFilter.matrix(<double>[
                  0.393, 0.769, 0.189, 0, 0, //
                  0.349, 0.686, 0.168, 0, 0,
                  0.272, 0.534, 0.131, 0, 0,
                  0, 0, 0, 1, 0,
                ]),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: LinearGradient(
                      colors: [Colors.green.shade400, Colors.teal.shade400],
                    ),
                  ),
                  child: const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.photo_filter,
                          size: 48,
                          color: Colors.white70,
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Sepia Filtered',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ❌ Stacked: BackdropFilter + ShaderMask combined
          _buildSection(
            label: 'Combined (blur + mask)',
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 150,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.orange.shade300,
                            Colors.pink.shade300,
                          ],
                        ),
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.auto_awesome,
                          size: 64,
                          color: Colors.white70,
                        ),
                      ),
                    ),
                    BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: ShaderMask(
                        shaderCallback: (bounds) => const RadialGradient(
                          colors: [Colors.white, Colors.transparent],
                        ).createShader(bounds),
                        blendMode: BlendMode.dstIn,
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.layers, size: 40, color: Colors.white),
                              SizedBox(height: 8),
                              Text(
                                'Stacked Effects',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static Widget _buildSection({required String label, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

/// Warning banner shown at the top of the shader-heavy page.
///
/// Impeller (the default backend on iOS since Flutter 3.16 and Android since
/// 3.22) pre-compiles shaders offline, so `ShaderCompilation` timeline events
/// are never emitted on Impeller regardless of how much blur/colorfilter
/// stacking the page does. Without this banner users run the demo on the
/// default backend, see zero detector hits, and reasonably conclude the
/// detector is broken. There is no public Flutter API to detect the active
/// graphics backend from Dart, so we always show the banner and explain what
/// the user needs to do to observe detection.
class _ImpellerWarningBanner extends StatelessWidget {
  const _ImpellerWarningBanner();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colorScheme.error.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: colorScheme.error,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Shader compile events only fire on the Skia backend. '
                'Impeller (default on iOS since Flutter 3.16 and Android '
                'since 3.22) pre-compiles shaders offline, so this demo '
                'will silently produce no detector hits there.\n\n'
                'To observe detection, relaunch with '
                '`--no-enable-impeller`.',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onErrorContainer,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
