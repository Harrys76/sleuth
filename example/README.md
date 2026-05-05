# Sleuth Example

Demo app organized by category. 20 demo screens trigger specific detectors;
7 capture-helper screens drive `runtimeVerified` capture brackets.

## Running

```bash
# Profile mode (recommended — accurate timing)
cd example && flutter run --profile

# Debug mode (source locations visible, timing less representative)
cd example && flutter run
```

## Demo Screens

| # | Screen | Detectors Triggered | Category |
|---|--------|--------------------|----------|
| 1 | High-Level setState | Rebuild, SetStateScope | Build |
| 2 | Rebuild Hotspot (Dashboard) | Rebuild Stats | Build |
| 3 | Non-Lazy ListView | ListView | Build |
| 4 | CSV Import | HeavyCompute | Build |
| 5 | Live Waveform | Repaint | Paint |
| 6 | Always-Repaint CustomPainter | CustomPainter | Paint |
| 7 | Missing RepaintBoundary | RepaintBoundary | Paint |
| 8 | GPU Pressure | GpuPressure | GPU & Rendering |
| 9 | Shader Jank | ShaderJank | GPU & Rendering |
| 10 | FPS Stress Test (~20 FPS) | HeavyCompute, GpuPressure | GPU & Rendering |
| 11 | IntrinsicHeight Abuse | LayoutBottleneck | Layout |
| 12 | Uncached Images | ImageMemory | Memory |
| 13 | Memory Pressure | MemoryPressure | Memory |
| 14 | KeepAlive Overuse | KeepAlive | Memory |
| 15 | Search + Gallery | NetworkMonitor | Network & I/O |
| 16 | Platform Channel Traffic | PlatformChannel | Network & I/O |
| 17 | Font Loading Stress | FontLoading | Network & I/O |
| 18 | Custom Detector Cookbook | Custom (Tooltip / Slow Frame / Raster) | Custom |
| 19 | Combined: Social Feed | Image, Layout, setState, Correlator | Combined |
| 20 | Combined: Chat App | Rebuild, KeepAlive, Channel, SetState | Combined |

### Capture Helpers (`runtimeVerified` brackets)

Drive on-device capture brackets for the audit gate.

| Screen | Bracket |
|--------|---------|
| HeavyCompute | `heavy_compute` warning + critical |
| RebuildActivity | `rebuild_activity` warning + critical |
| FrameTiming (jank_detected) | `jank_detected` warning (60Hz) |
| MemoryPressure | `heap_growing` warning |
| NetworkMonitor | `slow_request` warning + critical |
| PlatformChannel | `platform_channel_traffic` warning |
| Repaint | `excessive_repaint` warning |

Each demo includes `BAD:` and `FIX:` annotations explaining the anti-pattern and its fix.

## What to Look For

1. Tap the dog button to open the dashboard
2. Navigate to a demo screen and interact with it
3. Return to the dashboard — issues should appear in the Issues tab
4. In debug mode with `enableDebugCallbacks: true`, rebuild/repaint widget highlights are visible
5. In profile mode, frame timing data is most accurate
