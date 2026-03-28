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
  });

  final IssueSeverity severity;
  final IssueCategory category;
  final IssueConfidence confidence;
  final String title;
  final String detail;
  final String fixHint;

  /// Stable identifier that does not change when dynamic values in [title]
  /// update (e.g. rebuild counts, GC frequency). Used by the UI to maintain
  /// checkbox selection across scan cycles. When null, falls back to [title].
  final String? stableId;
  final String? widgetName;
  final String? routeName;
  final ObservationSource? observationSource;
  final InteractionContext? interactionContext;
  final bool debugModeDisclaimer;
  final DateTime? detectedAt;
  final String? ancestorChain;

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
    return 'PerformanceIssue($severity, $category, $confidence, "$title"$route$source$interaction$chain)';
  }
}

extension InteractionContextDisplay on InteractionContext {
  String get displayName => switch (this) {
        InteractionContext.idle => 'idle',
        InteractionContext.scrolling => 'scrolling',
        InteractionContext.navigating => 'route transition',
      };
}
