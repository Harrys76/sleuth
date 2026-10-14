// The jank rule against real frames: the `recentFrames` of the six
// on-device snapshots under test/validation/captures/mcp_snapshots/ (iPhone
// 12, iOS 17.5, 240 frames each, recorded with Sleuth 0.34). They predate
// the per-frame own-work log, so `ownStartDelayUs` is 0 and the deadline
// rule alone decides.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/frame_stats.dart';

const _dir = 'test/validation/captures/mcp_snapshots';

List<FrameStats> _frames(String name) {
  final json =
      jsonDecode(File('$_dir/$name.json').readAsStringSync())
          as Map<String, dynamic>;
  return [
    for (final f in (json['recentFrames'] as List).cast<Map<String, dynamic>>())
      FrameStats.fromJson(f),
  ];
}

void main() {
  // Jank frames per snapshot under the deadline rule. They equal the counts
  // of the earlier total-span rule: no real frame waited long on the
  // hand-off, so dropping it changes nothing here.
  const expected = {
    'snapshot_heavy_compute': 7,
    'snapshot_idle': 0,
    'snapshot_memory': 7,
    'snapshot_recurrence': 14,
    'snapshot_repaint': 12,
    'snapshot_routes': 9,
  };

  for (final MapEntry(key: name, value: jank) in expected.entries) {
    test('$name: $jank jank frames; every one the build or raster alone '
        'misses is a late start', () {
      final frames = _frames(name);
      expect(frames, hasLength(240));
      expect(frames.where((f) => f.isJank), hasLength(jank));
      for (final f in frames) {
        // The hand-off wait never reached a quarter of the budget.
        expect(
          f.buildToRasterGap.inMicroseconds,
          lessThanOrEqualTo(f.frameBudgetUs ~/ 4),
        );
        final perThread =
            f.uiDuration.inMicroseconds > f.frameBudgetUs ||
            f.rasterDuration.inMicroseconds > f.frameBudgetUs;
        if (f.isJank && !perThread) {
          // Jank only because the build started late.
          expect(
            f.vsyncOverhead.inMicroseconds,
            greaterThan(f.frameBudgetUs - f.uiDuration.inMicroseconds),
          );
        }
      }
    });
  }

  test('a per-thread rule would keep 4 of the 49 jank frames', () {
    var deadline = 0, perThread = 0;
    for (final name in expected.keys) {
      for (final f in _frames(name)) {
        if (f.isJank) deadline++;
        if (f.uiDuration.inMicroseconds > f.frameBudgetUs ||
            f.rasterDuration.inMicroseconds > f.frameBudgetUs) {
          perThread++;
        }
      }
    }
    expect(deadline, 49);
    expect(perThread, 4);
  });

  test('if Sleuth\'s own work had covered each late start, the frames '
      'would be Sleuth overhead, not jank', () {
    final frames = _frames('snapshot_recurrence');
    final late = frames.where((f) => f.isJank).toList();
    expect(late, isNotEmpty);
    for (final f in late) {
      final covered = f.copyWith(
        ownStartDelayUs: f.vsyncOverhead.inMicroseconds,
      );
      // A frame whose build or raster ran over stays jank either way.
      final perThread =
          f.uiDuration.inMicroseconds > f.frameBudgetUs ||
          f.rasterDuration.inMicroseconds > f.frameBudgetUs;
      expect(covered.isJank, perThread);
      expect(covered.isSleuthOverhead, !perThread);
    }
  });
}
