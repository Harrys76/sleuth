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
    this.dedupIdentityMicros,
    this.extraTraceArgs,
    this.ancestorChain,
    this.fixEffort,
    this.topAllocators,
    this.rankingScore,
    this.rankingBreakdown,
    this.rootCauseId,
    this.rootCauseIds,
    this.downstreamIds,
    this.confidenceReason,
    this.packageName,
    this.scaffoldHashKey,
    this.tabVisitIndex,
    this.sourceRoute,
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

  /// Wall-clock time when the issue was first detected. Used for
  /// user-facing displays and snapshot exports.
  final DateTime? detectedAt;

  /// Stable per-source-event identifier (microseconds) for capture-mode
  /// dedup. Distinct from [detectedAt] which carries wall-clock
  /// semantics. Detectors observing VM Timeline events derive this
  /// from `event.timestampUs` (monotonic since system boot — NOT epoch
  /// micros). When null, capture-mode dedup falls back to
  /// `detectedAt.microsecondsSinceEpoch`.
  ///
  /// Separating dedup identity from wall-clock prevents the v0.18.2
  /// regression where exporting `detectedAt.toIso8601String()` would
  /// ship 1970-era timestamps for any detector that overloaded
  /// detectedAt with monotonic VM time.
  final int? dedupIdentityMicros;

  /// Detector-supplied extra args merged into the capture-mode trace
  /// event. Used by detectors that want to expose their authoritative
  /// observed value (e.g. `_recentCallCount` for PlatformChannel) so
  /// the audit-gate can cross-check the operator's reported magnitude
  /// against what the detector actually saw at fire time. Values are
  /// strings because Flutter's `Timeline.instantSync` arg encoding
  /// stringifies every value once on its way to the engine. When null,
  /// no extra args are merged (default for detectors without an
  /// observed-value boundary worth pinning).
  final Map<String, String>? extraTraceArgs;

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

  /// StableId of the single root-cause issue that explains this one.
  ///
  /// **Deprecated** in v0.24.2 in favor of [rootCauseIds] (plural). The
  /// multi-parent annotation pipeline writes only [rootCauseIds]; this
  /// field is no longer populated by [CausalGraphRule.apply]. Existing
  /// readers should migrate to [rootCauseIds]. Removed in v0.25.0.
  ///
  /// Null for root issues, standalone issues, and any issue produced
  /// after v0.24.2.
  @Deprecated(
      'Use rootCauseIds (plural). Removed in v0.25.0. apply() writes only '
      'the plural field starting v0.24.2.')
  final String? rootCauseId;

  /// StableIds of every root-cause issue that explains this one.
  /// Multiple parents are possible when distinct upstream causes co-fire
  /// against the same downstream effect (e.g. `stream_resource_growth`,
  /// `uncached_images`, and `excessive_keep_alive:*` all causing
  /// `heap_growing`).
  ///
  /// Null for root issues and standalone issues (no causal chain). Set by
  /// [CausalGraphRule] during cross-detector correlation. Order is
  /// deterministic: severity descending, then stableId ascending.
  final List<String>? rootCauseIds;

  /// Canonical read accessor for the multi-parent causal annotation.
  /// Falls back from [rootCauseIds] (plural, v0.24.2+) to `rootCauseId`
  /// (singular, deprecated, v0.24.1-) coerced as a singleton list. Use
  /// this accessor in consumers — direct field access on [rootCauseIds]
  /// bypasses the back-compat coercion and silently breaks for callers
  /// still on the deprecated singular constructor.
  List<String>? get effectiveRootCauseIds {
    if (rootCauseIds != null) return rootCauseIds;
    // ignore: deprecated_member_use_from_same_package
    final singular = rootCauseId;
    return singular == null ? null : <String>[singular];
  }

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

  /// Route name captured by the detector at emission time, before the
  /// controller's aggregate-cycle stamp overwrites [routeName] with the
  /// CURRENTLY active route. Detectors that retain issues across batches
  /// (TTL persistence, cooldown suppression) MUST populate this so a
  /// post-emission navigation does not reattribute the issue to the new
  /// route. The aggregator prefers `sourceRoute` over the live route when
  /// stamping. Null for one-shot per-batch detectors that never persist
  /// across navigation.
  final String? sourceRoute;

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
        // Canonical post-v0.24.2 emission: derive singular from plural so
        // v0.24.1-and-earlier readers see the first reaching root (sorted
        // severity desc → stableId asc). Eliminates drift between the two
        // fields when apply() rewrites only the plural form on a previously
        // legacy-stamped issue.
        if (rootCauseIds != null && rootCauseIds!.isNotEmpty)
          'rootCauseId': rootCauseIds!.first,
        if (rootCauseIds == null &&
            // ignore: deprecated_member_use_from_same_package
            rootCauseId != null)
          // ignore: deprecated_member_use_from_same_package
          'rootCauseId': rootCauseId,
        if (rootCauseIds != null) 'rootCauseIds': rootCauseIds,
        if (downstreamIds != null) 'downstreamIds': downstreamIds,
        if (confidenceReason != null) 'confidenceReason': confidenceReason,
        if (packageName != null) 'packageName': packageName,
        if (scaffoldHashKey != null) 'scaffoldHashKey': scaffoldHashKey,
        if (tabVisitIndex != null) 'tabVisitIndex': tabVisitIndex,
        if (sourceRoute != null) 'sourceRoute': sourceRoute,
      };

  /// Deserializes a [PerformanceIssue] from a JSON map.
  ///
  /// **v0.16.0 scope note — imported snapshots are lossy.** Schema drift in
  /// required enum fields (`severity`, `category`, `confidence`) falls back
  /// to neutral defaults (`warning` / `build` / `possible`) rather than
  /// throwing. Drifted values in required string fields (`title`, `detail`,
  /// `fixHint`) currently pass through raw `as String` casts and will throw
  /// on type mismatch. This path exists for test round-trips and debug
  /// tooling; it is **not a first-class consumer surface** in v0.16.0.
  ///
  /// A drifted `severity` silently imported as `warning` cascades into
  /// consumer surfaces (issue ranker 100× weight, health-score 30-point
  /// critical penalty, trigger-button red/green badge, duration escalation).
  /// Do not feed untrusted or cross-version snapshots into `fromJson` in
  /// production.
  ///
  /// First-class import with explicit drift semantics (skip-on-drift or
  /// throw-on-drift with caller control) ships in v0.17 alongside the MCP
  /// server milestone.
  factory PerformanceIssue.fromJson(Map<String, dynamic> json) =>
      PerformanceIssue(
        // Required enums fall back to neutral defaults on schema drift
        // (renamed value, numeric coercion, missing key) instead of
        // throwing and poisoning the whole snapshot. Matches the
        // per-entry defensive-cast policy applied to `topAllocators`.
        severity: _tryParseEnum(IssueSeverity.values, json['severity']) ??
            IssueSeverity.warning,
        category: _tryParseEnum(IssueCategory.values, json['category']) ??
            IssueCategory.build,
        confidence: _tryParseEnum(IssueConfidence.values, json['confidence']) ??
            IssueConfidence.possible,
        title: json['title'] as String,
        detail: json['detail'] as String,
        fixHint: json['fixHint'] as String,
        stableId: json['stableId'] as String?,
        widgetName: json['widgetName'] as String?,
        routeName: json['routeName'] as String?,
        observationSource:
            _tryParseEnum(ObservationSource.values, json['observationSource']),
        interactionContext: _tryParseEnum(
            InteractionContext.values, json['interactionContext']),
        debugModeDisclaimer: json['debugModeDisclaimer'] as bool? ?? false,
        // Guard against FormatException on malformed ISO strings (e.g. a
        // JS consumer stamping a non-ISO date, an IDE MCP re-exporter
        // truncating to date-only, or any hand-crafted payload). Same
        // schema-drift tolerance as the enum fields above — drops to
        // null instead of poisoning the whole snapshot.
        detectedAt: json['detectedAt'] is String
            ? DateTime.tryParse(json['detectedAt'] as String)
            : null,
        ancestorChain: json['ancestorChain'] as String?,
        fixEffort: _tryParseEnum(FixEffort.values, json['fixEffort']),
        // Defensive per-entry parsing: `AllocationEntry.fromJson` uses
        // strict `as` casts on every required field, so a single malformed
        // entry (e.g. `{'className': 42}` from a JS consumer that coerced
        // a stringified class name, or a schema drift that renamed a key)
        // would throw and poison the entire deserialization. Wrap each
        // entry in a try/catch and drop offenders instead of failing the
        // whole snapshot.
        topAllocators: json['topAllocators'] is List
            ? _tryParseAllocationEntries(json['topAllocators'] as List)
            : null,
        rankingScore:
            json['rankingScore'] is int ? json['rankingScore'] as int : null,
        rankingBreakdown: json['rankingBreakdown'] is Map<String, dynamic>
            ? {
                for (final entry
                    in (json['rankingBreakdown'] as Map<String, dynamic>)
                        .entries)
                  if (entry.value is int) entry.key: entry.value as int,
              }
            : null,
        // Plural takes precedence; singular falls back as a singleton list
        // for v0.24.1-and-earlier snapshots that only carried `rootCauseId`.
        // Both keys never coexist in v0.24.2+ output, but the dual-read
        // path means re-importing an old snapshot composes cleanly with
        // multi-parent UI rendering.
        // ignore: deprecated_member_use_from_same_package
        rootCauseId: json['rootCauseId'] as String?,
        rootCauseIds: json['rootCauseIds'] is List
            ? (json['rootCauseIds'] as List).whereType<String>().toList()
            : (json['rootCauseId'] is String
                ? <String>[json['rootCauseId'] as String]
                : null),
        downstreamIds: json['downstreamIds'] is List
            ? (json['downstreamIds'] as List).whereType<String>().toList()
            : null,
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
        sourceRoute: json['sourceRoute'] as String?,
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
    int? dedupIdentityMicros,
    Map<String, String>? extraTraceArgs,
    String? ancestorChain,
    FixEffort? fixEffort,
    List<AllocationEntry>? topAllocators,
    int? rankingScore,
    Map<String, int>? rankingBreakdown,
    String? rootCauseId,
    List<String>? rootCauseIds,
    List<String>? downstreamIds,
    String? confidenceReason,
    String? packageName,
    int? scaffoldHashKey,
    int? tabVisitIndex,
    String? sourceRoute,
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
      // Preserve stable per-source-event identity through clones.
      // MemoryPressure's `enrichHeapGrowingIssue` re-clones the issue
      // to attach top-allocator data — without this propagation the
      // clone silently drops the dedup identity, breaking capture-mode
      // composite-key dedup for any subsequent emission.
      dedupIdentityMicros: dedupIdentityMicros ?? this.dedupIdentityMicros,
      extraTraceArgs: extraTraceArgs ?? this.extraTraceArgs,
      ancestorChain: ancestorChain ?? this.ancestorChain,
      fixEffort: fixEffort ?? this.fixEffort,
      topAllocators: topAllocators ?? this.topAllocators,
      rankingScore: rankingScore ?? this.rankingScore,
      rankingBreakdown: rankingBreakdown ?? this.rankingBreakdown,
      // ignore: deprecated_member_use_from_same_package
      rootCauseId: rootCauseId ?? this.rootCauseId,
      rootCauseIds: rootCauseIds ?? this.rootCauseIds,
      downstreamIds: downstreamIds ?? this.downstreamIds,
      confidenceReason: confidenceReason ?? this.confidenceReason,
      packageName: packageName ?? this.packageName,
      scaffoldHashKey: scaffoldHashKey ?? this.scaffoldHashKey,
      tabVisitIndex: tabVisitIndex ?? this.tabVisitIndex,
      sourceRoute: sourceRoute ?? this.sourceRoute,
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

/// Parse a raw JSON list into `List<AllocationEntry>`, dropping entries
/// that fail `AllocationEntry.fromJson`'s strict casts instead of letting
/// one malformed entry abort the whole snapshot. Returns null when no
/// entries survive, matching the field's nullable contract.
///
/// Only payload-shape failures are swallowed: `TypeError` (the most
/// common schema-drift shape — e.g. `{'className': 42}` failing
/// `as String`) and `Exception` subclasses (`FormatException`,
/// `ArgumentError`-as-Exception, parse failures). `StackOverflowError`,
/// `OutOfMemoryError`, `StateError`, and other `Error` subclasses
/// propagate because they signal VM instability or genuine programmer
/// bugs, not payload drift.
List<AllocationEntry>? _tryParseAllocationEntries(List raw) {
  final out = <AllocationEntry>[];
  for (final item in raw) {
    if (item is! Map<String, dynamic>) continue;
    try {
      out.add(AllocationEntry.fromJson(item));
    } on TypeError catch (_) {
      // JS numeric coercion, renamed field type, etc.
    } on Exception catch (_) {
      // FormatException, ArgumentError, other parse drift.
    }
  }
  return out.isEmpty ? null : out;
}

/// Guarded enum parsing: returns the matching enum value, or null when
/// `raw` is missing, non-String, or not a legal name. Callers supply a
/// fallback via `??` for required fields so one renamed value doesn't
/// poison the whole snapshot.
T? _tryParseEnum<T extends Enum>(List<T> values, Object? raw) {
  if (raw is! String) return null;
  try {
    return values.byName(raw);
  } on ArgumentError {
    return null;
  }
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
