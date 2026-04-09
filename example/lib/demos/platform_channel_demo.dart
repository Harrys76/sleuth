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

  /// Called by DemoScaffold when the toggle flips. If the user moves to
  /// the Fixed Pattern while the sustained load is running, stop it — the
  /// fix is "don't spam the channel in the first place".
  void _handleToggle(bool isFixed) {
    if (isFixed && _sustainedRunning) {
      _sustainedTimer?.cancel();
      _sustainedTimer = null;
      _addLog('Switched to Fixed Pattern — sustained load stopped.');
      setState(() => _sustainedRunning = false);
    }
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
          'or >8ms cumulative duration per second.\n'
          '▶ Flip to Fixed Pattern — a single batched call replaces 50 chatty '
          'ones, staying well below the threshold.\n\n'
          'Requires VM service connection (profile mode).',
      onToggle: _handleToggle,
      fixedBody: _buildFixedBody(context),
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

  /// Fixed-pattern body: a single batched call replaces the 50 chatty ones.
  /// Sleuth should not flag this — total calls/sec stays well below the
  /// 20/sec threshold because we invoke the channel at most once per tap.
  Widget _buildFixedBody(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton.icon(
                onPressed: () async {
                  _addLog(
                    'Batched call: fetching 50 items in one invocation...',
                  );
                  try {
                    await _channel.invokeMethod<void>('getBatch', {
                      'indices': List<int>.generate(50, (i) => i),
                    });
                    if (!mounted) return;
                    _addLog('Batched call: success (1 round-trip).');
                  } on MissingPluginException {
                    if (!mounted) return;
                    _addLog(
                      'Batched call: MissingPluginException (demo only).',
                    );
                  } on PlatformException catch (e) {
                    if (!mounted) return;
                    _addLog('Batched call error: $e');
                  }
                },
                icon: const Icon(Icons.inventory_2),
                label: const Text('Batched Call (50 items, 1 round-trip)'),
              ),
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                onPressed: () {
                  _addLog(
                    'EventChannel pattern: stream updates instead of polling.',
                  );
                },
                icon: const Icon(Icons.stream),
                label: const Text('Simulate EventChannel Stream'),
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
    );
  }
}
