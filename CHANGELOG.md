## Unreleased

- `gc_pressure` counts each garbage collection once. The VM posts every
  collection once per non-system isolate of the isolate group, so apps using
  `compute` or `Isolate.run` saw the rate multiplied (an iPhone 12 run with
  `Isolate.run` parses received 464 events for 271 collections). The VM
  client now resolves its own isolate with `Service.getIsolateId`, confirms it
  in `getVM`, and drops the copies posted for other isolates. Memory, CPU and
  allocation RPCs use the same id.
- `gc_pressure` splits its window into young-generation collections,
  completed old-generation cycles (`MarkSweep` / `MarkCompact`) and
  concurrent-marking starts (`StartCMark`, new `markStartCount`).
  Concurrent-marking starts were counted as scavenges before.
- `gc_pressure` reports how long GC paused the app in the last 10 s
  (`gcPauseMs`, `gcPausePercent` and a detail sentence), from the VM's
  cumulative pause counters, when every collection in the window has a
  measured pause. `MemoryPressureDetector.gcWindowStats` exposes the window.
- `shader_compilation` detects Impeller OpenGL ES program links
  (`LinkProgram`), the Android fallback backend on emulators, Huawei devices,
  older MediaTek devices and drivers with known bugs.
- The VM client no longer subscribes to the Extension stream unless a caller
  consumes it. The framework posts a `Flutter.Frame` event for every frame
  outside release builds, and the client decoded each one on the UI isolate.
- `heap_growing` has a second, more accurate measurement: the heap left
  right after the idle full collections the VM runs between frames, which
  leaves out garbage the next collection would free. Replayed on iPhone 12
  traces it matches the retained allocation rate within 1 %. While it has
  fresh collections it decides: growth publishes `confirmed`, and a flat
  heap withdraws the issue even when the 500 ms heap-sample regression reads
  above the threshold. Without a fresh verdict (no recent idle collections,
  or a drop such as a page or cache being freed) the heap-sample regression
  decides as before, at `likely` unless idle collections already showed
  the growth in the same episode with no drop since. The new
  measurement ignores the first 30 s after Sleuth starts. Trace records
  name the leg (`heapGrowingLeg`) and stamp
  `observedFloorSlopeBytesPerSec` or `observedSlopeBytesPerSec`.
- StreamResourceDetector reads the allocation profile only while
  `heap_growing` is active, instead of every 10 s in every session. A new
  growth episode starts a new sample window, so `stream_resource_growth`
  appears about 30 s after `heap_growing` at the earliest.
- New `Sleuth.setHeapGrowingLegsForCapture` (capture mode only) records
  one `heap_growing` leg at a time.
- `heap_growing` enrichment reads the allocation profile once instead of
  twice, and waits up to 5 s for it. The ranking already used each class's
  live bytes and instances, so the first read and its accumulator reset did
  nothing, and on an iPhone 12 the profile takes longer than the old 500 ms
  wait. A profile that arrives after the growth episode ended is dropped
  instead of labelling the next episode. `AllocationEntry.instancesDelta` /
  `bytesDelta` are documented as the live counts they hold.
- New `Sleuth.holdAllocationProfileReads` / `releaseAllocationProfileReads`
  (capture mode only) stop Sleuth's own allocation-profile reads and wait for
  one in flight, so a memory capture leg's heap samples do not include their
  decoding.
- Example: the memory capture screen holds those reads and switches
  StreamResourceDetector off for each leg, aborts a leg when a read is still
  in flight after 10 s, starts the at leg at 600 000 B/s, never retries the
  at or above leg at 512 000 B/s or below, marks a below leg on which the
  detector fired as out of band, and records the isolation and the measured
  operator rate in the capture notes. The new
  `ext.sleuthDemo.allocationReads` extension does the same for a measurement
  run.
- `heap_growing.warning` stays `runtimeVerified` with one bracket per leg,
  each backed by its own Flutter 3.47.6 triad (iPhone 12, iOS 17.5) recorded
  with the other leg switched off and the measured operator rate as the
  observed value: floor leg at 573 022 B/s for an operator rate of 572 044 and
  above 779 355 for 781 317; sample leg at 672 185 for 572 489 and above
  796 951 for 781 793; both below legs silent. The previous Flutter 3.41.4 set
  read 1.25 to 1.55 times the operator rate.
- Example: the memory capture screen records one `heap_growing` leg per
  run, keeps the measured operator rate as `expectedMagnitude.observed`, and
  keeps each run's buffers until the screen closes, so their collection
  never lands inside the next run.
- Example: the CSV Import demo's `Isolate.run` path spawns from a synchronous
  helper. A closure created inside the `async` handler captured the
  handler's completer and failed to send.
- Behaviour change: a frame is jank when it misses its deadline. Its build
  must end within the frame budget counted from vsync, start delay
  included, and its raster must fit in the budget. The wait between the end
  of the build and the start of the raster no longer counts; 0.37.0 counted
  the whole span from vsync to the end of the raster. `FrameStats.isJank`
  and `isSevereJank` follow the new rule, so jank counts and percentages are
  not comparable with earlier versions.
