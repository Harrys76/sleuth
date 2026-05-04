import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../demo_scaffold.dart';

// CSV "import contacts" screen. The bad path parses on the main isolate
// inside `build()` so the BUILD timeline event spans the parse —
// HeavyComputeDetector observes durations >8 ms (warning) / >16 ms
// (critical). The fixed path offloads to `Isolate.run` so the parent
// isolate's BUILD event stays sub-threshold and the UI stays responsive.

const _rowChoices = [1000, 10000, 50000];

class HeavyComputeDemo extends StatefulWidget {
  const HeavyComputeDemo({super.key});

  @override
  State<HeavyComputeDemo> createState() => _HeavyComputeDemoState();
}

class _HeavyComputeDemoState extends State<HeavyComputeDemo> {
  int _rowIndex = 1; // default 10K (warning)
  bool _busy = false;
  // Set by the bad-path Pick CSV tap and consumed on the next `build`.
  // The parse must run inside `build` so the enclosing BUILD timeline
  // event — emitted by `BuildOwner.buildScope` — captures the parse
  // duration. Gesture-handler work runs in pointer dispatch (no BUILD
  // event), so HeavyComputeDetector cannot observe it there.
  bool _pendingMainParse = false;
  final ValueNotifier<int> _lastMainMs = ValueNotifier<int>(0);
  final ValueNotifier<int> _lastIsolateMs = ValueNotifier<int>(0);
  List<_Contact> _contacts = const [];

  int get _rowCount => _rowChoices[_rowIndex];

  @override
  void dispose() {
    _lastMainMs.dispose();
    _lastIsolateMs.dispose();
    super.dispose();
  }

  void _handleToggle(bool isFixed) {
    // A pending main-isolate parse is consumed only by the Bad body's
    // build. If the user toggles to Fixed before that build runs the
    // body unmounts, the parse never fires, and the post-frame
    // callback that would have cleared `_busy` never schedules. Reset
    // both flags so the Fixed body's controls aren't stranded.
    if (_pendingMainParse) {
      setState(() {
        _pendingMainParse = false;
        _busy = false;
      });
    }
  }

  void _onSliderChanged(double v) {
    final newIndex = v.round();
    if (newIndex == _rowIndex) return;
    HapticFeedback.selectionClick();
    setState(() => _rowIndex = newIndex);
  }

  void _requestMainParse() {
    setState(() {
      _busy = true;
      _pendingMainParse = true;
      _contacts = const [];
    });
  }

  Future<void> _runIsolateParse() async {
    setState(() {
      _busy = true;
      _contacts = const [];
    });
    final stopwatch = Stopwatch()..start();
    final rows = _rowCount;
    final result = await Isolate.run(() => _generateAndParse(rows));
    stopwatch.stop();
    if (!mounted) return;
    _lastIsolateMs.value = stopwatch.elapsedMilliseconds;
    setState(() {
      _busy = false;
      _contacts = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_pendingMainParse) {
      _pendingMainParse = false;
      final stopwatch = Stopwatch()..start();
      final rows = _rowCount;
      final result = _generateAndParse(rows);
      stopwatch.stop();
      final elapsedMs = stopwatch.elapsedMilliseconds;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _lastMainMs.value = elapsedMs;
        setState(() {
          _busy = false;
          _contacts = result;
        });
      });
    }

    return DemoScaffold(
      title: 'CSV Import',
      description:
          '❌ BAD: Parses an in-memory CSV synchronously on the main isolate '
          'inside `build()`. The enclosing BUILD timeline event spans the '
          'parse — HeavyComputeDetector flags `heavy_compute.warning` '
          '(>8 ms) and `heavy_compute.critical` (>16 ms) at the larger row '
          'counts. UI freezes for the duration of the parse.\n'
          '✅ FIX: `Isolate.run()` offloads parsing — UI stays responsive, '
          'detector goes silent. Note: isolate spawn overhead is ~50–150 ms, '
          'so the isolate path is not strictly faster for tiny payloads — '
          'it trades total time for UI responsiveness.\n\n'
          '▶ Slide the row count, tap Pick CSV. 1K = silent, 10K = warning, '
          '50K = critical. Toggle Fixed to see the detector go silent.\n\n'
          'No Cancel button: both paths complete in under ~300 ms even at '
          '50K rows. Real apps with multi-second parses should expose '
          'cancellation via raw `Isolate.spawn` + `ReceivePort`.',
      metricsBar: MetricsBar(
        chips: [
          MetricChip(label: 'Rows', value: '${_rowCount ~/ 1000}K'),
          ValueListenableBuilder<int>(
            valueListenable: _lastMainMs,
            builder: (_, ms, _) => MetricChip(
              label: 'Main',
              value: ms == 0 ? '—' : '$ms',
              unit: ms == 0 ? '' : ' ms',
            ),
          ),
          ValueListenableBuilder<int>(
            valueListenable: _lastIsolateMs,
            builder: (_, ms, _) => MetricChip(
              label: 'Isolate',
              value: ms == 0 ? '—' : '$ms',
              unit: ms == 0 ? '' : ' ms',
            ),
          ),
        ],
      ),
      onToggle: _handleToggle,
      body: _ImportBody(
        rowIndex: _rowIndex,
        tier: _tierForMs(_lastMainMs.value),
        busy: _busy,
        contacts: _contacts,
        onSliderChanged: _onSliderChanged,
        onPickCsv: _busy ? null : _requestMainParse,
        modeLabel: 'Main isolate (UI freezes)',
        ctaLabel: 'Pick CSV',
      ),
      fixedBody: _ImportBody(
        rowIndex: _rowIndex,
        tier: _tierForMs(_lastMainMs.value),
        busy: _busy,
        contacts: _contacts,
        onSliderChanged: _onSliderChanged,
        onPickCsv: _busy ? null : _runIsolateParse,
        modeLabel: 'Isolate.run() (UI responsive)',
        ctaLabel: 'Pick CSV (isolate)',
      ),
    );
  }
}

