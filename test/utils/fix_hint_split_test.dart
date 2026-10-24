import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/utils/fix_hint_builder.dart';
import 'package:sleuth/src/utils/fix_hint_split.dart';

/// Rewrites the reviewed table instead of comparing against it:
/// `fvm flutter test test/utils/fix_hint_split_test.dart
/// --dart-define=UPDATE_FIX_SPLIT=true`. Review the diff before committing.
const _update = bool.fromEnvironment('UPDATE_FIX_SPLIT');

const _fixture = 'test/utils/_fixtures/fix_hint_split.txt';

const _chain = 'MyApp > HomePage > FeedList (feed_list.dart:42)';

/// Every public [FixHintBuilder] method, called with fixed arguments.
final Map<String, String Function()> _hints = {
  'animatedBuilderNoChild': () => FixHintBuilder.animatedBuilderNoChild(
    widgetName: 'Spinner',
    ancestorChain: _chain,
  ).$1,
  'alwaysRepaintPainter': () => FixHintBuilder.alwaysRepaintPainter(
    widgetName: 'ChartPainter',
    ancestorChain: _chain,
  ).$1,
  'frequentRepaintPainter': () => FixHintBuilder.frequentRepaintPainter(
    widgetName: 'ChartPainter',
    ancestorChain: _chain,
  ).$1,
  'multipleCustomFonts': () => FixHintBuilder.multipleCustomFonts(
    fontCount: 4,
    families: ['Inter', 'Lora', 'Mono', 'Serif'],
  ).$1,
  'runtimeFontLoading': () => FixHintBuilder.runtimeFontLoading(
    fontCount: 2,
    families: ['Inter', 'Lora'],
  ).$1,
  'sustainedJank': () => FixHintBuilder.sustainedJank().$1,
  'jankDetected': () => FixHintBuilder.jankDetected().$1,
  'excessiveGlobalKeys': () => FixHintBuilder.excessiveGlobalKeys(count: 30).$1,
  'globalKeyRecreation': () =>
      FixHintBuilder.globalKeyRecreation(churnCount: 12).$1,
  'rasterDominance': () => FixHintBuilder.rasterDominance().$1,
  'expensiveGpuNodes': () => FixHintBuilder.expensiveGpuNodes(
    widgetName: 'BackdropFilter',
    ancestorChain: _chain,
  ).$1,
  'expensiveGpuNodes(blur chrome)': () => FixHintBuilder.expensiveGpuNodes(
    widgetName: 'BackdropFilter',
    ancestorChain: _chain,
    blurChromeOwners: {'CupertinoNavigationBar', 'CupertinoActionSheet'},
  ).$1,
  'expensiveGpuNodes(only chrome)': () => FixHintBuilder.expensiveGpuNodes(
    widgetName: 'BackdropFilter',
    blurChromeOwners: {'CupertinoTabBar'},
    onlyChrome: true,
  ).$1,
  'rasterCacheThrashing': () => FixHintBuilder.rasterCacheThrashing().$1,
  'rasterCacheGrowing': () => FixHintBuilder.rasterCacheGrowing().$1,
  'eventLoopStall': () => FixHintBuilder.eventLoopStall(worstMs: 240).$1,
  'heavyCompute': () => FixHintBuilder.heavyCompute(
    durationMs: 18.4,
    dirtyWidgets: ['FeedList', 'FeedTile'],
  ).$1,
  'uncachedImages': () => FixHintBuilder.uncachedImages(
    count: 3,
    widgetName: 'Image',
    ancestorChain: _chain,
  ).$1,
  'excessiveKeepAlive': () =>
      FixHintBuilder.excessiveKeepAlive(count: 12, ancestorChain: _chain).$1,
  'layoutBottleneck': () => FixHintBuilder.layoutBottleneck(
    widgetName: 'IntrinsicHeight',
    ancestorChain: _chain,
  ).$1,
  'wrapBottleneck': () =>
      FixHintBuilder.wrapBottleneck(childCount: 80, ancestorChain: _chain).$1,
  'nonLazyList': () => FixHintBuilder.nonLazyList(
    childCount: 120,
    widgetName: 'ListView',
    ancestorChain: _chain,
  ).$1,
  'sliverToBoxAdapterLarge': () => FixHintBuilder.sliverToBoxAdapterLarge(
    childCount: 60,
    childType: 'Column',
    ancestorChain: _chain,
  ).$1,
  'sliverFillRemainingScrollable': () =>
      FixHintBuilder.sliverFillRemainingScrollable(ancestorChain: _chain).$1,
  'sliverToBoxAdapterShrinkWrap': () =>
      FixHintBuilder.sliverToBoxAdapterShrinkWrap(
        scrollableType: 'ListView',
        ancestorChain: _chain,
      ).$1,
  'nonLazyShrinkWrap': () => FixHintBuilder.nonLazyShrinkWrap(
    scrollableType: 'ListView',
    flexType: 'Column',
    ancestorChain: _chain,
  ).$1,
  'nonLazySliver': () => FixHintBuilder.nonLazySliver(
    childCount: 90,
    widgetName: 'SliverList',
    ancestorChain: _chain,
  ).$1,
  'gcPressure': () => FixHintBuilder.gcPressure().$1,
  'heapGrowing': () => FixHintBuilder.heapGrowing().$1,
  'heapNearCapacity': () => FixHintBuilder.heapNearCapacity().$1,
  'streamResourceGrowth': () => FixHintBuilder.streamResourceGrowth(
    growingClassSuffixes: ['StreamSubscription', 'StreamController'],
    topGrowthDelta: 64,
  ).$1,
  'nativeMemoryGrowth': () => FixHintBuilder.nativeMemoryGrowth().$1,
  'nestedScrollChildren': () => FixHintBuilder.nestedScrollChildren(
    childCount: 40,
    widgetName: 'ListView',
    ancestorChain: _chain,
  ).$1,
  'nestedScrollGeneric': () => FixHintBuilder.nestedScrollGeneric(
    widgetName: 'ListView',
    ancestorChain: _chain,
  ).$1,
  'slowRequest': () =>
      FixHintBuilder.slowRequest(worstUrl: 'https://api.example.com/feed').$1,
  'largeResponse': () =>
      FixHintBuilder.largeResponse(worstUrl: 'https://api.example.com/feed').$1,
  'httpErrorSpike': () =>
      FixHintBuilder.httpErrorSpike(errorCount: 6, transportFailures: 2).$1,
  'requestFrequency': () => FixHintBuilder.requestFrequency().$1,
  'highFrequencySamePath': () => FixHintBuilder.highFrequencySamePath(
    url: 'https://api.example.com/search',
    count: 5,
  ).$1,
  'opacityZero': () => FixHintBuilder.opacityZero(
    widgetName: 'Opacity',
    ancestorChain: _chain,
  ).$1,
  'platformChannelTraffic': () =>
      FixHintBuilder.platformChannelTraffic(topMethod: 'getBattery').$1,
  'rebuildDebug': () => FixHintBuilder.rebuildDebug(
    typeName: 'FeedTile',
    rate: 45,
    ancestorChain: _chain,
    interactionContext: InteractionContext.scrolling,
  ).$1,
  'rebuildActivity': () => FixHintBuilder.rebuildActivity(
    buildPercent: 22.5,
    enrichedNames: ['FeedList', 'FeedTile'],
    interactionContext: InteractionContext.scrolling,
  ).$1,
  'statefulDensity': () =>
      FixHintBuilder.statefulDensity(topWidget: 'FeedTile').$1,
  'excessiveRepaintVm': () => FixHintBuilder.excessiveRepaintVm(
    paintPercent: 31.8,
    interactionContext: InteractionContext.navigating,
  ).$1,
  'repaintDebugType': () => FixHintBuilder.repaintDebugType(
    typeName: 'ChartPainter',
    rate: 60,
    ancestorChain: _chain,
  ).$1,
  'excessiveRepaintDebug': () => FixHintBuilder.excessiveRepaintDebug().$1,
  'setStateScope': () => FixHintBuilder.setStateScope(
    widgetName: 'DemoScaffold',
    subtreePercent: 88,
    ancestorChain: _chain,
  ).$1,
  'shaderCompilation': () => FixHintBuilder.shaderCompilation().$1,
  'shallowRebuildRisk': () => FixHintBuilder.shallowRebuildRisk(
    widgetName: 'FeedTile',
    hasVmData: true,
  ).$1,
  'excessiveRepaintBoundary': () => FixHintBuilder.excessiveRepaintBoundary(
    boundaryCount: 70,
    ancestorChain: _chain,
  ).$1,
  'missingRepaintBoundary': () => FixHintBuilder.missingRepaintBoundary(
    widgetName: 'AnimatedChart',
    ancestorChain: _chain,
  ).$1,
  'slowStartupTtff': () =>
      FixHintBuilder.slowStartupTtff(ttffMs: 2177, dominantPhase: 'build').$1,
  'trackedResourceConcurrent': () =>
      FixHintBuilder.trackedResourceConcurrent(name: 'socket', liveCount: 8).$1,
  'trackedResourceLongLived': () => FixHintBuilder.trackedResourceLongLived(
    name: 'socket',
    ageSeconds: 420,
  ).$1,
};