- Frame start delay caused by Sleuth is subtracted before the deadline
  check: its tree scans, VM response decoding, profile reads and
  service-extension work, and the time its VM timeline request is in flight
  (at most 25 ms per poll, 60 ms for a full read). The VM holds its timeline
  lock while it writes that response, and on iOS and Android, where the UI
  and platform threads are one thread, a frame whose vsync lands in that
  wait starts late with nothing traced in the gap. An iPhone 12 showed 5 to
  20 ms of such delay on every 500 ms poll. A frame late only because of
  Sleuth counts as Sleuth overhead (`FrameStats.isSleuthOverhead`, new
  `FrameStats.ownStartDelayUs` and `appStartDelayUs`,
  `FrameStatsSummary.sleuthOverheadFrames`, `sleuthOverheadFrames` in route
  sessions' `frameStats` and in the trace args) and is left out of the jank
  percentage and of route health. The cap is a first guess made before the
  response arrives; the next timeline poll measures the stall itself (the
  stretch in which the UI thread recorded no event while Sleuth's request
  was in flight) and the frames still in the buffer are judged again. On a
  Galaxy A07 (Helio G99, Android 16) the stall reached 22 ms at the median
  and 70 ms at most, past the cap. Sleuth keeps its record of its own work
  for 10 s, so a burst of VM messages cannot push it out.
- `jank_detected` details name the bottleneck as UI-bound, raster-bound or
  late start, and a late start gives the delay and Sleuth's share of it.
- Verdicts take their phase from the frame's own threads in every tier. A
  jank frame whose build and raster both fit in the budget started late,
  and its cause is `schedulerDelay`; otherwise the thread that ran over
  decides, and its largest phase names it. The Full tier no longer reads
  the poll batch's phase totals, which add up about 500 ms of frames, as
  the frame's own. `PipelinePhase.pipelineStall` is no longer produced for
  jank frames. The verdict reason gives the start delay with Sleuth's
  share; the per-frame `Bottleneck:` line and the ranking's jank boost
  follow the same rule.
- Behaviour change: CPU attribution of jank verdicts
  (`FrameVerdict.topFunctions`) is off by default; new
  `SleuthConfig.cpuAttribution` turns it on. The VM builds a
  `getCpuSamples` answer on the app's UI isolate: on an iPhone 12 every
  request froze the UI for 250 to 410 ms, even for one frame's window, so
  Sleuth froze the app every 10 s while frames janked. With the option on,
  the first 600 ms of each request count as Sleuth's own work where they
  delay a frame's start or a timer.
- New `event_loop_stall` detector (VM only, Flutter 3.35 and later). The VM
  posts a `Timer` stream event when a timer fires 100 ms or more late.
  Events within 50 ms merge into one stall. Before it is judged, each stall
  is clipped to the first lifecycle change after the app was hidden or
  paused, and debugger pauses (`Debug` stream), hot reloads
  (`IsolateReload` and the reassemble) and Sleuth's own work are taken off
  it. What is left is a warning from 100 ms and critical from 700 ms
  (`DetectorThresholds.stallWarningMs` / `stallCriticalMs`). Events while
  the app is hidden or paused are ignored. The issue holds 10 s after the
  latest stall, a stall on another route starts a new one, and it stamps
  `observedStallMs` and `stallCount`. While it listens, Sleuth runs an
  empty 50 ms timer, because the VM measures a stall from the moment the
  first waiting timer was due: without one an 800 ms freeze read 562 ms on
  an iPhone 12, with a 100 ms timer 750 ms and with the 50 ms timer 757 ms;
  five 150 ms freezes read 115 to 143 ms. `ext.sleuth.diagnose` gains
  `eventLoopStallTimerStream`, `eventLoopStallExcused` and
  `eventLoopStallIgnored`. Causal rule: `event_loop_stall` leads to
  `sustained_jank` (42 rules).
- `expensive_gpu_nodes` reads blur sigma from the filter's fields. Profile
  builds strip `toString`, which the old text match parsed, so every blur
  had an unknown sigma there and a sigma 2 blur was reported. `ImageFilter`
  and `ImageFilterConfig` blurs and compositions are read: two blurs in a
  row draw one of sqrt(a² + b²), a colour filter adds none (so a
  `BackdropFilter` with only a colour filter is no longer reported), a NaN
  or infinite sigma draws nothing, and a composition with a matrix has no
  known sigma and still counts.
- A `BackdropFilter` with `enabled: false` no longer counts as an expensive
  GPU node or toward `missing_repaint_boundary`.
- `missing_repaint_boundary` skips a `CustomPaint` without painters. On
  Android, Flutter 3.47's scroll stretch keeps one around every scrollable
  and sets its painter only while the stretch runs, so every list was
  reported.
- A blur drawn by a Cupertino bar, popup surface or action sheet names its
  owner in the node detail ("drawn by CupertinoTabBar") and does not count
  toward `missing_repaint_boundary`. The fix hint tells the app to give a
  bar an opaque `backgroundColor` (or, for a navigation bar,
  `enableBackgroundFilterBlur: false`) and says a popup's blur lasts only
  while it is shown; a card of only such blurs leaves out the
  RepaintBoundary advice.
- Apps that use the `material_ui` and `cupertino_ui` packages get the same
  treatment as apps that use Material and Cupertino from the SDK: their
  `Scaffold` and `CupertinoPageScaffold` start route sessions, their
  `TabBarView` keeps tab sessions, `setstate_scope` treats their widgets as
  framework widgets, their control painters are framework painters, CPU
  samples in those packages count as framework time, and debug per-widget
  rebuild and paint counts leave out the widgets they build internally
  (Flutter counts every widget created outside the SDK as the app's until
  DevTools sets the project's root directories, so the `AnimatedBuilder`
  inside a `material_ui` progress indicator reported 115 rebuilds per
  second on an iPhone 12). Names are matched exactly, so an app subclass of
  a `material_ui` widget is not recognised. An app widget named `Scaffold`
  is not mistaken for one, in the scan root or in `setstate_scope`: the
  match needs the framework's `ScaffoldState`.
- Example: a migrated-app demo (`material_ui`), a Cupertino blur demo, and
  `ext.sleuthDemo.uiBlock` / `blurProbe` extensions.
- `platform_channel_traffic` counts calls by event time. Each check, once
  per second, counts the call begins in the busiest 1 s span of event time
  that holds a call received since the previous check. It counted whatever
  poll batches arrived within one second of wall time, so a steady 50
  calls/s read 74 on a Galaxy A07 and the iPhone capture's 45 calls/s read
  36. The method counts, call durations and trace args on the card come
  from the same span. Calls the VM client delivers again after a reconnect,
  and calls made before a capture scenario began, do not count. The
  detector keeps the last 10 s of calls, so a check sees a poll that
  covers several seconds, and a call that arrives late counts with the
  calls around it. A late call inside a span already reported at its
  severity or higher adds no second issue, and it does not hide other new
  calls in the same check. A poll with more calls than the detector keeps
  (4096) still reports its busiest span. New
  `PlatformChannelCall.tid` holds the thread of the call's begin, so two
  calls that begin in the same microsecond on different threads keep both
  durations. The triad was re-recorded on Flutter 3.47.6 (iPhone 12,
  iOS 17.5) with evenly spaced calls: below 15 calls/s silent, at 26,
  above 34.
- Evidence tiers by severity: `DetectorMetadata.effectiveTierFor` takes an
  optional `severity`, and a runtimeVerified result then needs a bracket
  for that severity. The platform channel detector's base tier is now
  `reproducerOnly` with a `perStableIdTier` raise for its warning, so its
  critical tier and `excessive_repaint` critical read `reproducerOnly`.
  The ledger moves to 20 / 21 detectors at `reproducerOnly` base and 1 / 21
  at `runtimeVerified` base.
- Behavior change: `http_error_spike` is critical at 10 errors in the 5 s
  window, whatever their status. Five to nine 5xx errors now read warning
  (the 5xx count stays in the detail), so a CI budget with
  `maxCriticalIssues` no longer fails on them.
- `native_memory_growing` needs the process RSS itself to grow. When RSS
  keeps the pages of freed Dart objects, a heap drop of about 25 MB or more
  reads as native growth while the drop sits in the 30 s window (a
  simulated 50 MB drop with flat RSS read 2.5 MB/s for 12 s). On a Galaxy
  A07 the VM returned the pages of a 64 MB drop; that recording replays in
  tests. `HeapSample.nativeBytes` keeps its definition.
- `high_frequency_same_path` counts the largest cluster of requests within
  500 ms of each other; requests at 0, 300, 600 and 700 ms count 3 (they
  counted 2).
- `gc_pressure` gives a new overage a new identity after the window empties,
  also at thresholds of 5/min or less, so the capture path records it.
- Capture mode records no trace events from a detector that threw in the
  last structural scan, matching the published issues.
- Example: `ext.sleuthDemo.retain` retains byte buffers and reports exact
  bytes; its `List<int>` of large ints held 4-byte references on Android
  and reported twice the retained rate.
- Behavior change: `native_memory_growing` needs growth that keeps going.
  The slope must pass 1 MiB/s over the whole 30 s window and over each half
  of it, each half with at least 4 samples, and each slope is the smaller
  of the native and RSS regressions. A one-time jump of D bytes inside the
  window reads about 1.5 x D / 30 s as one slope, so a 25 MB jump passed
  for more than 10 s: opening the GPU and FPS stress demos on a Galaxy A07
  reported native growth. Those recordings now stay silent, and fourteen
  10 MB native allocations 2.5 s apart fire on a Galaxy A07 and an iPhone
  12. Growth needs to continue for about 25 s, and allocations more than
  about 15 s apart can leave one half flat.
- Behavior change: `gc_pressure` counts young-generation collections only,
  and `SleuthConfig.gcRateThresholdPerMin` now defaults to 240 young
  collections a minute (it was 180 events of any kind). An app that sets it
  now gates young collections with it. Each concurrent old-generation cycle
  posts a marking start and a sweep, and an animated screen runs them
  steadily: Live Waveform posted 41 old-generation events in 10 s on an
  iPhone 12 next to 28 scavenges, and read as pressure. Young collections
  follow the allocation rate: the GC Churn demo ran 65 in 10 s on a Galaxy
  A07 and 135 on an iPhone 12. Old-generation cycles, marking starts and
  the pause share stay on the card. The title reads "N young GCs/min". On a
  Galaxy A07 at 90 Hz, Live Waveform ran 41 young collections in 10 s and
  spent 4.9 % of the time in GC pauses, more than the churn demo's 3.9 %,
  and fires.
- Behavior change: `raster_dominance` counts frames that missed their
  deadline on the raster thread. A frame counts when its raster time
  exceeds its own frame budget and `maxFrameRasterFloorUs` and is more than
  2 times its UI time; it counted from 8 ms of raster, so 60 Hz screens
  whose raster fit the frame read as GPU pressure. Three such frames within
  one second warn and 10 are critical (new
  `GpuPressureDetector.criticalRasterDominantFrames`); critical no longer
  needs the frames to be over budget, since all of them are. The detector
  keeps the last second of these frames across scans, so a burst that a
  scan splits counts once, and reports a burst once. Recorded frames replay
  in tests: on a Galaxy A07 at 90 Hz the GPU Pressure, Cupertino blur and
  IntrinsicHeight demos dropped 26 to 54 such frames a second, and other
  screens 5 or fewer. The VM timeline does not pair a frame's raster with
  its UI work, so it sets each raster frame against the UI time of an
  average frame in its poll; it compared one frame's raster with the whole
  poll's UI total, which grows with the frame count, so it almost never
  agreed on an animated screen and read old values on idle polls. With the
  VM timeline connected, one raster frame since the last scan over the
  budget and more than 2 times that UI time makes the issue `confirmed`;
  the VM ratio no longer sets the severity. When no frames arrived since
  the last scan (the jank detector is off), the VM timeline reports alone
  once one poll holds 3 such frames, critical at 10. A route change drops
  the VM timing seen before it. `effectiveMaxFrameRasterFloorUs` is the
  resolved frame budget, or `maxFrameRasterFloorUs` when larger.
- Behavior change: on displays faster than `fpsTarget`, `heavy_compute`
  warns at three quarters of the frame budget, at most 8 ms (it was half
  the budget): 8 ms at 90 Hz and 6.25 ms at 120 Hz, critical at twice that.
  Half the budget flagged builds that left half the frame for layout, paint
  and raster. At the `fpsTarget` budget, with an explicit
  `heavyComputeGapMs` and in capture mode the threshold stays as before:
  8 ms, or the explicit value.
- Behavior change: `jank_detected` and `sustained_jank` judge only the
  frames whose vsync lies within 10 s of the newest frame's, outside
  capture mode. A screen that stops animating draws only Sleuth's own scan
  frames, about one a second, so the 240-frame buffer kept the bad frames
  for minutes and the card stayed after the jank ended. The cards now clear
  about 10 s after the jank stops. Frames without a vsync time still count.
  On such a screen ten frames fill the window, so `jank_detected` also needs
  at least 3 late frames (`FrameTimingDetector.minJankFrameCount`); one or
  two hitches no longer read as 10 to 20 % jank.
- Behavior change: outside capture mode Sleuth reads the VM timeline from
  the VM's `Timeline` stream instead of a `getVMTimeline` request every
  500 ms. The request made the VM write every event in its window while
  the app's threads waited to record theirs. On a Galaxy A07 the 1 s window
  (about 6,900 events) held the raster thread up to 41 ms and delayed frame
  starts up to 60 ms at every poll. An iPhone 12 showed the late starts,
  and Sleuth raised `sustained_jank`, `jank_detected` and `raster_dominance`
  cards for frames it slowed itself. The stream posts each thread's events
  in blocks of 64 as a block fills, which cost the measured frames
  nothing. The 500 ms tick stays and parses the blocks that arrived as one
  batch, so detectors keep their cadence. A thread that writes few events
  holds them in an unfinished block, and any `getVMTimeline` request makes
  the VM post every thread's unfinished block before it answers. So when a
  frame finished more than 250 ms after the newest event seen on the frame
  or raster thread (at most once a second), and at least every 2 s, the
  tick requests an empty window and parses the blocks that arrive with it.
  Capture mode keeps the request, as do sessions whose VM refuses the
  stream or sends no block at all for 10 s while the app draws frames.
  `PollTimings` and the `lastPoll*` / `maxPoll*` diagnose keys describe the
  tick, with the request readings taken from its catch-up read. New
  diagnose keys: `timelineSource`, `streamBlocks`, `streamEvents`,
  `streamEventsDropped`, `catchUpReads`, `lastStreamLagMs`.
- `shader_compilation` marks a compile `keyframe` when a build started
  within 100 ms before it in any of the last 20 timeline batches that held
  builds, not only in the same batch. A pipeline worker's events reach
  Sleuth when the VM posts its timeline block, often a batch after the
  build.
- Only a client's first VM session reads the whole timeline buffer, for
  the engine startup events; a reconnect starts from the last second. A
  whole-buffer read on a Galaxy A07 held the raster thread for 110 ms.
  `onStartupTimelineEvents` runs once per client, as documented.
- The parser finds a stretch in which the frame thread recorded nothing
  across two timeline batches, because it carries each frame thread's open
  idle stretch across calls (`frameThreadIdle`). Before, it lost the part
  before the second batch's first event, and some late starts on a Galaxy
  A07 kept 18 ms of Sleuth's own 36 ms delay as jank.
- The VM timeline parser no longer lets async events move its per-thread
  duplicate cursor. The engine posts `SceneDisplayLag` on the raster
  thread whenever frames are late, as an async pair whose end carries the
  frame's target time, ahead of the thread's next events; the cursor then
  dropped the raster frames that followed as duplicates. On a Galaxy A07
  the GPU Pressure demo parsed 2 raster frames out of 76, so every VM
  raster reading came from the few frames that survived. Async events are
  still dropped when read again.
- Example: the gallery's pages come from Cloudflare's speed-test endpoint,
  because httpbin caps `/bytes/N` at 102,400 bytes and the 1.1 MB page
  never reached the `large_response` threshold. The bad gallery loads more
  pages on its own until its list can scroll (at most 10), so its
  load-on-scroll can start; a pull on a list that cannot scroll no longer
  counts as a scroll to the end, and the list can be pulled to refresh on
  Android. A non-2xx answer is an error, not a page, the request cap has
  its own message with no retry, and a pull at the cap keeps the loaded
  pages. The Memory Pressure demo fills its native buffers with random
  bytes, because iOS compresses zero pages and RSS did not grow.
- Four more family-severity pairs are `runtimeVerified`, each backed by an
  iPhone 12 capture triad on Flutter 3.47.6: `http_error_spike` warning
  (2, 3 and 6 errors), `high_frequency_same_path` warning (2, 3 and 6
  GETs to one path), `platform_channel_traffic` critical (30 calls per
  second with no critical record, then 51 and 68) and `excessive_repaint`
  critical (26.2, 31.8 and 53.6 % of UI-thread time).
- `http_error_spike` stamps `observedErrorCount` and
  `high_frequency_same_path` stamps `observedClusterSize`, each with an
  identity taken from its `detectedAt`. The same-path issue sets
  `captureTraceStableId: 'high_frequency_same_path'`, because its id
  hashes the host and port. `NetworkMonitorDetector.lastObservedErrorCount`
  and `lastObservedSamePathCluster`, with `flushErrorSpikeEvaluation()` and
  `flushSamePathEvaluation()`, hold the peak window and cluster below the
  thresholds too. The error window sorts its records by start time. They
  arrive in completion order, so an error that finished late could be
  counted in one window with errors that started more than 5 s from it.
- `DetectorMetadata.effectiveTierFor` reads a colon-parametric id, such as
  `high_frequency_same_path:<fingerprint>` or
  `tracked_resource_concurrent:<name>`, through its family's tier and
  coverage.
- Example: the network capture screen's loopback server answers a
  requested status, and the screen gains error and same-path modes. The
  platform channel screen gains critical legs at 30, 50 and 90 calls per
  second. The repaint screen gains critical legs, which lay out long
  wrapped texts and draw one per tile, because short texts left the paint
  share near 30 % however many ran. `ext.sleuthDemo.captureLeg` accepts
  repaint critical legs.
- `sustained_jank` critical is `runtimeVerified`, backed by an iPhone 12
  capture triad on Flutter 3.47.6 whose legs inject 2, 3 and 6 severe
  frames (below silent, at 3, above 6). Twenty pairs across 15 stable ids
  are now `runtimeVerified`.
- Example: a sustained_jank capture screen spins the UI thread for 40 ms
  inside chosen ticker frames, judges every frame with its own FrameTiming
  rule, and keeps a leg only when its severe frames are exactly the spin
  frames and the detector's last count equals the spin count. A leg with
  an ambient severe frame is refused.

## 0.37.0

Flutter 3.47 support, more accurate detectors, a cheaper VM poll loop, and a
reworked overlay with accessibility support. The matching sidecar is
`sleuth_mcp` 0.8.0. The
[full release notes](https://github.com/Harrys76/sleuth/blob/main/doc/release_notes/0.37.0.md)
list every change.

### Breaking and behavior changes

- The minimum versions are Dart `^3.8.0` and Flutter `>=3.32.0`, and
  `vm_service` widens to `>=14.0.0 <16.0.0`.
- `rebuild_activity` and `excessive_repaint` measure the share of UI-thread
  time spent building or painting per ~1 s window instead of counts. They warn
  above 10 % and go critical above 30 %
  (`DetectorThresholds.buildTimePercentThreshold` /
  `paintTimePercentThreshold`). `SleuthConfig.rebuildThreshold` and
  `RepaintDetector.paintFrequencyThreshold` now gate only the per-widget debug
  cards.
- Removed: `RebuildDetector.setBaseline`, `baselineRebuildRate`,
  `lastObservedRebuildRate`, `peakObservedRebuildRate`,
  `RepaintDetector.lastObservedPaintCount`, `peakObservedPaintCount` (replaced
  by `last`/`peakObservedBuildPercent` and `last`/`peakObservedPaintPercent`),
  and `CorrelatedFrameData.coverageRatio` (`FrameVerdict.correlationCoverage`
  reports the batch coverage). `FixHintBuilder.rebuildActivity` and
  `excessiveRepaintVm` take percentages.
- `heap_near_capacity` compares process memory (RSS) with the new opt-in
  `DetectorThresholds.memoryBudgetBytes` and stays off until you set it.
  `gc_pressure` fires above 180 GC/min (was 60).
- Issues rank by evidence tier, which combines severity and confidence, so a
  confirmed warning ranks above a possible critical. A warning no longer turns
  critical after 30 scans. Comparing a 0.36 snapshot with a 0.37 one can show
  severity changes from this alone.
- The jank budget follows the measured frame rate, between `fpsTarget` and the
  display's refresh rate (`autoFrameBudget: false` keeps it fixed). At 60 Hz a
  33 ms frame is jank but no longer severe.
- In the causal graph a `possible` cause no longer claims a `likely` or
  `confirmed` effect, and an effect collapses under a single cause only when
  that cause is at least as severe. The graph has 41 rules.
- Debug repaint cards name the likely origin of a layer's repaints, are titled
  "Likely Repaint Origin" and are `likely`. Per-widget debug counts cover only
  widgets your app creates (`DebugInstrumentationConfig.userWidgetsOnly`).
- Platform-channel profiling is opt-in (`SleuthConfig.profilePlatformChannels`),
  and `platform_channel_traffic` triggers on call count only.
- `excessive_keep_alive` ids name the scrollable
  (`excessive_keep_alive:PageView~1`). Hides saved under the old positional ids
  are dropped.
- Encyclopedia entries, fix hints, guides and some overlay titles are reworded
  to match what the detectors do.

### Added

- Overlay: system and predictive back close the innermost layer first; the
  overlay layout, hidden cards, filter and theme survive restarts with
  `SleuthConfig.stateStore`; Hide with Undo and a Hidden list; Copy details;
  severity filter chips; collapsed cards hold their order while the dashboard
  is open; `Sleuth.overlayUiState`.
- Accessibility: overlay text scales from 0.8 to 2.0×, screen-reader labels and
  actions replace dragging, most controls are 48 dp, text meets WCAG AA contrast,
  plus high-contrast presets, a System / Light / Dark toggle, reduced motion
  and Escape. `SleuthThemeData.fromColorScheme` and `fromSeed` build a theme
  from your app's colours.
- AI chat: Stop and Retry, short failure reasons with Copy error, first-token
  and stall timeouts (`AiChatAdapter.firstTokenTimeout` / `stallTimeout`), a
  Session section in the prompt, and conversations kept per card for the
  session. Custom adapters can throw `AiProviderException`.
- `raster_dominance` from per-frame `FrameTiming` without a VM link, and
  `BaseDetector.processFrame(FrameStats)` for custom detectors.
- `non_lazy_shrinkwrap` for shrink-wrapped lists inside a `Column` or `Row`.
- `Sleuth.lastPollTimings` and VM poll costs in `ext.sleuth.diagnose`, which
  also reports `effectiveFrameRateHz`, `frameBudgetUs` and `frameRateSource`.
- `ext.sleuth.issues` carries `vmConnected`.

### Fixed

- On Flutter 3.47, scans no longer abort in bottom-navigation apps
  (`IndexedStack`).
- Sleuth reads the VM timeline incrementally and never clears it, so DevTools
  keeps its view. In capture mode a poll on an idle iPhone 12 screen dropped
  from 117 ms to 6.6 ms. CPU-sample requests are spaced 10 s apart.
- `shader_compilation` reads Impeller Vulkan and Skia build events; it was
  silent on devices.
- Fewer false positives: framework painters, Material's own clips and
  framework-built intrinsics are skipped, `setstate_scope` needs observed
  rebuilds, keep-alive counts the innermost page view, sliver-added repaint
  boundaries are not counted, `uncached_images` measures real decode waste, and
  `large_response` skips images, video, audio and fonts.
- Rebuild and repaint cards no longer flicker at the threshold, and the
  overlay's own widgets are no longer counted as the app's.
- The VM connection survives a single failed poll and tries loopback first
  (wireless iOS), a scan on a quiet screen no longer waits for an unrelated
  repaint, jank is judged per route, and `heavy_compute` emits one issue per
  batch.
- Explanation placeholders are filled in the AI prompt and
  `ext.sleuth.explain`.

### Example and testing

- New Tabbed Shell and Shrink-wrapped Sections demos, an animated GPU demo,
  `ext.sleuthDemo.*` remote-drive extensions, capture screens that check
  provenance and bands before export, and capture triads re-recorded on
  Flutter 3.47.6.
- Wall-clock benchmarks carry the `benchmark` tag and run serially.

`kSleuthPackageVersion` is 0.37.0.

## 0.36.0

Companion package: `sleuth_mcp` is now available — an MCP stdio sidecar that
exposes the `ext.sleuth.*` VM service extensions to AI clients (Claude Code,
Cursor, Zed), so an assistant can query a running app's live performance data in
conversation. Opt-in and versioned independently (see
[`packages/sleuth_mcp/CHANGELOG.md`](packages/sleuth_mcp/CHANGELOG.md), current
0.7.2). The in-app overlay remains sleuth's primary UX.

This release also brings the MCP integration surface and snapshot controls
(consolidates 0.32.0–0.35.0; per-version detail in `CHANGELOG.archive.md`):

- Seven `ext.sleuth.*` extensions — `snapshot`, `issues`, `routeHealth`,
  `explain`, `encyclopedia`, `causalGraph`, `diagnose`. Debug/profile only
  (`kReleaseMode` no-op). Every response stamps `connectionMode`,
  `schemaVersion: 1`, and a per-session `sessionUuid`.
- Wire-shape lock — `doc/mcp_schema.{json,md}` codify the envelope and every
  handler's data shape (nested `recurrenceTrends` / `sessionSummary` /
  `routeSessions` included), audit-enforced.
- Snapshot projection + pagination — `sections` / `maxIssueCount` /
  `maxRouteCount` keep long sessions under the MCP client token cap;
  backward-compatible (no args = full payload).
- `SleuthConfig.showOverlay` (default `true`): set `false` to hide the in-app
  overlay (trigger button + dashboard) while detectors and `ext.sleuth.*` keep
  running — for MCP-only sessions where the AI client is the consumer.

`kSleuthPackageVersion` → 0.36.0; envelope `schemaVersion` stays `1`. Sidecar
`sleuth_mcp` (current 0.7.2) pins 0.36.0.

## 0.30.1

pub.dev README polish — no detector or distribution change.

- `doc/logo.png` now ships in the published archive (`.pubignore` whitelist) so the README hero image renders on pub.dev instead of falling back to the alt text.
- Tests-passing badge refreshed to the current count (3,001).

## 0.30.0

`TrackedResourceDetector.tracked_resource_long_lived.warning` raised to runtimeVerified via `additionalBrackets[0]`. Distribution: 15/20 effective runtimeVerified family-severity pairs across 12 unique stableIds.

- Long-lived bracket: threshold 300 (matches default `longLivedSeconds`), unit `seconds`, atTolerance 0.5 (at-band [300, 450]), aboveCeilingMultiplier 3.0 (ceiling 900). `observedAxisArgKey: 'oldestInstanceAgeSeconds'`, `requireUniqueDetectedAtMicros: true`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures with real-time waits past the 300 s production threshold.
- Detector behaviour change: `_evaluateLongLived` overwrites `longLivedFirstCrossMicros = nowMicros` each sweep (was `??=` first-cross-only). A long-lived overshoot now produces an emission per sweep with monotonically-increasing age — captures get a real ascending-age series (`observedAxisReduction: 'max'` picks the leg-end value), and a lingering leak re-flags every sweep with the current elapsed retention. UI cards unchanged (same stableId, age refreshes).
- `captureTraceStableId: longLivedStableId` re-added to `_evaluateLongLived` so parametric `tracked_resource_long_lived:<name>` emissions route through the bare family for the bracket validator's byte-exact filter.
- New public API: `lastObservedAgeSecondsFor(name)` / `peakObservedAgeSecondsFor(name)` per-name age observables. `_sweep()` records each pass; `untrackAll(name)` drops entries; `resetCaptureState()` clears them.
- Capture screen long-lived legs: register 1 ref + real-time wait (250 / 380 / 600 s for below / at / above) at the production threshold. `dispose()` clears per-name override defensively via `Sleuth.setResourceThreshold(_kResourceName)` (both null = remove).

## 0.29.1

`IssueEncyclopediaPage` "Learn more" navigation now resolves to the correct entry for parametric stableIds (`tracked_resource_concurrent:<name>`, `excessive_keep_alive:<i>`, `excessive_global_keys:<i>`) and dynamic-suffix stableIds (`repaint_debug_<typeName>`, `rebuild_debug_<typeName>`). Previously the page used byte-exact `scrollToStableId` against `IssueExplanationBuilder.allExplanations` (bare-family keys), so parametric/dynamic variants never expanded or scrolled the target entry.

- New public `IssueExplanationBuilder.canonicalId(String)` — strips parametric `:<param>` and dynamic widget-type suffixes, mapping a `PerformanceIssue.stableId` to the encyclopedia key.
- `IssueEncyclopediaPage._scrollTargetKey` getter resolves `widget.scrollToStableId` through `canonicalId`; `initState` `containsKey` check, `_scrollToTarget`, and per-row `isScrollTarget` comparison all use the normalized key.

## 0.29.0

`TrackedResourceDetector.tracked_resource_concurrent.warning` raised to runtimeVerified via `perStableIdTier`. Distribution: 14/20 effective runtimeVerified family-severity pairs across 11 unique stableIds.

- Bracket: threshold 6 (smallest count > default `maxConcurrent` 5 that triggers emission), unit `instances`, atTolerance 0.5 (at-band [6, 9]), aboveCeilingMultiplier 3.0 (ceiling 18). `observedAxisArgKey: 'liveInstanceCount'`, `requireUniqueDetectedAtMicros: true`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures.
- New `PerformanceIssue.captureTraceStableId` optional field. When set, `CaptureHelper.composeIssueEvent` uses it (instead of `stableId`) to compose the `sleuth.issue.<id>.<severity>` trace-event name. Parametric stableId detectors (`tracked_resource_concurrent:<name>`) route the trace event through the bare family so the bracket validator's byte-exact filter matches every member. UI cards still key on the parametric `stableId`; equality + hashCode unchanged.
- Detector capture plumbing: `flushConcurrentEvaluation()` (synchronous sweep, bypasses the 10 s sweep-timer); `untrackAll(name)` (drop bucket + detach Finalizers — leg isolation for capture screens); `resetCaptureState()` (clears per-name observables + every bucket's `concurrentFirstCrossMicros` / `longLivedFirstCrossMicros`, propagated from `SleuthController.resetCaptureState`); per-name getters `lastObservedLiveCountFor(name)` / `peakObservedLiveCountFor(name)` plus aggregate `lastObservedLiveCount` / `peakObservedLiveCount` for back-compat. Capture screens MUST use the per-name getter — the aggregate would track an unrelated bucket if another `Sleuth.trackResource(...)` registration is active.
- `tracked_resource_long_lived` family stays reproducerOnly — 300 s threshold exceeds an on-device scenario window. `_evaluateLongLived` does NOT set `captureTraceStableId`, so its emissions never land as bare-family `sleuth.issue.tracked_resource_long_lived.warning` events in capture mode (which would be unclaimed evidence: no bracket, no `coveredThresholds` entry).
- New `example/lib/demos/tracked_resource_capture_screen.dart`. Per-leg flow: `untrackAll` + clear strong-refs → `suspendNonEssentialTimelineStreams` → `markScenarioBegin` → synchronous allocate + register → `flushConcurrentEvaluation` → 3 × 32 ms frame yields → `flushTimelineNow` → read `peakObservedLiveCountFor(name)` → `markScenarioEnd` → 600 ms drain → `exportCaptureJson`.

## 0.28.0

New `Sleuth.setResourceThreshold(name, {int? maxConcurrent, int? longLivedSeconds})` per-name threshold override for `TrackedResourceDetector`. `trackResource` / `untrackResource` API unchanged.

- **Merge semantics**: omitted or invalid axis preserves the prior value for that axis. Explicit both-null clears the override. Subsequent calls update one axis without losing the other.
- Override is bucket-independent — survives empty-bucket sweep eviction, LRU bucket drops, and `isEnabled = false` toggle. `dispose()` clears.
- Per-axis validation: invalid values (`<= 0`) drop that axis (counted via `droppedOverridesCount`). Cap at 1000 distinct names — new-name overflow silently drops; updates to existing names always succeed. Runtime guard (release-safe).
- Issue `extraTraceArgs` always stamps `effectiveMaxConcurrent` / `effectiveLongLivedSeconds` + `thresholdSource` (`'override'` or `'global'`).
- Pre-init calls (before `Sleuth.init`) drop with a once-per-session debug warning.
- Cross-isolate / `kReleaseMode` no-op (matches `trackResource` shape).

## 0.27.0

New `TrackedResourceDetector` (runtime, opt-in) + public `Sleuth.trackResource` / `Sleuth.untrackResource` API. 19 → 20 detectors.

- `Sleuth.trackResource(name, resource)` registers; tracker keeps `WeakReference` + Finalizer token + first-seen timestamp per registration. Token is the registration identity (allocation-unique, collision-resistant); shared `Finalizer` dispatches release on GC reclaim. `Sleuth.untrackResource(name, resource)` is the optional explicit decrement.
- Two emission paths, both `confirmed`:
  - `tracked_resource_concurrent.warning` — live count under one name > `trackedResourceMaxConcurrent` (default 5).
  - `tracked_resource_long_lived.warning` — single instance alive past `trackedResourceLongLivedSeconds` (default 300 s).
- LRU cap (`trackedResourceMaxDistinctNames`, default 1000) bounds the in-memory bucket map; eviction detaches per-ref Finalizer entries so VM-side state stays bounded. Periodic sweep (`trackedResourceSweepIntervalSeconds`, default 10 s) drives evaluation.
- Pure Dart — no VM service dependency. Cross-isolate registration is a no-op (one controller per isolate).
- Primitive / record targets silently dropped via `droppedTargetsCount`.
- New `CausalGraphRule` edges `tracked_resource_concurrent → heap_growing` and `tracked_resource_long_lived → heap_growing`.
- Tier `reproducerOnly`.

## 0.26.0

`stream_resource_growth.warning` raised to runtimeVerified; `gc_pressure` default 30 → 60/min.

- `StreamResourceDetector`: `stream_resource_growth.warning` → runtimeVerified via `perStableIdTier`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures bracket threshold 50 (unit `instances`) on `topGrowthDelta` axis; atTolerance 0.6, aboveCeilingMultiplier 3.0.
- BREAKING-ISH: magnitude gate switched from summed `netDelta` to dominant-class `top.delta` so the firing axis matches the bracketed axis. Multi-class growth (≥2 watchlist classes ascending) stays as a structural precondition. A balanced 25+25 multi-class workload no longer fires; a single 60-instance leak with any other grower still does.
- `MemoryPressureDetector.gcRateThresholdPerMin` default 30 → 60. Dart's `EventStreams.kGC` emits per young-gen scavenge; ~30/min is steady-state for a moderately allocating UI. Pre-v0.26.0 sensitivity available via `SleuthConfig(gcRateThresholdPerMin: 30)`.
- `StreamResourceCaptureScreen`: 1024 KB/sec byte pressure (256 KB × 4 Hz, 1024-entry rotating cap) reliably re-arms heap_growing inside scenario. Heap-growing readiness wait moved INSIDE scenario span (`markScenarioBegin → resetCaptureState` wipes the prior latch). Direct `flushStreamResourceEvaluation()` dropped — emissions route through `pollStreamResourceAllocationProfileNowWithCapture`. JSON post-process aligns `expectedMagnitude.observed` to detector-stamped `topGrowthDelta`.
- `'instances'` added to `ProfileCaptureSchema.approvedUnits`.

## 0.25.0 (BREAKING)

Multi-parent causal UI + removal of deprecated `rootCauseId` singular field.

**BREAKING** — `PerformanceIssue.rootCauseId` (deprecated since v0.24.2) and `effectiveRootCauseIds` getter removed. JSON `rootCauseId` key no longer read or emitted. Migration:
- `PerformanceIssue(rootCauseId: 'x')` → `rootCauseIds: ['x']` (also covers `copyWith`).
- `issue.rootCauseId` getter → `issue.rootCauseIds?.firstOrNull`.
- v0.24.x-or-earlier snapshots carrying only the singular key must re-export through v0.24.2 (singular → plural coercion) before importing on v0.25.0+. Debug builds emit a warning when fromJson sees the legacy key without the plural.

UI:
- `IssueCard.parentIssues` + `_causedBySection` widget (mirrors `_downstreamSection`; cap at 5 + "and N more"; "(+N suppressed)" annotation when resolved parents < `rootCauseIds.length`).
- `computeVisibleIssues`: ≥2 parents always visible (multi-parent badge); 1 parent collapses under visible parent or surfaces as orphan; 0 parents visible.
- `FloatingIssuesCard`: resolves `parentIssues` via `stableIdToIssue` map; counts unresolved parents.
- `AiContextBuilder` reads `rootCauseIds` directly.

Contract:
- `rootCauseIds` documented invariant: null or non-empty. `fromJson` coerces empty/all-non-string lists to null.
- `_resortRootCauseIdsByCurrentSeverity` keeps `rootCauseIds[0]` highest-severity post-escalation so the "Caused by" badge and AI-prompt cap-at-5 truncation stay accurate.

Tests: +9 (5 `_causedBySection` render + 4 fromJson normalization). Visibility-filter triad updated. ~10 sites migrated singular→plural; singular-only regression tests removed (now compile errors).

## 0.24.2

Multi-parent causal-graph annotation (metadata layer). `CausalGraphRule.apply` now claims every reaching root for each downstream effect, removing the v0.24.1 export-vs-UI asymmetry at the data model layer. Top-level UI rendering of multi-parent badges is deferred to v0.25.0+ — the visibility filter still collapses each downstream under any visible reaching root.

- `PerformanceIssue.rootCauseIds: List<String>?` (plural) joins the schema; singular `rootCauseId` is `@Deprecated` and removed in v0.25.0. Constructor accepts both for back-compat. `fromJson` reads `rootCauseIds` if present, falls back to a singleton-list coercion of `rootCauseId` for v0.24.1-and-earlier snapshots. `toJson` derives singular from `rootCauseIds.first` (post-v0.24.2 canonical) so v0.24.1 readers see the highest-severity root after re-export — eliminates singular/plural drift.
- `CausalGraphRule.apply()`: `downstreamOwners` is now `Map<int, Set<int>>` (multi-parent) instead of `Map<int, int>` (single-owner). BFS from each root accumulates every reach. Each downstream issue carries every reaching root, sorted severity desc then stableId asc. Confidence suppression skips the root's `downstreamIds` listing for a `possible` downstream when any reaching root is `confirmed` or `likely`. Intermediate nodes in multi-hop chains are not surfaced as parents — only originating roots are (matches BFS-from-roots model; surfacing intermediates ships in v0.25.0+).
- `FloatingIssuesCard`: precomputed `stableIdToIssue` map (O(1) downstream lookup, drops itemBuilder cost from O(n²) to O(n)). `computeVisibleIssues` filter extended for multi-parent semantics: a downstream is hidden from top-level when any reaching root is visible; surfaces standalone only when every parent is suppressed.
- `AiContextBuilder`: prompt section uses singular "Root cause issue" / plural "Root cause issues" label depending on `rootCauseIds.length`; caps the joined list at 5 with `(+N more)` suffix.
- Tests: +5 (multi-parent 3×3 fan-in pin, rule-ordering invariant under input-shuffle, multi-parent confidence suppression, full-pipeline integration via correlator, multi-parent visibility-filter triad). ~70 existing assertions migrated from `.rootCauseId` → `.rootCauseIds`.

## 0.24.1

Cross-detector polish for `stream_resource_growth`.

- `CausalGraphRule`: 3 new edges so retained-stream emissions surface as causes of co-firing memory issues. `stream_resource_growth → heap_growing`, `stream_resource_growth → heap_near_capacity`, `stream_resource_growth → gc_pressure`. Mirrors the `uncached_images` and `excessive_keep_alive:*` patterns.
- Edge enumeration is asymmetric across consumers: `CausalGraphRule.activeEdges` (Markdown export, session summaries) returns every distinct cause→effect pair, so a 3-cause × 3-effect memory co-fire surfaces all 9 edges. `CausalGraphRule.apply` (UI annotation) remains single-owner — each downstream gets one `rootCauseId` chosen by severity-then-index, and losing roots render as standalone cards. Multi-parent UI rendering is deferred to a future cut.
- Schema regression guard: `ProfileCaptureSchema.parseFile` round-trip test for the 4 detector-side `extraTraceArgs` keys (`topGrowthClass`, `topGrowthDelta`, `watchlistClassesGrowing`, `samplesInWindow`) so a future schema tightening with a key allowlist cannot silently disable the detector's trace args.
- Tests: +6 (4 `activeEdges` edge tests + 1 negative control, 1 `apply()` single-owner pin for the 3-cause memory fan-in, 1 schema round-trip).

## 0.24.0

New `StreamResourceDetector` (vmOnly) flags likely retained async resources via `getAllocationProfile` class-instance diff, gated on a recent `MemoryPressureDetector.heap_growing` emission. 18 → 19 detectors.

- `StreamResourceDetector`: polls allocation profile at most once per `streamResourceSampleSeconds` (default 10s); tracks `instancesCurrent` for a hardcoded watchlist of dart:async / dart:io / web_socket_channel suffixes (`StreamSubscription`, `_BroadcastSubscription`, `_ControllerSubscription`, `StreamController`, `_SyncBroadcastStreamController`, `_AsyncBroadcastStreamController`, `_WebSocketImpl`, `WebSocketChannel`) plus rxdart `PublishSubject` / `BehaviorSubject` / `ReplaySubject` when `classRef.library.uri` contains rxdart. Emits `stream_resource_growth.warning` only when (a) `MemoryPressureDetector.isHeapGrowingActive` returns true within the recency window (default 30s), (b) ≥2 watchlist classes show ≥3 of 3 ascending transitions across a K=4 sample window, (c) sum of per-class net deltas exceeds `streamResourceMinDelta` (default 50). Confidence `likely`. Tier `reproducerOnly`.
- Suffix-match (`endsWith`) shields against private-class renames across Flutter SDK versions. 20s warmup window suppresses cold-start subscription accumulation; window/warmup re-engage on `pause()` / `resume()` / `resetCaptureState()`. Re-entrancy guard (`_pollInFlight`) + 3-failure backoff (60s default). 3-cycle cooldown holds `dedupIdentityMicros` stable so the controller dedup composite key collapses successive fires to one trace record.
- `MemoryPressureDetector`: new public `bool isHeapGrowingActive([int? windowMicros])` getter backed by `_lastHeapGrowingEmittedAtMicros` stamp. Decoupled from `_issues.any(...)` retention so a long-resolved heap_growing cannot latch downstream gating. Cleared on `vmConnected=false` / `reset()` / `dispose()`.
- `Sleuth.streamResourceDetector` static accessor (kReleaseMode-guarded). `StreamResourceDetector` exported from the public barrel.
- 5 new `DetectorThresholds` fields: `streamResourceSampleSeconds`, `streamResourceMinDelta`, `streamResourceWarmupSeconds`, `streamResourceHeapGrowingRecencyMicros`, `streamResourcePollFailureBackoffSeconds`.
- New `FixHintBuilder.streamResourceGrowth` cross-references `heap_growing` / `native_memory_growing` as alternative memory-pressure causes.
- IssueEncyclopediaPage entry for `stream_resource_growth` in `issue_explanation_builder.dart`.
- Library-URI gate on core watchlist: `endsWith` matches only fire when `classRef.library.uri` is `dart:async`, `package:web_socket_channel`, or (for WebSocket only) `dart:io`. dart:io's `_HttpClientStreamSubscription` is explicitly excluded — it self-cancels on response completion and would otherwise produce false positives on every network-heavy app.
- Cooldown semantics: wall-clock deadline (`cooldownSeconds`, default 30 s) — survives VmService disconnect mid-cooldown without leaving a stale issue pinned to `_issues` until the next non-null poll arrives. Re-emit during cooldown refreshes `detectedAt` (so UI does not show a stale stamp) while preserving `dedupIdentityMicros` for controller composite-key dedup.
- Reset-generation guard: in-flight `_pollAllocationProfile` snapshots `_resetGeneration` at start; if `_clearRetainedState` runs between the `await` and the result handler, the result is discarded. Without this, leg-N-1 sample data could write into leg-N's freshly-cleared `_perClassWindow` and break capture-mode scenario isolation.
- `windowSize` constructor assertion: `assert(windowSize >= 2)` rules out the empty-list `RangeError` path in `_evaluateWindow` if a future caller passes 0 or 1.
- `_ingestProfile` per-poll aggregation: sums `instancesCurrent` across every class that maps to the same suffix bucket and appends exactly one sample per suffix per poll. For suffixes previously seen but absent from the current poll (the leak was fixed and GC reclaimed every instance), appends `0` so a stale ascending window ages out instead of re-firing every cooldown cycle. All-zero windows are dropped to bound map growth.
- `_matchWatchlist` longest-suffix-match: a class named `_SyncBroadcastStreamController` matches the specific suffix instead of being shadowed by the generic `StreamController` bucket. First-match would also collapse multiple distinct controller flavors into one window, corrupting the ascending-transitions check.
- `_dropEmissionState` helper consolidates clears across cooldown lapse + transient gate failure + window underflow paths, eliminating drift between code paths that previously cleared a subset of emission fields.
- `@visibleForTesting` annotation on `allocationProfileFetcherForTest` constructor parameter so production callers cannot inject a custom fetcher.
- Tests: +17 unit (warmup, sample-rate gate, single-class-no-emit, heap_growing-off-no-emit, sub-threshold-no-emit, co-fire emission, extraTraceArgs key set, cooldown stable identity within window, cooldown detectedAt refresh, wall-clock cooldown expiry, non-monotone-no-emit, null-fetcher backoff, rxdart library-URI gate × 2, `_HttpClientStreamSubscription` exclusion, resetCaptureState, disabled, vmConnected-false). +5 reproducer (deliberate-leak harness, heap_growing-off, flat-no-emit, rxdart, cooldown).

## 0.23.0

`GpuPressureDetector.raster_dominance` idle false-positive fixed; `HeavyComputeDetector` issues persist past one VM batch.

- `GpuPressureDetector`: ratio numerator uses MAX-of-frame raster gated by `maxFrameRasterFloorUs` (default 8000us). New ctor param tunable for 120Hz / Impeller / low-power-mode.
- `RenderPipelineAnalyzer`: raster admitted as `suspectedPhase` only when one frame crosses 8000us.
- `HeavyComputeDetector`: emissions persist `emissionPersistence` (default 10s) via monotonic `Stopwatch` — survives VM poll cadence + system clock jumps. Retained state clears on `isEnabled=false` / `vmConnected=false`.
- `PerformanceIssue.sourceRoute`: detectors that retain issues stamp the route at emission. Aggregator prefers `sourceRoute` over live route, so post-emission navigation cannot reattribute. Wired through `HeavyComputeDetector` + `PlatformChannelDetector` via `sourceRouteProvider`.
- CSV Import demo row choices `[50K, 200K, 500K]` + post-parse sort. 500K cap avoids OOM / iOS watchdog.
- Tests: +5 gpu_pressure (idle-suppression, floor-triad, spike+idle, 12ms critical); +7 persistence (heavy_compute Stopwatch TTL × 3, lifecycle clear × 2, route-during-TTL × 2; platform_channel route-during-cooldown × 2).
- Doc cleanup: 21 historical spec files + `HANDOFF.md` removed; example/README aligned with 18-detector + 500K demo cap; README logo path switched to relative (`doc/logo.png`) for pub.dev rendering against private repo. Added Fastlane `TRACK_WIDGET_CREATION` patch tip for iOS profile archives. README accuracy fixes: Repaint detector moved from VM-Only to Hybrid section (matches `DetectorLifecycle.hybrid`); `heavyComputeGapMs` config example corrected to 8 (was drift-stamped 200). Pubspec description sharpened — leads with in-app overlay differentiator, drops abstract layer names.
- `doc/validation_ledger.md` Non-Detector Components: dropped stale v0.16.7 promise; framework live, 0 components registered; tier raises deferred to next non-detector formula change (4 candidates listed: `IssueRanker`, `RouteSession.healthScore`, `RecurrenceTrend`, FPS formulas).
- Reference-device matrix slimmed to **iPhone 12 / iOS 17.5 only** (`approvedDevicePairs`). iPhone 13 mini + Pixel 7 removed — never used by real captures (only synthetic fixtures, swapped). Anchor fixture re-pinned (SHA-256 updated). Android coverage gap explicitly documented in `doc/reference_devices.md`. 5 device-mismatch tests skipped pending second approved device pair. `doc/validation_matrix.md` + `doc/capture_procedure.md` + `example/lib/custom_detectors/README.md` swept for stale 23-detector / iPhone 13 mini / Pixel 7 references.

2,883 tests; `fvm flutter analyze` clean.

## 0.22.0

`sustained_jank.critical` runtimeVerified raise withdrawn. Bracket axis (sliding 240-frame-window severeCount) cannot composably bracket against operator-claimed K — ambient severe frames accumulate in the same window. Future raise needs detector-level baseline subtraction (`RebuildDetector.setBaseline(int)` pattern).

- Removed: 3 `sustained_jank` capture JSONs, `frame_timing_sustained_jank_capture_screen.dart`, example-app tile, retainedOrphans manifest entries.
- Reproducer-tier coverage of `sustained_jank` retained in `test/validation/frame_timing_reproducer_test.dart`.
- Distribution unchanged (12 family-severity pairs across 9 stableIds).
- README distribution paragraph + frame_timing_detector source comment refreshed to current state.

## 0.21.0

`RepaintDetector.excessive_repaint.warning` raised to runtimeVerified via `perStableIdTier` on three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures. Base tier stays `reproducerOnly`; `excessive_repaint_debug` and parametric `repaint_debug_<typeName>` are not over-claimed.

- Capture-mode plumbing: `lastObservedPaintCount` + `peakObservedPaintCount` getters, `flushPaintEvaluation()` (refreshes only `lastObservedPaintCount`; never updates peak so the exported magnitude always matches an emitted `observedPaintCount` arg), `resetCaptureState()` (per-leg accumulator clear, also called from `SleuthController.resetCaptureState` for cross-detector parity). VM emission stamps `extraTraceArgs.observedPaintCount` + `dedupIdentityMicros`.
- Bracket: `threshold: 30 paints`, `bracketAtTolerance: 0.50` (at-band [30, 45]), `aboveCeilingMultiplier: 2.0` (above-band ceiling 60 sits strictly under the `> 60` critical-tier fire boundary). Capture screen mounts 32 distinct `CustomPaint` widget classes so the per-widget debug gate stays sub-threshold and emission flows through the VM aggregate path.
- `Sleuth.repaintDetector` static getter (capture-screen access). `Sleuth.lastCaptureExportFailure` surfaces the most-recent `exportCaptureJson` null-return reason in-app.
- 12 effective runtimeVerified family-severity pairs across 9 unique stableIds. Base distribution unchanged (16/18 reproducerOnly, 2/18 runtimeVerified).

2,870 tests passing; `fvm flutter analyze` clean.

## 0.20.2

Example-app polish. No detector logic, public API, or schema change.

- `example/lib/main.dart` tile subtitles trimmed to ≤40 chars so 360 dp phones render single-line without ellipsis. Combined-chat tile keeps `SetState` (drops `Image`) to advertise actual detector coverage.
- `example/lib/demos/heavy_compute_demo.dart` description drops the hard "300 ms" claim → "complete in under a few hundred ms on modern devices" so CPU-throttled devices don't break the promise.
- `example/lib/demos/network_stress_demo.dart` search builds URL via `Uri.parse(...).replace(queryParameters: {'q': query})` — RFC 3986 percent-encoding for special chars (`+`, `&`, `=`, `#`, unicode).

2,862 unit + integration tests passing; `fvm flutter analyze` clean.

## 0.20.1

`FrameTimingDetector` and `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` on each emission. README + dartdoc gain a "Measurement window" note: Sleuth reports frame total duration from `FrameTiming` (build-to-raster span), not vsync delivery cadence.

- New `DetectorThresholds.startupPhaseWindowSeconds` (default 5). Classification reads `Timeline.now` at emission time — emission-time semantics, not event-time. A startup-phase frame whose callback delivery is delayed past the window boundary tags `'steady'`. Differs from `ShaderJankDetector.shaderWarmupContext` (per-event timestamp); the two tags are related but not aligned at the boundary.
- Buffer-aggregated emissions (`sustained_jank` 60-frame, `rebuild_activity` 1-second, raster-cache 30+ frames) tag from emission-time `Timeline.now`. A buffer straddling the boundary tags `'steady'` once `Timeline.now` exceeds the threshold.
- Null `Sleuth.dartEntryMonotonicUs` (init not called) or negative delta omits the key rather than fabricating a value.
- `rebuild_activity` runtimeVerified bracket axis (`observedRebuildRate`) co-exists with the new key. Audit-gate `validateBracket` reads named keys directly; multi-key emissions remain extractable.
- The tag is observable in capture-mode trace records and audit-gate replay; not serialized into saved JSON snapshots.
- Both detectors expose `appStartMonotonicUsForTest` constructor parameter for deterministic tests.

2,862 unit + integration tests passing; `fvm flutter analyze` clean. No detector logic, public API, or schema-version change.

## 0.20.0

**BREAKING**: 5 low-value detectors removed. Distribution: 23 → 18 detectors.

### Removed

- `DetectorType.animatedBuilder` — subset of `rebuild_detector` (AnimatedBuilder misuse manifests as rebuild storms; covered upstream).
- `DetectorType.opacity` — symptom-of-symptom (`Opacity` → `saveLayer` → jank already caught by `frame_timing.jank_detected`).
- `DetectorType.shallowRebuildRisk` — predictive heuristic; real signal caught by `rebuild_detector` from VM-timeline evidence.
- `DetectorType.nestedScroll` — Flutter's own `Vertical viewport was given unbounded height` diagnostic is more authoritative.
- `DetectorType.globalKey` — correctness lint, not perf; framework throws on duplicate `GlobalKey`.

Orphaned config fields removed: `SleuthConfig.maxGlobalKeys`, `DetectorThresholds.shallowRebuildMaxDepth`, `DetectorThresholds.animatedBuilderMinSubtreeSize`.

### Migration

Drop the 5 removed `DetectorType` references from `enabledDetectors`. `rebuild_detector` + `frame_timing` still surface AnimatedBuilder, opacity-jank, and rebuild-storm patterns from runtime evidence.

```dart
// BEFORE (v0.19.x):
SleuthConfig(enabledDetectors: {
  DetectorType.opacity, DetectorType.rebuild, DetectorType.frameTiming,
});

// AFTER (v0.20.0):
SleuthConfig(enabledDetectors: {
  DetectorType.rebuild, DetectorType.frameTiming,
});
```

v0.19 snapshots remain readable in v0.20 — serialization is `stableId`-keyed; encyclopedia + causal-graph rules retain removed-stableId entries for replay context. Users pinned at `^0.19.x` will not auto-upgrade.

### Distribution

16/18 reproducerOnly base + 2/18 runtimeVerified base. 11 effective runtimeVerified family-severity pairs across 8 unique stableIds (unchanged — none of the 5 removed carried raises).

2,851 unit + integration tests passing; `fvm flutter analyze` clean. Benchmark thresholds in `test/benchmark/` are machine-load-sensitive and may flake on slower hardware.


---

Releases prior to v0.20.0 are archived in [`CHANGELOG.archive.md`](https://github.com/Harrys76/sleuth/blob/main/CHANGELOG.archive.md).
