/// Severity levels for detected performance issues.
enum IssueSeverity { ok, warning, critical }

/// Categories mapping to Flutter rendering pipeline phases.
enum IssueCategory {
  build,
  layout,
  paint,
  raster,
  memory,
  channel,
  font,
  network
}

/// Confidence levels reflecting the strength of evidence behind a detection.
///
/// - [confirmed]: Directly observed runtime condition (e.g. jank frame measured,
///   shader compilation event seen, GC frequency counted).
/// - [likely]: Runtime signal combined with structural evidence (e.g. raster
///   dominance plus expensive render nodes found in tree).
/// - [possible]: Structural heuristic only — pattern found in widget/render
///   tree without runtime confirmation (e.g. non-lazy list, Opacity(0.0)).
enum IssueConfidence { confirmed, likely, possible }

/// The user interaction state when an issue was observed.
enum InteractionContext { idle, scrolling, navigating }

/// Identifies the data source that produced a detection, so the UI can show
/// provenance and users can understand the strength of the evidence.
enum ObservationSource {
  /// Structural tree scan (element inspection).
  structural,

  /// VM Service timeline events.
  vmTimeline,

  /// Debug-only framework callbacks (debugOnRebuildDirtyWidget, etc.).
  debugCallback,

  /// Debug callback data confirmed a structural finding.
  debugCallbackAndStructural,
}

/// Estimated developer effort to apply the suggested fix.
///
/// Human-classified per detector via [FixHintBuilder]. Used by the UI to show
/// effort badges and by consumers to prioritize which fixes to attempt first.
enum FixEffort {
  /// < 5 min: add a parameter, wrap in const, swap a widget.
  quick,

  /// < 30 min: extract widgets, add boundaries, restructure.
  medium,

  /// > 30 min: isolate migration, caching layer, architecture change.
  involved,
}

/// A detected performance issue with actionable fix hint.
class PerformanceIssue {
  const PerformanceIssue({
    required this.severity,
    required this.category,
    required this.confidence,
    required this.title,
    required this.detail,
    required this.fixHint,
    this.stableId,
    this.widgetName,
    this.routeName,
    this.observationSource,
    this.interactionContext,
    this.debugModeDisclaimer = false,
    this.detectedAt,
    this.ancestorChain,
    this.fixEffort,
  });

  /// How severe this issue is (ok, warning, critical).
  final IssueSeverity severity;

  /// Which rendering pipeline phase this issue relates to.
  final IssueCategory category;

  /// Strength of evidence behind this detection.
  final IssueConfidence confidence;

  /// Short human-readable title describing the issue.
  final String title;

  /// Detailed explanation of what was observed.
  final String detail;

  /// Actionable suggestion for how to fix the issue.
  final String fixHint;

  /// Stable identifier that does not change when dynamic values in [title]
  /// update (e.g. rebuild counts, GC frequency). Used by the UI to maintain
  /// checkbox selection across scan cycles. When null, falls back to [title].
  final String? stableId;

  /// Name of the widget most relevant to this issue (if attributable).
  final String? widgetName;

  /// Active route name when this issue was detected.
  final String? routeName;

  /// Data source that produced this detection.
  final ObservationSource? observationSource;

  /// User interaction state when this issue was observed.
  final InteractionContext? interactionContext;

  /// Whether this issue's accuracy is reduced in debug mode.
  final bool debugModeDisclaimer;

  /// Wall-clock time when the issue was first detected.
  final DateTime? detectedAt;

  /// Widget ancestor chain providing source-location context.
  final String? ancestorChain;

  /// Estimated effort to implement the suggested fix.
  /// Null for legacy issues deserialized from JSON without this field.
  final FixEffort? fixEffort;

