import 'dart:async';
import 'dart:collection';

import 'package:meta/meta.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';

/// Opt-in retention tracker. Users register resources via
/// [Sleuth.trackResource]; emits with `confirmed` confidence.
///
/// Emission paths:
/// - [concurrentStableId]: live count under one name exceeds
///   [DetectorThresholds.trackedResourceMaxConcurrent].
/// - [longLivedStableId]: a single instance under one name has been
///   alive past [DetectorThresholds.trackedResourceLongLivedSeconds].
///
/// Storage is keyed by name → `_Bucket` of `WeakReference<Object>`
/// entries. Tracker holds only weak references, so registration cannot
/// prevent GC. Cross-isolate registration is a no-op (each isolate has
/// its own controller).
class TrackedResourceDetector extends BaseDetector
    with DetectorMetadataProvider {
  TrackedResourceDetector({
    int maxConcurrent = 5,
    int longLivedSeconds = 300,
    int maxDistinctNames = 1000,
    int sweepIntervalSeconds = 10,
    DateTime Function()? clock,
  })  : assert(maxConcurrent >= 1, 'maxConcurrent must be >= 1.'),
        assert(longLivedSeconds > 0, 'longLivedSeconds must be > 0.'),
        assert(maxDistinctNames >= 1, 'maxDistinctNames must be >= 1.'),
        assert(sweepIntervalSeconds > 0, 'sweepIntervalSeconds must be > 0.'),
        _maxConcurrent = maxConcurrent,
        _longLivedSeconds = longLivedSeconds,
        _maxDistinctNames = maxDistinctNames,
        _sweepInterval = Duration(seconds: sweepIntervalSeconds),
        _clock = clock ?? DateTime.now,
        super(
          type: DetectorType.trackedResource,
          lifecycle: DetectorLifecycle.runtime,
          name: 'Tracked Resource',
          description: 'Detects retained resources via explicit '
              'Sleuth.track registration.',
        );

  /// StableId for "more than maxConcurrent live instances of the same name".
  static const String concurrentStableId = 'tracked_resource_concurrent';

  /// StableId for "single instance of a name alive past long-lived threshold".
  static const String longLivedStableId = 'tracked_resource_long_lived';

  final int _maxConcurrent;
  final int _longLivedSeconds;
  final int _maxDistinctNames;
  final Duration _sweepInterval;
  final DateTime Function() _clock;

  /// `LinkedHashMap` preserves insertion / re-emit order so eviction
  /// drops the least-recently-emitted bucket on overflow.
  final LinkedHashMap<String, _Bucket> _buckets =
      LinkedHashMap<String, _Bucket>();

  /// Finalizer drives `_recordRelease` when the GC reclaims a tracked
  /// target. Single shared finalizer avoids per-target allocation.
  /// The token is the registration's identity — collision-resistant
  /// because each `_FinalizerToken` is a distinct object instance.
  late final Finalizer<_FinalizerToken> _finalizer = Finalizer<_FinalizerToken>(
    _recordRelease,
  );

  Timer? _sweepTimer;
  bool _isEnabled = true;
  int _droppedTargets = 0;
  int _evictedNames = 0;
  // Incremented on rejected register calls.
  // ignore: prefer_final_fields
  int _droppedOverrides = 0;

  /// Per-name threshold overrides. Kept separate from `_buckets` so
  /// override survives empty-bucket sweep + LRU drop — config, not
  /// registration state.
  final Map<String, _NameOverride> _nameOverrides = {};

  /// Hard cap on the override map. Guards per-instance-name misuse in
  /// release builds where `assert` is stripped.
  static const int _maxNameOverridesCap = 1000;

  final List<PerformanceIssue> _issues = [];

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) {
    if (_isEnabled == value) return;
    _isEnabled = value;
    if (value) {
      _ensureSweepRunning();
    } else {
      _sweepTimer?.cancel();
      _sweepTimer = null;
      _issues.clear();
      // Detach Finalizer entries before clearing so the VM doesn't
      // retain callbacks for refs we just dropped; clear so re-enable
      // starts from a clean slate.
      _dropBucketsAndDetachAllRefs(_buckets.values.toList(growable: false));
      _buckets.clear();
    }
  }

  /// Diagnostic: count of `track` calls dropped because the target
  /// type was unsupported (primitive, record, or `WeakReference`
  /// construction failure).
  @visibleForTesting
  int get droppedTargetsCount => _droppedTargets;

  /// Diagnostic: count of name buckets evicted by the LRU cap.
  @visibleForTesting
  int get evictedNamesCount => _evictedNames;

  /// Diagnostic: count of override-registration calls dropped because
  /// the value was non-positive or the override map cap was reached.
  @visibleForTesting
  int get droppedOverridesCount => _droppedOverrides;

  /// Diagnostic: snapshot of per-name overrides for tests. Does not
  /// expose the live map.
  @visibleForTesting
  Map<String, ({int? maxConcurrent, int? longLivedSeconds})>
      snapshotNameOverrides() {
    return {
      for (final e in _nameOverrides.entries)
        e.key: (
          maxConcurrent: e.value.maxConcurrent,
          longLivedSeconds: e.value.longLivedSeconds,
        ),
    };
  }

  /// Snapshot of currently tracked name → live count. For tests +
  /// demo screens; do not mutate the returned map.
  @visibleForTesting
  Map<String, int> snapshotLiveCounts() {
    final out = <String, int>{};
    for (final entry in _buckets.entries) {
      out[entry.key] = entry.value.liveCount;
    }
    return out;
  }

  /// Override concurrent / long-lived thresholds for [name]. Survives
  /// empty-bucket sweep, LRU drops, and `isEnabled = false` — override
  /// is config, not registration.
  ///
  /// Merge: omitted or invalid axis preserves prior. Explicit both-null
  /// clears. Invalid value (`<= 0`) counts via [droppedOverridesCount].
  /// New-name overflow past [_maxNameOverridesCap] silently drops +
  /// counts; updates to existing names always succeed.
  ///
  /// Public entry point: `Sleuth.setResourceThreshold`.
  void registerNameOverride(
    String name, {
    int? maxConcurrent,
    int? longLivedSeconds,
  }) {
    // Caller intent: both args literally absent → explicit clear.
    // Distinct from validation reducing both to null (which preserves).
    if (maxConcurrent == null && longLivedSeconds == null) {
      _nameOverrides.remove(name);
      return;
    }
    // Per-axis validation: invalid axis drops + counts.
    int? validMax = maxConcurrent;
    int? validLongLived = longLivedSeconds;
    if (validMax != null && validMax < 1) {
      _droppedOverrides++;
      validMax = null;
    }
    if (validLongLived != null && validLongLived < 1) {
      _droppedOverrides++;
      validLongLived = null;
    }
    if (validMax == null && validLongLived == null) {
      // All supplied axes invalid; preserve prior (axis-level no-op).
      return;
    }
    // Merge: omitted / invalid axis preserves the prior entry's value.
    final existing = _nameOverrides[name];
    final mergedMax = validMax ?? existing?.maxConcurrent;
    final mergedLongLived = validLongLived ?? existing?.longLivedSeconds;
    if (mergedMax == null && mergedLongLived == null) {
      // Invalid axes + no prior entry — nothing to store.
      return;
    }
    if (existing == null && _nameOverrides.length >= _maxNameOverridesCap) {
      _droppedOverrides++;
      return;
    }
    _nameOverrides[name] = _NameOverride(
      maxConcurrent: mergedMax,
      longLivedSeconds: mergedLongLived,
    );
  }

  /// Register [resource] under [name]. Repeated `(name, resource)`
  /// pairs are deduped by identity — `identical()` walk over same-name
  /// refs (hash equality cannot stand in for object identity). Held
  /// via [WeakReference] so registration cannot prevent GC.
  ///
  /// Primitives (`num`, `String`, `bool`, `Symbol`) and `WeakReference`
  /// construction failures are silently dropped and counted via
  /// [droppedTargetsCount].
  void track(String name, Object resource) {
    if (!_isEnabled) return;
    // Primitives + records can't be weakly referenced.
    if (resource is num ||
        resource is String ||
        resource is bool ||
        resource is Symbol) {
      _droppedTargets++;
      return;
    }
    final WeakReference<Object> ref;
    try {
      ref = WeakReference<Object>(resource);
    } catch (_) {
      _droppedTargets++;
      return;
    }
    final hash = identityHashCode(resource);
    final bucket = _buckets.putIfAbsent(name, _Bucket.new);
    // Move to MRU position.
    _buckets.remove(name);
    _buckets[name] = bucket;
    // Identity-keyed dedup — Dart allows distinct objects to share an
    // identity hash, so hash-only would silently drop a colliding ref.
    for (final r in bucket.refs) {
      if (identical(r.ref.target, resource)) return;
    }
    final token = _FinalizerToken(name: name, identityHash: hash);
    bucket.add(_TrackedRef(
      ref: ref,
      identityHash: hash,
      firstSeenMicros: _clock().microsecondsSinceEpoch,
      token: token,
    ));
    _finalizer.attach(resource, token, detach: token);
    _enforceLruCap();
    _ensureSweepRunning();
  }

  /// Removes any ref under [name] whose target is `identical` to
  /// [resource] and detaches its [Finalizer] entry. Silent no-op when
  /// [name] is unknown or no identity match found.
  void untrack(String name, Object resource) {
    if (!_isEnabled) return;
    final bucket = _buckets[name];
    if (bucket == null) return;
    final removed = bucket.removeIdentityAndReturnTokens(resource);
    for (final token in removed) {
      _finalizer.detach(token);
    }
    if (bucket.isEmpty) {
      _buckets.remove(name);
    }
  }

  /// Test seam matching the production [Finalizer] callback path.
  /// Locates the registration whose target is `identical` to [resource]
  /// under [name], then dispatches `_recordRelease(token)` against its
  /// token. Deterministically simulates GC reclamation without
  /// depending on VM finalization timing.
  @visibleForTesting
  void simulateFinalizerForTest(String name, Object resource) {
    final bucket = _buckets[name];
    if (bucket == null) return;
    for (final r in bucket.refs) {
      if (identical(r.ref.target, resource)) {
        _recordRelease(r.token);
        return;
      }
    }
  }

  /// Run a sweep immediately (instead of waiting for the timer). Tests
  /// + demo screens call this to evaluate emissions deterministically.
  @visibleForTesting
  void evaluateNowForTest() {
    _sweep();
  }

  void _recordRelease(_FinalizerToken token) {
    final bucket = _buckets[token.name];
    if (bucket == null) return;
    bucket.removeByToken(token);
    if (bucket.isEmpty) {
      _buckets.remove(token.name);
    }
  }

  /// Permanent bucket drop — detaches each stored token before
  /// clearing refs so VM-side finalizer state stays bounded. Used by
  /// LRU eviction, disable, and dispose. Re-MRU moves must NOT call
  /// this (they preserve refs/tokens).
  void _dropBucketsAndDetachAllRefs(Iterable<_Bucket> buckets) {
    for (final bucket in buckets) {
      for (final ref in bucket.refs) {
        _finalizer.detach(ref.token);
      }
      bucket.refs.clear();
    }
  }

  void _enforceLruCap() {
    while (_buckets.length > _maxDistinctNames) {
      final oldest = _buckets.keys.first;
      final bucket = _buckets[oldest]!;
      _dropBucketsAndDetachAllRefs([bucket]);
      _buckets.remove(oldest);
      _evictedNames++;
    }
  }

  void _ensureSweepRunning() {
    if (_sweepTimer != null || !_isEnabled) return;
    _sweepTimer = Timer.periodic(_sweepInterval, (_) => _sweep());
  }

  void _sweep() {
    if (!_isEnabled) return;
    final nowMicros = _clock().microsecondsSinceEpoch;
    final newIssues = <PerformanceIssue>[];
    final emptyKeys = <String>[];
    // Snapshot keys before iteration — `_evaluateConcurrent` /
    // `_evaluateLongLived` mutate the map (LRU re-insert on
    // emission) which would invalidate `_buckets.entries`.
    final namesSnapshot = _buckets.keys.toList(growable: false);

    for (final name in namesSnapshot) {
      final bucket = _buckets[name];
      if (bucket == null) continue;
      bucket.pruneFinalised();
      if (bucket.isEmpty) {
        emptyKeys.add(name);
        continue;
      }
      final concurrentIssue = _evaluateConcurrent(name, bucket, nowMicros);
      if (concurrentIssue != null) newIssues.add(concurrentIssue);
      final longLivedIssue = _evaluateLongLived(name, bucket, nowMicros);
      if (longLivedIssue != null) newIssues.add(longLivedIssue);
    }
    for (final k in emptyKeys) {
      _buckets.remove(k);
    }
    _issues
      ..clear()
      ..addAll(newIssues);
  }

  PerformanceIssue? _evaluateConcurrent(
      String name, _Bucket bucket, int nowMicros) {
    final liveCount = bucket.liveCount;
    final overrideMax = _nameOverrides[name]?.maxConcurrent;
    final effectiveMax = overrideMax ?? _maxConcurrent;
    if (liveCount > effectiveMax) {
      bucket.concurrentFirstCrossMicros ??= nowMicros;
      // Move bucket to MRU on emission.
      _buckets.remove(name);
      _buckets[name] = bucket;
      final (hint, effort) = FixHintBuilder.trackedResourceConcurrent(
        name: name,
        liveCount: liveCount,
      );
      return PerformanceIssue(
        // Parametric stableId so distinct names render as distinct
        // issue cards. Without this, two names sharing the bare
        // family stableId collide in stableId-keyed UI maps and only
        // the last-emitted bucket surfaces.
        stableId: '$concurrentStableId:$name',
        severity: IssueSeverity.warning,
        category: IssueCategory.memory,
        confidence: IssueConfidence.confirmed,
        title: 'Tracked Resource Concurrent: $name '
            '($liveCount live instances)',
        detail: 'Sleuth.track has $liveCount live instances of "$name" '
            '— the bucket is above the configured threshold of '
            '$effectiveMax concurrent. The tracker holds only '
            'WeakReferences, so this is a confirmed retention by user '
            'code: each instance is reachable from somewhere outside '
            'the tracker. Audit the dispose / cancel paths for "$name".',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.structural,
        detectedAt: _clock(),
        dedupIdentityMicros: bucket.concurrentFirstCrossMicros,
        extraTraceArgs: <String, String>{
          'resourceName': name,
          'liveInstanceCount': liveCount.toString(),
          'detectedAtMicros': bucket.concurrentFirstCrossMicros!.toString(),
          'effectiveMaxConcurrent': effectiveMax.toString(),
          'thresholdSource': overrideMax != null ? 'override' : 'global',
        },
        confidenceReason:
            'User-registered Sleuth.track instances exceed concurrent threshold.',
      );
    } else {
      bucket.concurrentFirstCrossMicros = null;
      return null;
    }
  }

  PerformanceIssue? _evaluateLongLived(
      String name, _Bucket bucket, int nowMicros) {
    final overrideLongLived = _nameOverrides[name]?.longLivedSeconds;
    final effectiveLongLived = overrideLongLived ?? _longLivedSeconds;
    final thresholdMicros = effectiveLongLived * 1000000;
    final oldest = bucket.oldestLiveMicros;
    if (oldest == null) {
      bucket.longLivedFirstCrossMicros = null;
      return null;
    }
    final ageMicros = nowMicros - oldest;
    if (ageMicros < thresholdMicros) {
      bucket.longLivedFirstCrossMicros = null;
      return null;
    }
    bucket.longLivedFirstCrossMicros ??= nowMicros;
    _buckets.remove(name);
    _buckets[name] = bucket;
    final ageSeconds = ageMicros ~/ 1000000;
    final (hint, effort) = FixHintBuilder.trackedResourceLongLived(
      name: name,
      ageSeconds: ageSeconds,
    );
    return PerformanceIssue(
      stableId: '$longLivedStableId:$name',
      severity: IssueSeverity.warning,
      category: IssueCategory.memory,
      confidence: IssueConfidence.confirmed,
      title: 'Tracked Resource Long-Lived: $name alive ${ageSeconds}s',
      detail: 'Sleuth.track instance of "$name" has been alive for '
          '$ageSeconds seconds — past the configured long-lived '
          'threshold of $effectiveLongLived seconds. Confirmed retention '
          'via WeakReference + Finalizer: the GC has not reclaimed it, '
          'so something outside the tracker is holding it. If this is '
          'intentional (DI singleton, app-scope service), exclude '
          '"$name" from tracking.',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.structural,
      detectedAt: _clock(),
      dedupIdentityMicros: bucket.longLivedFirstCrossMicros,
      extraTraceArgs: <String, String>{
        'resourceName': name,
        'oldestInstanceAgeSeconds': ageSeconds.toString(),
        'detectedAtMicros': bucket.longLivedFirstCrossMicros!.toString(),
        'effectiveLongLivedSeconds': effectiveLongLived.toString(),
        'thresholdSource': overrideLongLived != null ? 'override' : 'global',
      },
      confidenceReason:
          'User-registered Sleuth.track instance has not been finalised within long-lived threshold.',
    );
  }

  @override
  void dispose() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _dropBucketsAndDetachAllRefs(_buckets.values.toList(growable: false));
    _buckets.clear();
    _issues.clear();
    // dispose() is terminal — drop overrides too. `isEnabled = false`
    // (non-terminal) deliberately preserves overrides as configuration.
    _nameOverrides.clear();
    _droppedOverrides = 0;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.reproducerOnly,
        rationale: 'Pure-Dart, opt-in. User registers via '
            '`Sleuth.trackResource(name, resource)`; tracker keeps '
            '`WeakReference` + Finalizer token + first-seen timestamp '
            'per registration. Token is the registration identity '
            '(allocation-unique, collision-resistant); shared `Finalizer` '
            'dispatches `_recordRelease(token)` on GC reclaim so bucket '
            'count matches reality without retaining the target. '
            'Periodic sweep (default 10 s) evaluates two thresholds: '
            '`tracked_resource_concurrent.warning` when live count > '
            '`maxConcurrent` (default 5); `tracked_resource_long_lived'
            '.warning` when the oldest instance has been alive past '
            '`longLivedSeconds` (default 300). Both `confirmed` '
            'confidence — opt-in registration is an explicit ownership '
            'claim. LRU cap (default 1000) bounds the in-memory bucket '
            'map; eviction also detaches per-ref Finalizer entries so '
            'VM-side state stays bounded. Cross-isolate registration is '
            'a no-op (each isolate has its own controller).',
        reproducerPath: 'test/validation/tracked_resource_reproducer_test.dart',
        coveredStableIds: {
          concurrentStableId,
          longLivedStableId,
        },
      );
}

