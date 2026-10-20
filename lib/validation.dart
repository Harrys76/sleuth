/// Capture and validation tooling for Sleuth's evidence ledger.
///
/// The example app's capture screens and the evidence audits use these
/// names to record and check detector captures. Apps that only run the
/// overlay need `package:sleuth/sleuth.dart` alone.
///
/// This library is not covered by Sleuth's semver promise: a minor release
/// can change or remove any name here. The same holds for main-API members
/// typed with these names, such as `Sleuth.repaintDetector` or
/// `RebuildDetector.validationMetadata`.
library;

export 'src/detectors/frame_timing_detector.dart' show FrameTimingDetector;
export 'src/detectors/gpu_pressure_detector.dart' show GpuPressureDetector;
export 'src/detectors/image_memory_detector.dart' show ImageMemoryDetector;
export 'src/detectors/memory_pressure_detector.dart'
    show MemoryPressureDetector;
export 'src/detectors/repaint_detector.dart' show RepaintDetector;
export 'src/detectors/startup_detector.dart' show StartupDetector;
export 'src/detectors/stream_resource_detector.dart'
    show StreamResourcePollResult;
export 'src/detectors/tracked_resource_detector.dart'
    show TrackedResourceDetector;
export 'src/validation/component_metadata.dart'
    show ComponentMetadata, ComponentMetadataProvider;
export 'src/validation/detector_metadata.dart'
    show BracketSpec, DetectorMetadata, DetectorMetadataProvider;
export 'src/validation/evidence_tier.dart' show EvidenceTier;
export 'src/validation/profile_capture_schema.dart' show ProfileCaptureSchema;
export 'src/vm/poll_timings.dart' show PollTimings;
export 'src/vm/service_extension_handlers.dart' show kSleuthPackageVersion;