  Map<String, dynamic> toJson() => {
        'severity': severity.name,
        'category': category.name,
        'confidence': confidence.name,
        'title': title,
        'detail': detail,
        'fixHint': fixHint,
        if (stableId != null) 'stableId': stableId,
        if (widgetName != null) 'widgetName': widgetName,
        if (routeName != null) 'routeName': routeName,
        if (observationSource != null)
          'observationSource': observationSource!.name,
        if (interactionContext != null)
          'interactionContext': interactionContext!.name,
        'debugModeDisclaimer': debugModeDisclaimer,
        if (detectedAt != null) 'detectedAt': detectedAt!.toIso8601String(),
        if (ancestorChain != null) 'ancestorChain': ancestorChain,
        if (fixEffort != null) 'fixEffort': fixEffort!.name,
      };

  factory PerformanceIssue.fromJson(Map<String, dynamic> json) =>
      PerformanceIssue(
        severity: IssueSeverity.values.byName(json['severity'] as String),
        category: IssueCategory.values.byName(json['category'] as String),
        confidence: IssueConfidence.values.byName(json['confidence'] as String),
        title: json['title'] as String,
        detail: json['detail'] as String,
        fixHint: json['fixHint'] as String,
        stableId: json['stableId'] as String?,
        widgetName: json['widgetName'] as String?,
        routeName: json['routeName'] as String?,
        observationSource: json['observationSource'] != null
            ? ObservationSource.values
                .byName(json['observationSource'] as String)
            : null,
        interactionContext: json['interactionContext'] != null
            ? InteractionContext.values
                .byName(json['interactionContext'] as String)
            : null,
        debugModeDisclaimer: json['debugModeDisclaimer'] as bool? ?? false,
        detectedAt: json['detectedAt'] != null
            ? DateTime.parse(json['detectedAt'] as String)
            : null,
        ancestorChain: json['ancestorChain'] as String?,
        fixEffort: json['fixEffort'] != null
            ? FixEffort.values.byName(json['fixEffort'] as String)
            : null,
      );

  PerformanceIssue copyWith({
    IssueSeverity? severity,
    IssueCategory? category,
    IssueConfidence? confidence,
    String? title,
    String? detail,
    String? fixHint,
    String? stableId,
    String? widgetName,
    String? routeName,
    ObservationSource? observationSource,
    InteractionContext? interactionContext,
    bool? debugModeDisclaimer,
    DateTime? detectedAt,
    String? ancestorChain,
    FixEffort? fixEffort,
  }) {
    return PerformanceIssue(
      severity: severity ?? this.severity,
      category: category ?? this.category,
      confidence: confidence ?? this.confidence,
      title: title ?? this.title,
      detail: detail ?? this.detail,
      fixHint: fixHint ?? this.fixHint,
      stableId: stableId ?? this.stableId,
      widgetName: widgetName ?? this.widgetName,
      routeName: routeName ?? this.routeName,
      observationSource: observationSource ?? this.observationSource,
      interactionContext: interactionContext ?? this.interactionContext,
      debugModeDisclaimer: debugModeDisclaimer ?? this.debugModeDisclaimer,
      detectedAt: detectedAt ?? this.detectedAt,
      ancestorChain: ancestorChain ?? this.ancestorChain,
      fixEffort: fixEffort ?? this.fixEffort,
    );
  }

  @override
  String toString() {
    final route = routeName != null ? ', route: $routeName' : '';
    final source =
        observationSource != null ? ', source: $observationSource' : '';
    final interaction =
        interactionContext != null ? ', interaction: $interactionContext' : '';
    final chain = ancestorChain != null ? ', chain: $ancestorChain' : '';
    final effort = fixEffort != null ? ', effort: $fixEffort' : '';
    return 'PerformanceIssue($severity, $category, $confidence, "$title"$route$source$interaction$chain$effort)';
  }
}

extension InteractionContextDisplay on InteractionContext {
  String get displayName => switch (this) {
        InteractionContext.idle => 'idle',
        InteractionContext.scrolling => 'scrolling',
        InteractionContext.navigating => 'route transition',
      };
}