/// The split of every hint as plain text: one `## name` section per hint,
/// each part headed `prose` or `code`.
String _render() {
  final out = StringBuffer();
  for (final entry in _hints.entries) {
    out.writeln('## ${entry.key}');
    for (final part in splitFixHint(entry.value())) {
      out.writeln(part.code ? '[code]' : '[prose]');
      out.writeln(part.text);
    }
    out.writeln();
  }
  return out.toString();
}

void main() {
  group('splitFixHint', () {
    test('text with no colon is one prose part', () {
      expect(splitFixHint('Use const constructors.'), [
        (code: false, text: 'Use const constructors.'),
      ]);
    });

    test('a multi-line call stays one code run', () {
      expect(
        splitFixHint(
          'Scope rebuilds:\n'
          'ValueListenableBuilder<int>(\n'
          '  valueListenable: _counter,\n'
          '  builder: (_, value, child) => Text("\$value"),\n'
          ')\n'
          'Move state down.',
        ),
        [
          (code: false, text: 'Scope rebuilds:'),
          (
            code: true,
            text:
                'ValueListenableBuilder<int>(\n'
                '  valueListenable: _counter,\n'
                '  builder: (_, value, child) => Text("\$value"),\n'
                ')',
          ),
          (code: false, text: 'Move state down.'),
        ],
      );
    });

    test('bullets stay prose even with parentheses', () {
      expect(splitFixHint('Fixes:\n  • Call cancel() on the subscription'), [
        (code: false, text: 'Fixes:\n  • Call cancel() on the subscription'),
      ]);
    });

    test('code starts only after a line ending in a colon', () {
      expect(splitFixHint('Avoid build() work.\nfoo();'), [
        (code: false, text: 'Avoid build() work.\nfoo();'),
      ]);
    });

    test('a sentence after code is prose, even with parentheses', () {
      expect(
        splitFixHint(
          'Wrap it:\nRepaintBoundary(child: X())\nSimplify (shadows).',
        ),
        [
          (code: false, text: 'Wrap it:'),
          (code: true, text: 'RepaintBoundary(child: X())'),
          (code: false, text: 'Simplify (shadows).'),
        ],
      );
    });

    test('comment lines and commands are code', () {
      expect(splitFixHint('Run:\nflutter run --profile\n// then compare'), [
        (code: false, text: 'Run:'),
        (code: true, text: 'flutter run --profile\n// then compare'),
      ]);
    });

    test('every FixHintBuilder hint splits as the reviewed table says', () {
      final rendered = _render();
      final file = File(_fixture);
      if (_update) {
        file.writeAsStringSync(rendered);
        return;
      }
      expect(rendered, file.readAsStringSync());
    });
  });
}
