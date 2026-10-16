// The MCP sidecar warns that the issue list is incomplete when the app has
// no VM service link, and names the issues that need one. The sidecar does
// not depend on this package, so it keeps its own copy of that list; this
// test pins the copy to the detectors.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/validation/detector_metadata.dart';

const _advisoryPath =
    'packages/sleuth_mcp/lib/src/tools/launch_mode_advisory.dart';

/// The stable ids in the sidecar's `vmOnlyStableIds` constant, a comma list
/// split across adjacent string literals.
Set<String> _sidecarVmOnlyIds() {
  final source = File(_advisoryPath).readAsStringSync();
  final declaration = RegExp(
    r"const String vmOnlyStableIds =\s*((?:'[^']*'\s*)+);",
  ).firstMatch(source);
  expect(declaration, isNotNull, reason: 'vmOnlyStableIds in $_advisoryPath');
  final joined = RegExp(
    r"'([^']*)'",
  ).allMatches(declaration!.group(1)!).map((m) => m.group(1)!).join();
  return {
    for (final id in joined.split(','))
      if (id.trim().isNotEmpty) id.trim(),
  };
}

void main() {
  test('the sidecar names every stable id of the vmOnly detectors and the '
      'VM paths of rebuild and repaint', () {
    final controller = SleuthController()..initializeDetectorsForTest();
    addTearDown(controller.dispose);
    final expected = <String>{
      for (final detector in controller.detectorsForAudit)
        if (detector.lifecycle == DetectorLifecycle.vmOnly &&
            detector is DetectorMetadataProvider)
          ...?(detector as DetectorMetadataProvider)
              .validationMetadata
              .coveredStableIds,
      // Hybrid detectors whose profile-mode issues come from the VM
      // timeline alone. raster_dominance stays out, because its frame leg
      // runs without a VM link.
      'rebuild_activity',
      'excessive_repaint',
    };
    expect(expected, contains('event_loop_stall'));
    expect(_sidecarVmOnlyIds(), expected);
  });
}
