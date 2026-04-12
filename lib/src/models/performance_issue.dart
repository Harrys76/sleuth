import 'allocation_entry.dart';

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
  network,
  startup,
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
///
/// Priority ordering for overlapping states (highest wins):
/// navigating > typing > scrolling > idle > appLifecycle
enum InteractionContext { idle, scrolling, navigating, typing, appLifecycle }

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
    this.topAllocators,
    this.rankingScore,
    this.rankingBreakdown,
    this.rootCauseId,
    this.downstreamIds,
    this.confidenceReason,
    this.packageName,
    this.scaffoldHashKey,
    this.tabVisitIndex,
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

  /// Raw active route name when this issue was detected. Kept verbatim (no
  /// `(tab-N)` suffix) so consumers that group/filter by route key see a
  /// stable string across tab visits. Use [routeDisplayName] to render a
  /// disambiguated label for tab 2+ visits.
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

  /// Top allocating classes when heap growth is detected.
  /// Populated by phase-2 enrichment from getAllocationProfile.
  final List<AllocationEntry>? topAllocators;

  /// Composite ranking score from [IssueRanker].
  /// Populated at export time by [IssueRanker.rankWithScores].
  /// Null for issues that haven't been through the export path.
  final int? rankingScore;

  /// Score breakdown by component: severity, frameImpact, confidence, recurrence.
  /// Each value is the weighted contribution to [rankingScore].
  final Map<String, int>? rankingBreakdown;

  /// StableId of the root-cause issue that explains this one.
  /// Null for root issues and standalone issues (no causal chain).
  /// Set by [CausalGraphRule] during cross-detector correlation.
  final String? rootCauseId;

  /// StableIds of downstream issues caused by this root issue.
  /// Null for non-root issues and standalone issues.
  /// Set by [CausalGraphRule] during cross-detector correlation.
  final List<String>? downstreamIds;

  /// Human-readable explanation of why [confidence] is at its current level.
  /// Set by detectors at issue creation and updated by correlator escalation.
  final String? confidenceReason;

  /// Package name extracted from the leaf element's source location.
  /// Null in profile mode or when source tracking is unavailable.
  final String? packageName;

  /// `identityHashCode` of the innermost visible Scaffold Element when the
  /// issue was observed, or `null` for scaffold-free scans. Paired with
  /// [routeName] to disambiguate issues detected on different tabs that share
  /// a `ModalRoute` (IndexedStack / StatefulShellRoute / CupertinoTabScaffold).
  /// Machine-readable; consumers that want to group strictly by scaffold
  /// identity key on this value alongside [routeName].
  final int? scaffoldHashKey;

  /// 1-indexed visit ordinal copied from the active [RouteSession] when this
  /// issue was observed. `null` when there was no active session (e.g. on an
  /// ignored route). Used by [routeDisplayName] and by the exporter / UI to
  /// distinguish multiple sessions for the same `(routeName, scaffoldHashKey)`.
  final int? tabVisitIndex;

  /// Display label for the route: `routeName` for the first visit, or
  /// `"$routeName (tab-$tabVisitIndex)"` for the 2nd+ visit to the same
  /// `(routeName, scaffoldHashKey)` pair. Returns `null` when [routeName] is
  /// null.
  ///
  /// Use this in UI cards, chat context, and any human-facing surface. Use
  /// raw [routeName] when grouping/filtering programmatically — the display
  /// suffix must not leak into keys, otherwise a route literally named
  /// `"/x (tab-2)"` becomes indistinguishable from a disambiguated `"/x"`.
  String? get routeDisplayName {
    final name = routeName;
    if (name == null) return null;
    final idx = tabVisitIndex;
    if (idx == null || idx <= 1) return name;
    return '$name (tab-$idx)';
  }

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
        if (topAllocators != null)
          'topAllocators': topAllocators!.map((a) => a.toJson()).toList(),
        if (rankingScore != null) 'rankingScore': rankingScore,
        if (rankingBreakdown != null) 'rankingBreakdown': rankingBreakdown,
        if (rootCauseId != null) 'rootCauseId': rootCauseId,
        if (downstreamIds != null) 'downstreamIds': downstreamIds,
        if (confidenceReason != null) 'confidenceReason': confidenceReason,
        if (packageName != null) 'packageName': packageName,
        if (scaffoldHashKey != null) 'scaffoldHashKey': scaffoldHashKey,
        if (tabVisitIndex != null) 'tabVisitIndex': tabVisitIndex,
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
        topAllocators: json['topAllocators'] != null
            ? (json['topAllocators'] as List)
                .map((a) => AllocationEntry.fromJson(a as Map<String, dynamic>))
                .toList()
            : null,
        rankingScore: json['rankingScore'] as int?,
        rankingBreakdown: json['rankingBreakdown'] != null
            ? (json['rankingBreakdown'] as Map<String, dynamic>)
                .map((k, v) => MapEntry(k, v as int))
            : null,
        rootCauseId: json['rootCauseId'] as String?,
        downstreamIds:
            (json['downstreamIds'] as List<dynamic>?)?.cast<String>(),
        confidenceReason: json['confidenceReason'] as String?,
        packageName: json['packageName'] as String?,
        // Defensive casts: malformed JSON (e.g. scaffoldHashKey serialised as
        // a string by a 53-bit-limited JavaScript consumer, or tabVisitIndex
        // arriving as a double) would crash `as int?`. Coerce non-int values
        // to null so one bad payload doesn't poison the whole snapshot.
        scaffoldHashKey: json['scaffoldHashKey'] is int
            ? json['scaffoldHashKey'] as int
            : null,
        tabVisitIndex:
            json['tabVisitIndex'] is int ? json['tabVisitIndex'] as int : null,
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
    List<AllocationEntry>? topAllocators,
    int? rankingScore,
    Map<String, int>? rankingBreakdown,
    String? rootCauseId,
    List<String>? downstreamIds,
    String? confidenceReason,
    String? packageName,
    int? scaffoldHashKey,
    int? tabVisitIndex,
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
      topAllocators: topAllocators ?? this.topAllocators,
      rankingScore: rankingScore ?? this.rankingScore,
      rankingBreakdown: rankingBreakdown ?? this.rankingBreakdown,
      rootCauseId: rootCauseId ?? this.rootCauseId,
      downstreamIds: downstreamIds ?? this.downstreamIds,
      confidenceReason: confidenceReason ?? this.confidenceReason,
      packageName: packageName ?? this.packageName,
      scaffoldHashKey: scaffoldHashKey ?? this.scaffoldHashKey,
      tabVisitIndex: tabVisitIndex ?? this.tabVisitIndex,
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
    final allocs =
        topAllocators != null ? ', allocators: ${topAllocators!.length}' : '';
    return 'PerformanceIssue($severity, $category, $confidence, "$title"$route$source$interaction$chain$effort$allocs)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PerformanceIssue &&
          stableId != null &&
          stableId == other.stableId;

  @override
  int get hashCode => stableId?.hashCode ?? super.hashCode;
}

extension InteractionContextDisplay on InteractionContext {
  String get displayName => switch (this) {
        InteractionContext.idle => 'idle',
        InteractionContext.scrolling => 'scrolling',
        InteractionContext.navigating => 'route transition',
        InteractionContext.typing => 'typing',
        InteractionContext.appLifecycle => 'app lifecycle',
      };
}

extension ObservationSourceDisplay on ObservationSource {
  String get displayName => switch (this) {
        ObservationSource.structural => 'structural scan',
        ObservationSource.vmTimeline => 'VM timeline',
        ObservationSource.debugCallback => 'debug callback',
        ObservationSource.debugCallbackAndStructural =>
          'debug callback + structural',
      };
}
