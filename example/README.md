# Sleuth Example

Demo app with 23 screens organized by category, each triggering specific performance detectors.

## Running

```bash
# Profile mode (recommended — accurate timing)
cd example && flutter run --profile

# Debug mode (source locations visible, timing less representative)
cd example && flutter run
```

## Demo Screens

| # | Screen | Detectors Triggered | Category |
|---|--------|-------------------|----------|
| 1 | High-Level setState | Rebuild, SetStateScope | Build |
| 2 | Non-Lazy ListView | ListView | Build |
| 3 | AnimatedBuilder No Child | AnimatedBuilder | Build |
| 4 | Shallow Rebuild Risk | ShallowRebuildRisk | Build |
| 5 | Heavy Compute | HeavyCompute, FrameTiming | Build |
| 6 | Repaint Stress | Repaint | Paint |
| 7 | Always-Repaint CustomPainter | CustomPainter | Paint |
| 8 | Missing RepaintBoundary | RepaintBoundary | Paint |
| 9 | Opacity Zero | Opacity | GPU & Rendering |
| 10 | GPU Pressure | GpuPressure | GPU & Rendering |
| 11 | Shader Jank | ShaderJank | GPU & Rendering |
| 12 | FPS Stress Test | HeavyCompute, GpuPressure | GPU & Rendering |
| 13 | IntrinsicHeight Abuse | LayoutBottleneck | Layout |
| 14 | Nested Scroll | NestedScroll | Layout |
| 15 | Uncached Images | ImageMemory | Memory |
| 16 | Memory Pressure | MemoryPressure | Memory |
| 17 | KeepAlive Overuse | KeepAlive | Memory |
| 18 | Network Stress | NetworkMonitor | Network & I/O |
| 19 | Platform Channel Traffic | PlatformChannel | Network & I/O |
| 20 | Font Loading Stress | FontLoading | Network & I/O |
| 21 | GlobalKey Overuse | GlobalKey | Keys & Identity |
| 22 | Combined: Social Feed | Image, Opacity, Layout, setState | Combined |
| 23 | Combined: Analytics Dashboard | Painter, AnimBuilder, GlobalKey, Font | Combined |

Each demo includes `BAD:` and `FIX:` annotations explaining the anti-pattern and its fix.

## What to Look For

1. Tap the dog button to open the dashboard
2. Navigate to a demo screen and interact with it
3. Return to the dashboard — issues should appear in the Issues tab
4. In debug mode with `enableDebugCallbacks: true`, rebuild/repaint widget highlights are visible
5. In profile mode, frame timing data is most accurate
