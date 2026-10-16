import 'dart:convert';
import 'dart:io';

import 'package:sleuth/src/models/frame_stats.dart';

/// A recorded frame fixture: the frames Sleuth held at one phase of a
/// device walk (`tool/demo_walk.dart --raw`), in frame order, and the
/// expected outcome written when the fixture was made.
({List<FrameStats> frames, Map<String, dynamic> expected}) loadFrameFixture(
  String path,
) {
  final json =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final frames = [
    for (final f in (json['frames'] as List).cast<Map<String, dynamic>>())
      FrameStats.fromJson(f),
  ]..sort((a, b) => a.frameNumber.compareTo(b.frameNumber));
  return (frames: frames, expected: json['expected'] as Map<String, dynamic>);
}
