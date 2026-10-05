// DemoScaffold keeps its header (toggle, instructions, metrics) from
// pushing the demo body off a short screen, such as a phone in
// landscape.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:example/demo_scaffold.dart';

void main() {
  final description = List.filled(
    12,
    'A long instruction line that wraps on a phone screen.',
  ).join(' ');

  Future<void> pumpScaffold(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: DemoScaffold(
          title: 'Demo',
          description: description,
          body: const ColoredBox(color: Colors.red, child: SizedBox.expand()),
          fixedBody: const SizedBox.expand(),
          metricsBar: const MetricsBar(
            chips: [MetricChip(label: 'Rebuilds', value: '12')],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('a landscape phone keeps the demo body on screen', (
    tester,
  ) async {
    await pumpScaffold(tester, const Size(683, 411));
    expect(tester.takeException(), isNull);
    final body = tester.getRect(find.byType(ColoredBox).last);
    expect(body.height, greaterThan(100));
    expect(body.bottom, lessThanOrEqualTo(411));
  });

  testWidgets('the header scrolls to reach the end of the instructions', (
    tester,
  ) async {
    await pumpScaffold(tester, const Size(683, 411));
    final metric = find.byType(MetricChip);
    await tester.scrollUntilVisible(
      metric,
      50,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    expect(tester.getRect(metric).bottom, lessThanOrEqualTo(411));
  });

  testWidgets('a portrait phone shows the header in full', (tester) async {
    await pumpScaffold(tester, const Size(411, 731));
    expect(tester.takeException(), isNull);
    expect(find.text(description), findsOneWidget);
    expect(find.byType(MetricChip), findsOneWidget);
  });
}
