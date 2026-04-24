// Shared helper for vmOnly / hybrid reproducer tests.
//
// Reproducers feed raw `List<TimelineEvent>` through the real
// `TimelineParser.parse()` into the detector — exercising the
// VM → TimelineParser → detector boundary that direct-construction
// `ParsedTimelineData(...)` tests previously bypassed.
//
// The parser silently drops events that don't match its classification
// allowlist (unknown names, wrong phase codes, missing `'dur'` on `'X'`).
// `parseAndAssertShape` asserts the parser produced exactly the counts
// the caller expected; any drop fails the test with a pointer at
// `[name, ph]` mismatch rather than letting the detector appear to
// misbehave downstream.

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import 'package:sleuth/src/vm/timeline_parser.dart';

export 'structural_reproducer_harness.dart'
    show hasStableId, lacksStableId, hasStableIdPrefix;

/// Construct a single `TimelineEvent` from its JSON fields.
///
/// `TimelineEvent.parse` returns a nullable object — the `!` assertion
/// here fails loudly when a test supplies malformed JSON, instead of
/// feeding a silently-null event into the parser.
///
/// `args` values are strings because Flutter writes all timeline args as
/// `Map<String, String>` (numeric values arrive as `"3"`, not `3`).
TimelineEvent buildEvent({
  required String name,
  required String ph,
  int? dur,
  int? ts,
  String cat = '',
  Map<String, String>? args,
  int pid = 1,
  int tid = 1,
}) {
  return TimelineEvent.parse({
    'name': name,
    'cat': cat,
    'ph': ph,
    if (dur != null) 'dur': dur,
    if (ts != null) 'ts': ts,
    if (args != null) 'args': args,
    'pid': pid,
    'tid': tid,
  })!;
}

/// Expected counts per classified bucket after [TimelineParser.parse].
///
/// Every field is required so a reproducer cannot omit the axis it
/// actually wants to test and accidentally let a silent drop go
/// unnoticed. Set unused fields to 0 explicitly.
typedef ParsedShape = ({
  int buildEventCount,
  int buildScopeCount,
  int layoutCount,
  int paintCount,
  int rasterCount,
  int shaderCount,
  int channelCount,
  int gcCount,
  int phaseEventCount,
});

/// Run [events] through [TimelineParser.parse] and assert the output
/// matches [expected] exactly.
///
/// Fails with the full breakdown when any count is off so the author
/// can see which bucket lost (or gained) events. Returns the parsed
/// data so the caller can continue into the detector.
ParsedTimelineData parseAndAssertShape(
  List<TimelineEvent> events,
  ParsedShape expected,
) {
  final parsed = TimelineParser.parse(events);
  final actual = (
    buildEventCount: parsed.buildEventCount,
    buildScopeCount: parsed.buildScopeDurations.length,
    layoutCount: parsed.flushLayoutDurations.length,
    paintCount: parsed.flushPaintDurations.length,
    rasterCount: parsed.rasterDurations.length,
    shaderCount: parsed.shaderCompileDurations.length,
    channelCount: parsed.platformChannelEvents.length,
    gcCount: parsed.gcEvents.length,
    phaseEventCount: parsed.phaseEvents.length,
  );
  expect(
    actual,
    expected,
    reason: 'TimelineParser output does not match expected shape. '
        'Events were silently dropped or re-classified — check event '
        'name casing, phase code, and presence of `dur` on `ph:"X"`. '
        'Parser accepts name variants for BUILD/LAYOUT/PAINT (v2.x '
        'title case, v3+ uppercase, v3.13+ `(root)` suffix) and '
        'platform channel events with the `Platform Channel send ` '
        'prefix.',
  );
  return parsed;
}
