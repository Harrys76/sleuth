import 'package:flutter/widgets.dart';

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
  int warmup = 5,
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
