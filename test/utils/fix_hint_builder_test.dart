import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/utils/fix_hint_builder.dart';

void main() {
  // -------------------------------------------------------------------------
  // AnimatedBuilderDetector
  // -------------------------------------------------------------------------
  group('animatedBuilderNoChild', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.animatedBuilderNoChild();
      expect(effort, FixEffort.quick);
    });

    test('includes widget context when provided', () {
      final (hint, _) = FixHintBuilder.animatedBuilderNoChild(
        widgetName: 'MyAnim',
        ancestorChain: 'MyPage > Column',
      );
      expect(hint, contains('MyAnim'));
      expect(hint, contains('MyPage > Column'));
    });

    test('fallback hint without context', () {
      final (hint, _) = FixHintBuilder.animatedBuilderNoChild();
      expect(hint, contains('child parameter'));
    });
  });

  // -------------------------------------------------------------------------
  // CustomPainterDetector
  // -------------------------------------------------------------------------
  group('alwaysRepaintPainter', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.alwaysRepaintPainter();
      expect(effort, FixEffort.quick);
    });

    test('includes widget context when provided', () {
      final (hint, _) = FixHintBuilder.alwaysRepaintPainter(
        widgetName: 'ChartPainter',
        ancestorChain: 'Dashboard > Stack',
      );
      expect(hint, contains('ChartPainter'));
    });

    test('mentions shouldRepaint', () {
      final (hint, _) = FixHintBuilder.alwaysRepaintPainter();
      expect(hint, contains('shouldRepaint'));
    });
  });

  group('frequentRepaintPainter', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.frequentRepaintPainter();
      expect(effort, FixEffort.quick);
    });

    test('mentions shouldRepaint', () {
      final (hint, _) = FixHintBuilder.frequentRepaintPainter();
      expect(hint, contains('shouldRepaint'));
    });
  });

  // -------------------------------------------------------------------------
  // FontLoadingDetector
  // -------------------------------------------------------------------------
  group('multipleCustomFonts', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.multipleCustomFonts(fontCount: 5);
      expect(effort, FixEffort.quick);
    });

    test('includes font count', () {
      final (hint, _) = FixHintBuilder.multipleCustomFonts(fontCount: 5);
      expect(hint, contains('5'));
    });

    test('includes family names when provided', () {
      final (hint, _) = FixHintBuilder.multipleCustomFonts(
        fontCount: 3,
        families: ['Roboto', 'OpenSans', 'Lato'],
      );
      expect(hint, contains('Roboto'));
      expect(hint, contains('OpenSans'));
    });
  });

  // -------------------------------------------------------------------------
  // FrameTimingDetector
  // -------------------------------------------------------------------------
  group('sustainedJank', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.sustainedJank();
      expect(effort, FixEffort.medium);
    });

    test('mentions profile mode', () {
      final (hint, _) = FixHintBuilder.sustainedJank();
      expect(hint, contains('profile mode'));
    });
  });

  group('jankDetected', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.jankDetected();
      expect(effort, FixEffort.quick);
    });
  });

  // -------------------------------------------------------------------------
  // GlobalKeyDetector
  // -------------------------------------------------------------------------
  group('excessiveGlobalKeys', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.excessiveGlobalKeys(count: 10);
      expect(effort, FixEffort.quick);
    });

    test('includes count', () {
      final (hint, _) = FixHintBuilder.excessiveGlobalKeys(count: 15);
      expect(hint, contains('15'));
    });
  });

  // -------------------------------------------------------------------------
  // GpuPressureDetector
  // -------------------------------------------------------------------------
  group('rasterDominance', () {
    test('returns involved effort', () {
      final (_, effort) = FixHintBuilder.rasterDominance();
      expect(effort, FixEffort.involved);
    });
  });

  group('expensiveGpuNodes', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.expensiveGpuNodes();
      expect(effort, FixEffort.medium);
    });

    test('includes widget context when provided', () {
      final (hint, _) = FixHintBuilder.expensiveGpuNodes(
        widgetName: 'ShaderMask',
        ancestorChain: 'Header > Stack',
      );
      expect(hint, contains('ShaderMask'));
    });
  });

  // -------------------------------------------------------------------------
  // HeavyComputeDetector — preserved keywords: Isolate.run(), compute()
  // -------------------------------------------------------------------------
  group('heavyCompute', () {
    test('returns involved effort', () {
      final (_, effort) = FixHintBuilder.heavyCompute();
      expect(effort, FixEffort.involved);
    });

    test('contains Isolate.run() keyword', () {
      final (hint, _) = FixHintBuilder.heavyCompute();
      expect(hint, contains('Isolate.run()'));
    });

    test('contains compute() keyword', () {
      final (hint, _) = FixHintBuilder.heavyCompute();
      expect(hint, contains('compute()'));
    });

    test('includes dirty widgets when provided', () {
      final (hint, _) = FixHintBuilder.heavyCompute(
        durationMs: 25.3,
        dirtyWidgets: ['MyExpensiveWidget', 'AnotherWidget'],
      );
      expect(hint, contains('MyExpensiveWidget'));
      expect(hint, contains('25.3'));
    });
  });

  // -------------------------------------------------------------------------
  // ImageMemoryDetector
  // -------------------------------------------------------------------------
  group('uncachedImages', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.uncachedImages(count: 3);
      expect(effort, FixEffort.quick);
    });

    test('includes widget context when provided', () {
      final (hint, _) = FixHintBuilder.uncachedImages(
        count: 2,
        widgetName: 'ProductCard',
        ancestorChain: 'ListView > ProductCard',
      );
      expect(hint, contains('ProductCard'));
    });

    test('includes count when widget context present', () {
      final (hint, _) = FixHintBuilder.uncachedImages(
        count: 5,
        widgetName: 'ImageGrid',
      );
      expect(hint, contains('5'));
    });

    test('mentions cacheWidth', () {
      final (hint, _) = FixHintBuilder.uncachedImages(count: 1);
      expect(hint, contains('cacheWidth'));
    });
  });

  // -------------------------------------------------------------------------
  // KeepAliveDetector
  // -------------------------------------------------------------------------
  group('excessiveKeepAlive', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.excessiveKeepAlive(count: 20);
      expect(effort, FixEffort.quick);
    });

    test('includes count and location', () {
      final (hint, _) = FixHintBuilder.excessiveKeepAlive(
        count: 20,
        ancestorChain: 'TabView > ListView',
      );
      expect(hint, contains('20'));
      expect(hint, contains('TabView > ListView'));
    });
  });

  // -------------------------------------------------------------------------
  // LayoutBottleneckDetector
  // -------------------------------------------------------------------------
  group('layoutBottleneck', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.layoutBottleneck();
      expect(effort, FixEffort.medium);
    });

    test('includes widget context when provided', () {
      final (hint, _) = FixHintBuilder.layoutBottleneck(
        widgetName: 'ChatBubble',
        ancestorChain: 'MessageList > Column',
      );
      expect(hint, contains('ChatBubble'));
      expect(hint, contains('MessageList > Column'));
    });

    test('fallback without context', () {
      final (hint, _) = FixHintBuilder.layoutBottleneck();
      expect(hint, contains('IntrinsicHeight'));
    });
  });

  // -------------------------------------------------------------------------
  // ListviewDetector
  // -------------------------------------------------------------------------
  group('nonLazyList', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.nonLazyList(childCount: 50);
      expect(effort, FixEffort.quick);
    });

    test('includes child count and context', () {
      final (hint, _) = FixHintBuilder.nonLazyList(
        childCount: 100,
        widgetName: 'UserList',
        ancestorChain: 'HomePage > Column',
      );
      expect(hint, contains('100'));
      expect(hint, contains('UserList'));
    });

    test('mentions ListView.builder', () {
      final (hint, _) = FixHintBuilder.nonLazyList(childCount: 50);
      expect(hint, contains('ListView.builder'));
    });
  });

  // -------------------------------------------------------------------------
  // MemoryPressureDetector
  // -------------------------------------------------------------------------
  group('gcPressure', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.gcPressure();
      expect(effort, FixEffort.medium);
    });
  });

  group('heapGrowing', () {
    test('returns involved effort', () {
      final (_, effort) = FixHintBuilder.heapGrowing();
      expect(effort, FixEffort.involved);
    });

    test('contains undisposed keyword', () {
      final (hint, _) = FixHintBuilder.heapGrowing();
      expect(hint, contains('undisposed'));
    });

    test('contains DevTools keyword', () {
      final (hint, _) = FixHintBuilder.heapGrowing();
      expect(hint, contains('DevTools'));
    });
  });

  group('heapNearCapacity', () {
    test('returns involved effort', () {
      final (_, effort) = FixHintBuilder.heapNearCapacity();
      expect(effort, FixEffort.involved);
    });

    test('contains DevTools keyword', () {
      final (hint, _) = FixHintBuilder.heapNearCapacity();
      expect(hint, contains('DevTools'));
    });
  });

  // -------------------------------------------------------------------------
  // NestedScrollDetector
  // -------------------------------------------------------------------------
  group('nestedScrollChildren', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.nestedScrollChildren(childCount: 30);
      expect(effort, FixEffort.medium);
    });

    test('includes child count and context', () {
      final (hint, _) = FixHintBuilder.nestedScrollChildren(
        childCount: 30,
        widgetName: 'NestedList',
        ancestorChain: 'TabPage > ListView',
      );
      expect(hint, contains('30'));
      expect(hint, contains('NestedList'));
    });
  });

  group('nestedScrollGeneric', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.nestedScrollGeneric();
      expect(effort, FixEffort.medium);
    });

    test('mentions CustomScrollView', () {
      final (hint, _) = FixHintBuilder.nestedScrollGeneric();
      expect(hint, contains('CustomScrollView'));
    });
  });

  // -------------------------------------------------------------------------
  // NetworkMonitorDetector — preserved keywords: caching, Paginate, Batch
  // -------------------------------------------------------------------------
  group('slowRequest', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.slowRequest();
      expect(effort, FixEffort.medium);
    });

    test('contains caching keyword', () {
      final (hint, _) = FixHintBuilder.slowRequest();
      expect(hint, contains('caching'));
    });

    test('includes URL when provided', () {
      final (hint, _) =
          FixHintBuilder.slowRequest(worstUrl: 'https://api.example.com/data');
      expect(hint, contains('https://api.example.com/data'));
    });
  });

  group('largeResponse', () {
    test('returns involved effort', () {
      final (_, effort) = FixHintBuilder.largeResponse();
      expect(effort, FixEffort.involved);
    });

    test('contains Paginate keyword', () {
      final (hint, _) = FixHintBuilder.largeResponse();
      expect(hint, contains('Paginate'));
    });

    test('includes URL when provided', () {
      final (hint, _) =
          FixHintBuilder.largeResponse(worstUrl: 'https://api.example.com/big');
      expect(hint, contains('https://api.example.com/big'));
    });
  });

  group('requestFrequency', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.requestFrequency();
      expect(effort, FixEffort.medium);
    });

    test('contains Batch keyword', () {
      final (hint, _) = FixHintBuilder.requestFrequency();
      expect(hint, contains('Batch'));
    });
  });

  // -------------------------------------------------------------------------
  // OpacityDetector — preserved keyword: Visibility
  // -------------------------------------------------------------------------
  group('opacityZero', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.opacityZero();
      expect(effort, FixEffort.quick);
    });

    test('contains Visibility keyword', () {
      final (hint, _) = FixHintBuilder.opacityZero();
      expect(hint, contains('Visibility'));
    });

    test('includes widget context when provided', () {
      final (hint, _) = FixHintBuilder.opacityZero(
        widgetName: 'FadeWidget',
        ancestorChain: 'Card > Stack',
      );
      expect(hint, contains('FadeWidget'));
    });
  });

  // -------------------------------------------------------------------------
  // PlatformChannelDetector — preserved keywords: Batch, Pigeon
  // -------------------------------------------------------------------------
  group('platformChannelTraffic', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.platformChannelTraffic();
      expect(effort, FixEffort.medium);
    });

    test('contains Batch keyword', () {
      final (hint, _) = FixHintBuilder.platformChannelTraffic();
      expect(hint, contains('Batch'));
    });

    test('contains Pigeon keyword', () {
      final (hint, _) = FixHintBuilder.platformChannelTraffic();
      expect(hint, contains('Pigeon'));
    });

    test('includes method name when provided', () {
      final (hint, _) =
          FixHintBuilder.platformChannelTraffic(topMethod: 'getLocation');
      expect(hint, contains('getLocation'));
    });
  });

  // -------------------------------------------------------------------------
  // RebuildDetector
  // -------------------------------------------------------------------------
  group('rebuildDebug', () {
    test('returns medium effort', () {
      final (_, effort) =
          FixHintBuilder.rebuildDebug(typeName: 'MyWidget', rate: 25);
      expect(effort, FixEffort.medium);
    });

    test('includes type name and rate', () {
      final (hint, _) =
          FixHintBuilder.rebuildDebug(typeName: 'MyListItem', rate: 30);
      expect(hint, contains('MyListItem'));
      expect(hint, contains('30'));
    });

    test('includes scrolling context', () {
      final (hint, _) = FixHintBuilder.rebuildDebug(
        typeName: 'MyWidget',
        rate: 25,
        interactionContext: InteractionContext.scrolling,
      );
      expect(hint, contains('scrolling'));
    });

    test('includes ancestor chain', () {
      final (hint, _) = FixHintBuilder.rebuildDebug(
        typeName: 'MyWidget',
        rate: 25,
        ancestorChain: 'MyPage > ListView',
      );
      expect(hint, contains('MyPage > ListView'));
    });
  });

  group('rebuildActivity', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.rebuildActivity(buildCount: 100);
      expect(effort, FixEffort.medium);
    });

    test('includes build count', () {
      final (hint, _) = FixHintBuilder.rebuildActivity(buildCount: 150);
      expect(hint, contains('150'));
    });

    test('includes enriched names when provided', () {
      final (hint, _) = FixHintBuilder.rebuildActivity(
        buildCount: 100,
        enrichedNames: ['WidgetA', 'WidgetB'],
      );
      expect(hint, contains('WidgetA'));
      expect(hint, contains('WidgetB'));
    });
  });

  group('statefulDensity', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.statefulDensity();
      expect(effort, FixEffort.medium);
    });

    test('includes top widget when provided', () {
      final (hint, _) = FixHintBuilder.statefulDensity(topWidget: 'MyStateful');
      expect(hint, contains('MyStateful'));
    });
  });

  // -------------------------------------------------------------------------
  // RepaintDetector
  // -------------------------------------------------------------------------
  group('excessiveRepaintVm', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.excessiveRepaintVm();
      expect(effort, FixEffort.quick);
    });

    test('mentions RepaintBoundary', () {
      final (hint, _) = FixHintBuilder.excessiveRepaintVm();
      expect(hint, contains('RepaintBoundary'));
    });

    test('includes scrolling context', () {
      final (hint, _) = FixHintBuilder.excessiveRepaintVm(
        interactionContext: InteractionContext.scrolling,
      );
      expect(hint, contains('scrolling'));
    });
  });

  group('repaintDebugType', () {
    test('returns quick effort', () {
      final (_, effort) =
          FixHintBuilder.repaintDebugType(typeName: 'AnimWidget', rate: 60);
      expect(effort, FixEffort.quick);
    });

    test('includes type name and rate', () {
      final (hint, _) =
          FixHintBuilder.repaintDebugType(typeName: 'ClockFace', rate: 60);
      expect(hint, contains('ClockFace'));
      expect(hint, contains('60'));
    });

    test('includes ancestor chain', () {
      final (hint, _) = FixHintBuilder.repaintDebugType(
        typeName: 'ClockFace',
        rate: 60,
        ancestorChain: 'Dashboard > Stack',
      );
      expect(hint, contains('Dashboard > Stack'));
    });
  });

  group('excessiveRepaintDebug', () {
    test('returns quick effort', () {
      final (_, effort) = FixHintBuilder.excessiveRepaintDebug();
      expect(effort, FixEffort.quick);
    });

    test('mentions RepaintBoundary', () {
      final (hint, _) = FixHintBuilder.excessiveRepaintDebug();
      expect(hint, contains('RepaintBoundary'));
    });
  });

  // -------------------------------------------------------------------------
  // SetStateScopeDetector
  // -------------------------------------------------------------------------
  group('setStateScope', () {
    test('returns medium effort', () {
      final (_, effort) = FixHintBuilder.setStateScope(
        widgetName: 'MyPage',
        subtreePercent: 45,
      );
      expect(effort, FixEffort.medium);
    });

    test('includes widget name and percent', () {
      final (hint, _) = FixHintBuilder.setStateScope(
        widgetName: 'HomePage',
        subtreePercent: 60,
      );
      expect(hint, contains('HomePage'));
      expect(hint, contains('60'));
    });

    test('includes ancestor chain when provided', () {
      final (hint, _) = FixHintBuilder.setStateScope(
        widgetName: 'HomePage',
        subtreePercent: 60,
        ancestorChain: 'App > MaterialApp',
      );
      expect(hint, contains('App > MaterialApp'));
    });
  });

  // -------------------------------------------------------------------------
  // ShaderJankDetector
  // -------------------------------------------------------------------------
  group('shaderCompilation', () {
    test('returns involved effort', () {
      final (_, effort) = FixHintBuilder.shaderCompilation();
      expect(effort, FixEffort.involved);
    });

    test('mentions cache-sksl', () {
      final (hint, _) = FixHintBuilder.shaderCompilation();
      expect(hint, contains('cache-sksl'));
    });
  });

  // -------------------------------------------------------------------------
  // ShallowRebuildRiskDetector
  // -------------------------------------------------------------------------
  group('shallowRebuildRisk', () {
    test('returns medium effort', () {
      final (_, effort) =
          FixHintBuilder.shallowRebuildRisk(widgetName: 'AppShell');
      expect(effort, FixEffort.medium);
    });

    test('includes widget name', () {
      final (hint, _) =
          FixHintBuilder.shallowRebuildRisk(widgetName: 'RootWidget');
      expect(hint, contains('RootWidget'));
    });

    test('omits VM suffix when hasVmData is true', () {
      final (hint, _) = FixHintBuilder.shallowRebuildRisk(
        widgetName: 'AppShell',
        hasVmData: true,
      );
      expect(hint, isNot(contains('Run in profile mode')));
    });

    test('includes VM suffix when hasVmData is false', () {
      final (hint, _) = FixHintBuilder.shallowRebuildRisk(
        widgetName: 'AppShell',
        hasVmData: false,
      );
      expect(hint, contains('Run in profile mode'));
    });
  });

  // ---------------------------------------------------------------------------
  // nativeMemoryGrowth
  // ---------------------------------------------------------------------------

  group('nativeMemoryGrowth', () {
    test('returns involved effort', () {
      final (_, effort) = FixHintBuilder.nativeMemoryGrowth();
      expect(effort, FixEffort.involved);
    });

    test('hint mentions DevTools', () {
      final (hint, _) = FixHintBuilder.nativeMemoryGrowth();
      expect(hint, contains('DevTools'));
    });

    test('hint mentions cacheWidth', () {
      final (hint, _) = FixHintBuilder.nativeMemoryGrowth();
      expect(hint, contains('cacheWidth'));
    });
  });

  // ---------------------------------------------------------------------------
  // FrameTimingDetector — Raster Cache Trends
  // ---------------------------------------------------------------------------

  group('rasterCacheThrashing', () {
    test('returns involved effort', () {
      final (_, effort) = FixHintBuilder.rasterCacheThrashing();
      expect(effort, FixEffort.involved);
    });

    test('hint mentions RepaintBoundary', () {
      final (hint, _) = FixHintBuilder.rasterCacheThrashing();
      expect(hint, contains('RepaintBoundary'));
    });
  });

  group('rasterCacheGrowing', () {
    test('returns involved effort', () {
      final (_, effort) = FixHintBuilder.rasterCacheGrowing();
      expect(effort, FixEffort.involved);
    });

    test('hint mentions cache entries', () {
      final (hint, _) = FixHintBuilder.rasterCacheGrowing();
      expect(hint, contains('cache entries'));
    });
  });
}
