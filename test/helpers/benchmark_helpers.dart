import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// CI runners are slower — multiply budgets by this factor.
/// Detected via common CI environment variables.
final int budgetMultiplier = () {
  const envVars = ['CI', 'GITHUB_ACTIONS', 'JENKINS_URL', 'GITLAB_CI'];
  return envVars.any((key) => Platform.environment.containsKey(key)) ? 2 : 1;
}();

/// Statistical result from a benchmark run.
class BenchmarkResult {
  const BenchmarkResult({
    required this.avgUs,
    required this.minUs,
    required this.maxUs,
    required this.stdDevUs,
    required this.iterations,
  });

  final double avgUs;
  final double minUs;
  final double maxUs;
  final double stdDevUs;
  final int iterations;

  double get avgMs => avgUs / 1000;
  double get coefficientOfVariation => avgUs > 0 ? stdDevUs / avgUs : 0;
}

/// Builds a mixed tree with StatefulWidgets at regular intervals.
///
/// Pattern per group (5 elements):
///   _BenchStateful > Column > [SizedBox, SizedBox, SizedBox]
///
/// Wrapping: Directionality > Column > [groups...]
/// Total elements ≈ 2 + (groupCount × 5)
///
/// This simulates a realistic app tree where StatefulWidgets own subtrees.
Widget buildMixedTree(int targetElements) {
  final groupCount = (targetElements - 2) ~/ 5;
  return Directionality(
    textDirection: TextDirection.ltr,
    child: Column(
      children: List.generate(
        groupCount,
        (i) => BenchStatefulWidget(key: ValueKey(i)),
      ),
    ),
  );
}

/// Counts actual elements reachable from [context] via visitChildElements.
int countElements(BuildContext context) {
  int count = 0;
  void visitor(Element element) {
    count++;
    element.visitChildren(visitor);
  }

  context.visitChildElements(visitor);
  return count;
}

/// Runs [body] for [warmup] + [iterations], returns average microseconds.
///
/// Prints results for manual inspection when running locally.
double benchmarkUs(
  String label,
  void Function() body, {
  int warmup = 20,
  int iterations = 50,
}) {
  // Warmup — let JIT settle
  for (int i = 0; i < warmup; i++) {
    body();
  }

  final sw = Stopwatch()..start();
  for (int i = 0; i < iterations; i++) {
    body();
  }
  sw.stop();

  final avgUs = sw.elapsedMicroseconds / iterations;
  final avgMs = avgUs / 1000;
  // ignore: avoid_print
  print('  [$label] ${avgMs.toStringAsFixed(2)} ms avg '
      '(${avgUs.toStringAsFixed(0)} µs, $iterations iterations)');
  return avgUs;
}

/// Like [benchmarkUs] but returns full [BenchmarkResult] with variance stats.
///
/// Measures each iteration individually for min/max/stdDev tracking.
BenchmarkResult benchmarkWithStats(
  String label,
  void Function() body, {
  int warmup = 20,
  int iterations = 50,
}) {
  for (int i = 0; i < warmup; i++) {
    body();
  }

  final times = <double>[];
  for (int i = 0; i < iterations; i++) {
    final sw = Stopwatch()..start();
    body();
    sw.stop();
    times.add(sw.elapsedMicroseconds.toDouble());
  }

  final avg = times.reduce((a, b) => a + b) / iterations;
  final min = times.reduce((a, b) => a < b ? a : b);
  final max = times.reduce((a, b) => a > b ? a : b);
  final variance =
      times.map((t) => (t - avg) * (t - avg)).reduce((a, b) => a + b) /
          iterations;
  final stdDev = variance > 0 ? math.sqrt(variance) : 0.0;

  // ignore: avoid_print
  print('  [$label] ${(avg / 1000).toStringAsFixed(2)} ms avg '
      '(\u03c3=${(stdDev / 1000).toStringAsFixed(2)} ms, '
      'min=${(min / 1000).toStringAsFixed(2)}, '
      'max=${(max / 1000).toStringAsFixed(2)}, '
      '$iterations iterations)');

  return BenchmarkResult(
    avgUs: avg,
    minUs: min,
    maxUs: max,
    stdDevUs: stdDev,
    iterations: iterations,
  );
}

/// Minimal StatefulWidget for mixed tree benchmarks.
///
/// Each instance creates 5 elements:
///   BenchStatefulWidget (StatefulElement)
///     > Column
///       > SizedBox, SizedBox, SizedBox
class BenchStatefulWidget extends StatefulWidget {
  const BenchStatefulWidget({super.key});

  @override
  State<BenchStatefulWidget> createState() => _BenchStatefulWidgetState();
}

class _BenchStatefulWidgetState extends State<BenchStatefulWidget> {
  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        SizedBox(),
        SizedBox(),
        SizedBox(),
      ],
    );
  }
}
