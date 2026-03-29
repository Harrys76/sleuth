import 'package:vm_service/vm_service.dart'
    show
        ClassRef,
        CpuSample,
        CpuSamples,
        FuncRef,
        LibraryRef,
        NativeFunction,
        ProfileFunction;

import '../models/cpu_attribution.dart';

/// Aggregates raw [CpuSamples] from the VM service into a ranked list
/// of [CpuAttribution] entries by exclusive (self) ticks.
///
/// Pure function class — no state, no VM dependency. Easily testable
/// with synthetic data.
class CpuSampleAggregator {
  const CpuSampleAggregator();

  /// VM tags indicating non-user code (GC, compiler, native, idle).
  static const _excludedVmTags = {
    'GC',
    'CompileOptimized',
    'CompileUnoptimized',
    'Native',
    'Idle',
    'VM',
  };

  /// Maximum call chain depth before truncation.
  static const _maxChainDepth = 5;

  /// Aggregate CPU samples into top-N functions by exclusive ticks.
  ///
  /// Returns an empty list if no usable samples are available.
  List<CpuAttribution> aggregate(CpuSamples cpuSamples, {int topN = 5}) {
    final functions = cpuSamples.functions;
    final samples = cpuSamples.samples;
    if (functions == null || functions.isEmpty) return const [];
    if (samples == null || samples.isEmpty) return const [];

    // Step 1: Count exclusive ticks per function index.
    // Exclusive = function is at the top of the stack (stack[0]).
    final exclusiveCounts = <int, int>{};
    int totalUsableSamples = 0;

    for (final sample in samples) {
      if (_isExcludedSample(sample)) continue;
      final stack = sample.stack;
      if (stack == null || stack.isEmpty) continue;

      final topFunctionIndex = stack[0];
      if (topFunctionIndex < 0 || topFunctionIndex >= functions.length) {
        continue;
      }

      exclusiveCounts[topFunctionIndex] =
          (exclusiveCounts[topFunctionIndex] ?? 0) + 1;
      totalUsableSamples++;
    }

    if (totalUsableSamples == 0) return const [];

    // Step 1b: Count inclusive ticks per function index.
    // Inclusive = function appears anywhere in the stack (deduplicated per sample).
    final inclusiveCounts = <int, int>{};

    for (final sample in samples) {
      if (_isExcludedSample(sample)) continue;
      final stack = sample.stack;
      if (stack == null || stack.isEmpty) continue;

      final seen = <int>{};
      for (final funcIdx in stack) {
        if (funcIdx < 0 || funcIdx >= functions.length) continue;
        if (seen.add(funcIdx)) {
          inclusiveCounts[funcIdx] = (inclusiveCounts[funcIdx] ?? 0) + 1;
        }
      }
    }

    // Step 2: Extract function info and classify as framework vs user code.
    final frameworkCounts = <int, int>{};
    final userCounts = <int, int>{};

    for (final entry in exclusiveCounts.entries) {
      final pf = functions[entry.key];
      final (_, _, libraryUri) = _extractInfo(pf);
      if (_isFrameworkFunction(libraryUri)) {
        frameworkCounts[entry.key] = entry.value;
      } else {
        userCounts[entry.key] = entry.value;
      }
    }

    // Step 3: Apply framework filter.
    // Exclude framework functions unless they dominate >50% of samples.
    final frameworkTotal =
        frameworkCounts.values.fold<int>(0, (sum, c) => sum + c);
    final keepFramework = frameworkTotal > totalUsableSamples * 0.5;

    final filteredCounts =
        keepFramework ? exclusiveCounts : Map<int, int>.from(userCounts);

    if (filteredCounts.isEmpty) return const [];

    // Step 4: Compute percentages, extract chains, and build attributions.
    final totalFiltered =
        filteredCounts.values.fold<int>(0, (sum, c) => sum + c);

    final attributions = <CpuAttribution>[];
    for (final entry in filteredCounts.entries) {
      final pf = functions[entry.key];
      final (functionName, className, libraryUri) = _extractInfo(pf);
      final exclusivePct = (entry.value / totalFiltered) * 100.0;

      // Inclusive uses totalUsableSamples as denominator
      final inclCount = inclusiveCounts[entry.key] ?? 0;
      final inclusivePct = totalUsableSamples > 0
          ? (inclCount / totalUsableSamples) * 100.0
          : 0.0;

      // Clamp: inclusive must be >= exclusive
      final clampedInclusivePct =
          inclusivePct < exclusivePct ? exclusivePct : inclusivePct;

      final callChain = _extractCallChain(
        targetFuncIndex: entry.key,
        samples: samples,
        functions: functions,
      );

      attributions.add(CpuAttribution(
        functionName: functionName,
        className: className,
        libraryUri: libraryUri,
        percentage: exclusivePct,
        inclusivePercentage: clampedInclusivePct,
        callChain: callChain,
      ));
    }

    // Step 5: Sort descending by percentage, take top N.
    attributions.sort((a, b) => b.percentage.compareTo(a.percentage));
    return attributions.take(topN).toList();
  }

