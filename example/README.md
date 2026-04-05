# Sleuth Example

Demo app with 15 screens, each triggering specific performance detectors.

## Running

```bash
# Profile mode (recommended — accurate timing)
cd example && flutter run --profile

# Debug mode (source locations visible, timing less representative)
cd example && flutter run
```

## Demo Screens

| # | Screen | Detectors Triggered |
|---|--------|-------------------|
| 1 | High-Level setState | Rebuild, SetStateScope |
| 2 | Non-Lazy ListView | ListView |
| 3 | IntrinsicHeight Abuse | LayoutBottleneck |
| 4 | Always-Repaint CustomPainter | CustomPainter |
| 5 | Uncached Images | ImageMemory |
| 6 | GlobalKey Overuse | GlobalKey |
| 7 | Nested Scroll | NestedScroll |
| 8 | Heavy Compute | HeavyCompute, FrameTiming |
| 9 | KeepAlive Overuse | KeepAlive |
| 10 | Opacity Zero | Opacity |
| 11 | AnimatedBuilder No Child | AnimatedBuilder |
| 12 | Shallow Rebuild Risk | ShallowRebuildRisk |
| 13 | Font Loading Stress | FontLoading |
| 14 | Repaint Stress | Repaint |
| 15 | Network Stress | NetworkMonitor |

Each demo includes `BAD:` and `FIX:` annotations explaining the anti-pattern and its fix.

## What to Look For

1. Tap the dog button to open the dashboard
2. Navigate to a demo screen and interact with it
3. Return to the dashboard — issues should appear in the Issues tab
4. In debug mode with `enableDebugCallbacks: true`, rebuild/repaint widget highlights are visible
5. In profile mode, frame timing data is most accurate