class _ImportBody extends StatelessWidget {
  const _ImportBody({
    required this.rowIndex,
    required this.tier,
    required this.busy,
    required this.contacts,
    required this.onSliderChanged,
    required this.onPickCsv,
    required this.modeLabel,
    required this.ctaLabel,
  });

  final int rowIndex;
  final _Tier tier;
  final bool busy;
  final List<_Contact> contacts;
  final ValueChanged<double> onSliderChanged;
  final VoidCallback? onPickCsv;
  final String modeLabel;
  final String ctaLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Row(
            children: [
              Text(
                modeLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              _TierBadge(tier: tier),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Slider(
            value: rowIndex.toDouble(),
            min: 0,
            max: 2,
            divisions: 2,
            label: '${_rowChoices[rowIndex] ~/ 1000}K rows',
            onChanged: busy ? null : onSliderChanged,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text('1K', style: TextStyle(fontSize: 11, color: Colors.grey)),
              Text('10K', style: TextStyle(fontSize: 11, color: Colors.grey)),
              Text('50K', style: TextStyle(fontSize: 11, color: Colors.grey)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onPickCsv,
              icon: const Icon(Icons.upload_file),
              label: Text(ctaLabel),
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (busy) const LinearProgressIndicator(),
        Expanded(
          child: contacts.isEmpty
              ? _EmptyState(busy: busy)
              : _ContactList(contacts: contacts),
        ),
      ],
    );
  }
}

class _TierBadge extends StatelessWidget {
  const _TierBadge({required this.tier});

  final _Tier tier;

  @override
  Widget build(BuildContext context) {
    final color = switch (tier) {
      _Tier.unknown => Colors.grey,
      _Tier.silent => Colors.green,
      _Tier.warning => Colors.amber,
      _Tier.critical => Colors.red,
    };
    final label = switch (tier) {
      _Tier.unknown => '?',
      _Tier.silent => 'silent',
      _Tier.warning => 'warning',
      _Tier.critical => 'critical',
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.busy});

  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              busy ? Icons.hourglass_top : Icons.contacts_outlined,
              size: 40,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              busy ? 'Parsing...' : 'No contacts yet — tap Pick CSV.',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactList extends StatelessWidget {
  const _ContactList({required this.contacts});

  final List<_Contact> contacts;

  @override
  Widget build(BuildContext context) {
    final preview = contacts.take(50).toList();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Imported ${contacts.length} contacts (showing first 50)',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: preview.length,
            itemBuilder: (context, i) {
              final c = preview[i];
              return ListTile(
                dense: true,
                leading: CircleAvatar(
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.primaryContainer,
                  child: Text(c.name[0]),
                ),
                title: Text(c.name),
                subtitle: Text(c.email),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Pure helpers (top-level for Isolate.run sendability) ────────────

class _Contact {
  const _Contact(this.name, this.email);
  final String name;
  final String email;
}

enum _Tier { unknown, silent, warning, critical }

// Classify from the latest measured main-isolate parse duration rather
// than row count. Detector thresholds are duration-based (>8 ms warning,
// >16 ms critical) — a fast iPhone may parse 50K under 16 ms (warning,
// not critical) and a CPU-throttled Android may parse 1K over 8 ms.
// Row-count mapping over-promises across devices.
_Tier _tierForMs(int ms) {
  if (ms == 0) return _Tier.unknown;
  if (ms <= 8) return _Tier.silent;
  if (ms <= 16) return _Tier.warning;
  return _Tier.critical;
}

// Generates a CSV string in memory. ~50 bytes/row → 50K rows ≈ 2.5 MB.
String _generateCsv(int rows) {
  final b = StringBuffer('id,name,email\n');
  for (var i = 0; i < rows; i++) {
    b.write('$i,User$i,user$i@example.com\n');
  }
  return b.toString();
}

List<_Contact> _parseCsv(String csv) {
  final lines = csv.split('\n');
  final contacts = <_Contact>[];
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) continue;
    final parts = line.split(',');
    if (parts.length < 3) continue;
    contacts.add(_Contact(parts[1], parts[2]));
  }
  return contacts;
}

List<_Contact> _generateAndParse(int rows) => _parseCsv(_generateCsv(rows));