  /// Check if a sample should be excluded based on its VM tag.
  bool _isExcludedSample(CpuSample sample) {
    final tag = sample.vmTag;
    if (tag == null || tag.isEmpty) return false;
    return _excludedVmTags.contains(tag);
  }

  /// Check if a library URI belongs to the Dart/Flutter framework.
  bool _isFrameworkFunction(String libraryUri) {
    return libraryUri.startsWith('dart:') ||
        libraryUri.startsWith('package:flutter/');
  }

  /// Extract function name, class name, and library URI from a ProfileFunction.
  (String functionName, String className, String libraryUri) _extractInfo(
    ProfileFunction pf,
  ) {
    final fn = pf.function;
    if (fn is FuncRef) {
      final name = fn.name ?? 'unknown';
      final owner = fn.owner;
      if (owner is ClassRef) {
        return (
          name,
          owner.name ?? '',
          owner.library?.uri ?? pf.resolvedUrl ?? '',
        );
      } else if (owner is LibraryRef) {
        return (name, '', owner.uri ?? pf.resolvedUrl ?? '');
      } else {
        // Owner is FuncRef (closure/nested function) or unknown
        return (name, '', pf.resolvedUrl ?? '');
      }
    } else if (fn is NativeFunction) {
      return (fn.name ?? 'native', '', 'native');
    }
    return ('unknown', '', pf.resolvedUrl ?? '');
  }

  /// Extract the most common call chain for a function from samples where
  /// it appears at the top of the stack.
  ///
  /// Walks each matching stack from top (index 0) upward to find the first
  /// user-authored frame ("user root"). Builds the chain from user root
  /// down to the hot function. Picks the most frequent chain across all
  /// matching samples.
  List<String>? _extractCallChain({
    required int targetFuncIndex,
    required List<CpuSample> samples,
    required List<ProfileFunction> functions,
  }) {
    final chainFrequency = <String, int>{};

    for (final sample in samples) {
      if (_isExcludedSample(sample)) continue;
      final stack = sample.stack;
      if (stack == null || stack.isEmpty || stack[0] != targetFuncIndex) {
        continue;
      }

      // Walk stack from top (0) upward looking for user root
      final rawChain = <String>[];
      int userRootIdx = -1;

      for (var i = 0; i < stack.length; i++) {
        final funcIdx = stack[i];
        if (funcIdx < 0 || funcIdx >= functions.length) break;

        final (funcName, className, libUri) = _extractInfo(functions[funcIdx]);
        final display =
            className.isNotEmpty ? '$className.$funcName' : funcName;
        rawChain.add(display);

        if (userRootIdx == -1 && !_isFrameworkFunction(libUri)) {
          userRootIdx = i;
        }
      }

      if (rawChain.isEmpty) continue;

      // Build chain: from user root down to hot function
      List<String> chain;
      if (userRootIdx == -1) {
        // Framework-only stack — use deepest frame as root, mark it
        chain = rawChain.reversed.toList();
        chain[0] = '${chain[0]} (framework)';
      } else {
        // User root found — chain from user root (inclusive) to top
        chain = rawChain.sublist(0, userRootIdx + 1).reversed.toList();
      }

      // Truncate if needed
      chain = _truncateChain(chain);

      final key = chain.join(' → ');
      chainFrequency[key] = (chainFrequency[key] ?? 0) + 1;
    }

    if (chainFrequency.isEmpty) return null;

    // Pick most common chain
    final bestKey =
        chainFrequency.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    return bestKey.split(' → ');
  }

  /// Truncate chain to [_maxChainDepth] entries, preserving root and hot function.
  List<String> _truncateChain(List<String> chain) {
    if (chain.length <= _maxChainDepth) return chain;
    return [
      chain[0], // user root
      chain[1], // first callee
      '...', // truncation marker
      chain[chain.length - 2], // caller of hot function
      chain.last, // hot function
    ];
  }
}
