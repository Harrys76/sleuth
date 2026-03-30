/// Classifies a raw VM timeline event by rendering pipeline phase.
///
/// Separate from [PipelinePhase] — this classifies raw timeline events,
/// not verdict bottleneck phases (no schedulerDelay/pipelineStall/unknown).
enum TimelinePhase { build, layout, paint, raster, shader }

/// A single VM timeline event with its absolute timestamp and duration.
///
/// Used by [FrameEventCorrelator] to match timeline events to specific
/// frames via timestamp overlap with [FrameStats] phase windows.
class PhaseEvent {
  const PhaseEvent({
    required this.phase,
    required this.timestampUs,
    required this.durationUs,
    this.dirtyCount,
    this.dirtyList,
    this.scopeContext,
  });

  /// Which pipeline phase this event belongs to.
  final TimelinePhase phase;

  /// Absolute monotonic clock timestamp in microseconds.
  /// Directly comparable to [FrameStats.buildStartUs] etc.
  final int timestampUs;

  /// Event duration in microseconds.
  final int durationUs;

  /// Number of dirty elements reported in the scope event's args.
  /// Only populated when timeline enrichment is enabled.
  /// Parsed from String (Flutter writes all args as `Map<String, String>`).
  final int? dirtyCount;

  /// Parsed list of dirty widget/RenderObject type names from scope args.
  /// `null` when enrichment is unavailable.
  final List<String>? dirtyList;

  /// The scope context type name (build scope only).
  /// e.g. `"MyApp(dirty)"` from `"scope context"` arg.
  final String? scopeContext;

  /// End timestamp (start + duration).
  int get endUs => timestampUs + durationUs;

  /// Whether this event carries any enrichment data from timeline args.
  bool get hasEnrichment => dirtyCount != null || dirtyList != null;

  Map<String, dynamic> toJson() => {
        'phase': phase.name,
        'timestampUs': timestampUs,
        'durationUs': durationUs,
        if (dirtyCount != null) 'dirtyCount': dirtyCount,
        if (dirtyList != null) 'dirtyList': dirtyList,
        if (scopeContext != null) 'scopeContext': scopeContext,
      };

  factory PhaseEvent.fromJson(Map<String, dynamic> json) => PhaseEvent(
        phase: TimelinePhase.values.byName(json['phase'] as String),
        timestampUs: json['timestampUs'] as int,
        durationUs: json['durationUs'] as int,
        dirtyCount: json['dirtyCount'] as int?,
        dirtyList: (json['dirtyList'] as List<dynamic>?)?.cast<String>(),
        scopeContext: json['scopeContext'] as String?,
      );
}
