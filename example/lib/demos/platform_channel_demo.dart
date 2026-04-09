import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 20: Platform Channel Traffic
// Triggers: PlatformChannel detector (VM-only, >20 calls/sec)
// ─────────────────────────────────────────

/// Demonstrates excessive platform channel invocations that block the UI thread.
class PlatformChannelDemo extends StatefulWidget {
  const PlatformChannelDemo({super.key});

  @override
  State<PlatformChannelDemo> createState() => _PlatformChannelDemoState();
}

class _PlatformChannelDemoState extends State<PlatformChannelDemo> {
  static const _channel = MethodChannel('sleuth_demo_channel');

  final List<String> _log = [];
  bool _rapidRunning = false;
  bool _sustainedRunning = false;
  Timer? _sustainedTimer;
  int _sustainedCount = 0;

  /// Snapshot of the global `debugProfilePlatformChannels` flag captured on
  /// entry so we can restore it on dispose. Without this, navigating into and
  /// back out of this demo silently clobbers a developer's global setting.
  bool _priorDebugProfilePlatformChannels = false;

  @override
  void initState() {
    super.initState();
    _priorDebugProfilePlatformChannels = debugProfilePlatformChannels;
    debugProfilePlatformChannels = true;
  }

  void _addLog(String message) {
    if (!mounted) return;
    setState(() => _log.add(message));
  }

  // ── Rapid Fire ──

  Future<void> _triggerRapidFire() async {
    if (_rapidRunning) return;
    setState(() => _rapidRunning = true);
    _addLog('Firing 50 rapid platform calls...');

    int successes = 0;
    int errors = 0;
    final futures = List.generate(50, (i) async {
      try {
        await _channel.invokeMethod<void>('getData', {'index': i});
        successes++;
      } on PlatformException {
        errors++;
      } on MissingPluginException {
        errors++;
      }
    });
    await Future.wait(futures);
    if (!mounted) return;
    _addLog('Rapid fire done: $successes ok, $errors unhandled.');
    setState(() => _rapidRunning = false);
  }

  // ── Sustained Load ──

  void _toggleSustained() {
    if (_sustainedRunning) {
      _sustainedTimer?.cancel();
      _sustainedTimer = null;
      _addLog('Sustained load stopped after $_sustainedCount calls.');
      setState(() => _sustainedRunning = false);
    } else {
      _sustainedCount = 0;
      setState(() => _sustainedRunning = true);
      _addLog('Sustained load started (50 calls/sec)...');
      _sustainedTimer = Timer.periodic(const Duration(milliseconds: 20), (_) {
        _sustainedCount++;
        _channel
            .invokeMethod<void>('tick', {'n': _sustainedCount})
            .catchError((_) => null);
      });
    }
  }

  // ── Single Call ──

  Future<void> _triggerSingle() async {
    _addLog('Single platform call...');
    try {
      await _channel.invokeMethod<void>('ping');
      _addLog('Single call: success.');
    } on MissingPluginException {
      _addLog('Single call: MissingPluginException (no native handler).');
    } on PlatformException catch (e) {
      _addLog('Single call error: $e');
    }
    // _addLog is guarded internally by a `mounted` check, so no extra
    // guard is needed after these awaits.
  }

  @override
  void dispose() {
    _sustainedTimer?.cancel();
    // Restore the prior value rather than hard-coding false, so a developer
    // who enabled this globally (e.g., in main.dart) still sees channel
    // profiling after navigating away from this demo.
    debugProfilePlatformChannels = _priorDebugProfilePlatformChannels;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Platform Channel Traffic',
      description:
          '❌ BAD: Excessive platform channel calls (>20/sec) block the UI thread.\n'
          '✅ FIX: Batch calls, use EventChannel for streams, or use Pigeon.\n\n'
          '▶ Tap "Rapid Fire" or "Sustained Load" — Sleuth flags >20 calls/sec '
          'or >8ms cumulative duration per second.\n\n'
          'Requires VM service connection (profile mode).',
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _rapidRunning ? null : _triggerRapidFire,
                  icon: const Icon(Icons.bolt),
                  label: const Text('Rapid Fire (50)'),
                ),
                FilledButton.icon(
                  onPressed: _toggleSustained,
                  icon: Icon(_sustainedRunning ? Icons.stop : Icons.play_arrow),
                  label: Text(
                    _sustainedRunning ? 'Stop Sustained' : 'Sustained Load',
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: _triggerSingle,
                  icon: const Icon(Icons.touch_app),
                  label: const Text('Single Call'),
                ),
              ],
            ),
          ),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: ListView.builder(
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      _log[i],
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