class _Bucket {
  _Bucket();

  final List<_TrackedRef> refs = [];

  /// First wall-clock micros at which the concurrent threshold was
  /// crossed. Stable while above-threshold; cleared on drop. Used as
  /// `dedupIdentityMicros` so cooldown re-emits collapse to one trace
  /// record per overshoot episode.
  int? concurrentFirstCrossMicros;

  int? longLivedFirstCrossMicros;

  bool get isEmpty => refs.isEmpty;

  int get liveCount => refs.where((r) => r.ref.target != null).length;

  /// Returns the oldest `firstSeenMicros` among still-live refs, or
  /// null if the bucket is empty / all refs collected.
  int? get oldestLiveMicros {
    int? oldest;
    for (final r in refs) {
      if (r.ref.target == null) continue;
      if (oldest == null || r.firstSeenMicros < oldest) {
        oldest = r.firstSeenMicros;
      }
    }
    return oldest;
  }

  void add(_TrackedRef ref) => refs.add(ref);

  /// Removes the single ref whose token is `identical` to [token].
  /// Hash collisions cannot affect this — token instances are
  /// allocation-unique by construction.
  void removeByToken(_FinalizerToken token) {
    refs.removeWhere((r) => identical(r.token, token));
  }

  /// Removes refs whose target is `identical` to [resource] and
  /// returns their finalizer tokens so the caller can detach the
  /// matching VM-side registrations.
  List<_FinalizerToken> removeIdentityAndReturnTokens(Object resource) {
    final removed = <_FinalizerToken>[];
    refs.removeWhere((r) {
      if (identical(r.ref.target, resource)) {
        removed.add(r.token);
        return true;
      }
      return false;
    });
    return removed;
  }

  void pruneFinalised() {
    refs.removeWhere((r) => r.ref.target == null);
  }
}

class _TrackedRef {
  _TrackedRef({
    required this.ref,
    required this.identityHash,
    required this.firstSeenMicros,
    required this.token,
  });

  final WeakReference<Object> ref;
  final int identityHash;
  final int firstSeenMicros;
  final _FinalizerToken token;
}

class _FinalizerToken {
  _FinalizerToken({required this.name, required this.identityHash});

  final String name;
  final int identityHash;
}

/// Per-name threshold override. Either field null = fall back to
/// global default. Both null = no override (entry would be removed
/// from the map).
class _NameOverride {
  _NameOverride({this.maxConcurrent, this.longLivedSeconds});

  final int? maxConcurrent;
  final int? longLivedSeconds;
}
