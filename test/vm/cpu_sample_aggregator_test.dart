import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:widget_watchdog/src/vm/cpu_sample_aggregator.dart';

void main() {
  const aggregator = CpuSampleAggregator();

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Create a ProfileFunction backed by a FuncRef with a ClassRef owner.
  ProfileFunction makeClassFunc({
    required String funcName,
    required String className,
    required String libraryUri,
  }) {
    return ProfileFunction(
      kind: 'Dart',
      inclusiveTicks: 0,
      exclusiveTicks: 0,
      resolvedUrl: libraryUri,
      function: FuncRef(
        id: 'func/$funcName',
        name: funcName,
        owner: ClassRef(
          id: 'class/$className',
          name: className,
          library: LibraryRef(id: 'lib/$libraryUri', uri: libraryUri),
        ),
      ),
    );
  }

  /// Create a ProfileFunction backed by a FuncRef with a LibraryRef owner.
  ProfileFunction makeTopLevelFunc({
    required String funcName,
    required String libraryUri,
  }) {
    return ProfileFunction(
      kind: 'Dart',
      inclusiveTicks: 0,
      exclusiveTicks: 0,
      resolvedUrl: libraryUri,
      function: FuncRef(
        id: 'func/$funcName',
        name: funcName,
        owner: LibraryRef(id: 'lib/$libraryUri', uri: libraryUri),
      ),
    );
  }

  /// Create a ProfileFunction backed by a FuncRef with a FuncRef owner (closure).
  ProfileFunction makeClosureFunc({
    required String funcName,
    required String resolvedUrl,
  }) {
    return ProfileFunction(
      kind: 'Dart',
      inclusiveTicks: 0,
      exclusiveTicks: 0,
      resolvedUrl: resolvedUrl,
      function: FuncRef(
        id: 'func/$funcName',
        name: funcName,
        owner: FuncRef(id: 'func/outer', name: 'outerFunction'),
      ),
    );
  }

  /// Create a ProfileFunction backed by a NativeFunction.
  ProfileFunction makeNativeFunc({required String name}) {
    return ProfileFunction(
      kind: 'Native',
      inclusiveTicks: 0,
      exclusiveTicks: 0,
      resolvedUrl: '',
      function: NativeFunction(name: name),
    );
  }

  /// Create a CpuSample with optional vmTag. stack is list of function indices.
  CpuSample makeSample({required List<int> stack, String? vmTag}) {
    return CpuSample(
      tid: 1,
      timestamp: 1000000,
      stack: stack,
      vmTag: vmTag,
    );
  }

  CpuSamples makeCpuSamples({
    required List<ProfileFunction> functions,
    required List<CpuSample> samples,
  }) {
    return CpuSamples(
      functions: functions,
      samples: samples,
      samplePeriod: 1000,
      sampleCount: samples.length,
      maxStackDepth: 128,
      timeOriginMicros: 0,
      timeExtentMicros: 1000000,
      pid: 1,
    );
  }

  // ---------------------------------------------------------------------------
  // Empty / null input
  // ---------------------------------------------------------------------------

  group('empty/null input', () {
    test('empty samples returns empty list', () {
      final result = aggregator.aggregate(makeCpuSamples(
        functions: [
          makeClassFunc(
              funcName: 'f', className: 'C', libraryUri: 'package:app/a.dart')
        ],
        samples: [],
      ));
      expect(result, isEmpty);
    });

    test('empty functions returns empty list', () {
      final result = aggregator.aggregate(makeCpuSamples(
        functions: [],
        samples: [
          makeSample(stack: [0])
        ],
      ));
      expect(result, isEmpty);
    });

    test('handles null functions list gracefully', () {
      final cs = CpuSamples(
        functions: null,
        samples: [
          makeSample(stack: [0])
        ],
        samplePeriod: 1000,
        sampleCount: 1,
        maxStackDepth: 128,
        timeOriginMicros: 0,
        timeExtentMicros: 1000000,
        pid: 1,
      );
      expect(aggregator.aggregate(cs), isEmpty);
    });

    test('handles null samples list gracefully', () {
      final cs = CpuSamples(
        functions: [
          makeClassFunc(
              funcName: 'f', className: 'C', libraryUri: 'package:app/a.dart')
        ],
        samples: null,
        samplePeriod: 1000,
        sampleCount: 0,
        maxStackDepth: 128,
        timeOriginMicros: 0,
        timeExtentMicros: 1000000,
        pid: 1,
      );
      expect(aggregator.aggregate(cs), isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Basic aggregation
  // ---------------------------------------------------------------------------

  group('basic aggregation', () {
    test('single function returns single attribution', () {
      final funcs = [
        makeClassFunc(
            funcName: 'build',
            className: 'MyWidget',
            libraryUri: 'package:app/w.dart'),
      ];
      final samples = [
        makeSample(stack: [0]),
        makeSample(stack: [0]),
        makeSample(stack: [0]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result, hasLength(1));
      expect(result[0].functionName, 'build');
      expect(result[0].className, 'MyWidget');
      expect(result[0].percentage, 100.0);
    });

    test('sorted by exclusive tick percentage descending', () {
      final funcs = [
        makeClassFunc(
            funcName: 'build',
            className: 'A',
            libraryUri: 'package:app/a.dart'),
        makeClassFunc(
            funcName: 'render',
            className: 'B',
            libraryUri: 'package:app/b.dart'),
        makeClassFunc(
            funcName: 'layout',
            className: 'C',
            libraryUri: 'package:app/c.dart'),
      ];
      // A: 1, B: 3, C: 2 → sorted B(50%), C(33.3%), A(16.7%)
      final samples = [
        makeSample(stack: [0]),
        makeSample(stack: [1]),
        makeSample(stack: [1]),
        makeSample(stack: [1]),
        makeSample(stack: [2]),
        makeSample(stack: [2]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result[0].functionName, 'render');
      expect(result[1].functionName, 'layout');
      expect(result[2].functionName, 'build');
    });

    test('percentage calculation is correct', () {
      final funcs = [
        makeClassFunc(
            funcName: 'a', className: 'A', libraryUri: 'package:app/a.dart'),
        makeClassFunc(
            funcName: 'b', className: 'B', libraryUri: 'package:app/b.dart'),
      ];
      // 3:1 ratio → 75% and 25%
      final samples = [
        makeSample(stack: [0]),
        makeSample(stack: [0]),
        makeSample(stack: [0]),
        makeSample(stack: [1]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result[0].percentage, closeTo(75.0, 0.1));
      expect(result[1].percentage, closeTo(25.0, 0.1));
    });

    test('top 5 cap — only returns 5 even with more functions', () {
      final funcs = List.generate(
        8,
        (i) => makeClassFunc(
            funcName: 'f$i',
            className: 'C$i',
            libraryUri: 'package:app/$i.dart'),
      );
      // Each function gets 1 sample
      final samples = List.generate(8, (i) => makeSample(stack: [i]));

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result, hasLength(5));
    });
  });

  // ---------------------------------------------------------------------------
  // Function info extraction
  // ---------------------------------------------------------------------------

  group('function info extraction', () {
    test('FuncRef with ClassRef owner extracts className', () {
      final funcs = [
        makeClassFunc(
            funcName: 'build',
            className: 'MyWidget',
            libraryUri: 'package:app/w.dart'),
      ];
      final result = aggregator.aggregate(makeCpuSamples(
        functions: funcs,
        samples: [
          makeSample(stack: [0])
        ],
      ));
      expect(result[0].className, 'MyWidget');
      expect(result[0].functionName, 'build');
      expect(result[0].libraryUri, 'package:app/w.dart');
      expect(result[0].displayName, 'MyWidget.build');
    });

    test('FuncRef with LibraryRef owner has empty className', () {
      final funcs = [
        makeTopLevelFunc(funcName: 'jsonDecode', libraryUri: 'dart:convert'),
      ];
      // Framework filter: dart:convert is framework — but with only 1 function
      // at 100%, it exceeds 50% so it's kept
      final result = aggregator.aggregate(makeCpuSamples(
        functions: funcs,
        samples: [
          makeSample(stack: [0])
        ],
      ));
      expect(result[0].className, '');
      expect(result[0].functionName, 'jsonDecode');
      expect(result[0].displayName, 'jsonDecode');
    });

    test('FuncRef with FuncRef owner (closure) has empty className', () {
      final funcs = [
        makeClosureFunc(
            funcName: '<anonymous>', resolvedUrl: 'package:app/main.dart'),
      ];
      final result = aggregator.aggregate(makeCpuSamples(
        functions: funcs,
        samples: [
          makeSample(stack: [0])
        ],
      ));
      expect(result[0].className, '');
      expect(result[0].functionName, '<anonymous>');
      expect(result[0].libraryUri, 'package:app/main.dart');
    });

    test('NativeFunction extracts name with "native" libraryUri', () {
      final funcs = [makeNativeFunc(name: 'malloc')];
      final result = aggregator.aggregate(makeCpuSamples(
        functions: funcs,
        samples: [
          makeSample(stack: [0])
        ],
      ));
      expect(result[0].functionName, 'malloc');
      expect(result[0].className, '');
      expect(result[0].libraryUri, 'native');
    });
  });

  // ---------------------------------------------------------------------------
  // vmTag filtering
  // ---------------------------------------------------------------------------

  group('vmTag filtering', () {
    final userFunc = makeClassFunc(
      funcName: 'build',
      className: 'W',
      libraryUri: 'package:app/w.dart',
    );

    test('filters GC vmTag samples', () {
      final result = aggregator.aggregate(makeCpuSamples(
        functions: [userFunc],
        samples: [
          makeSample(stack: [0], vmTag: 'GC')
        ],
      ));
      expect(result, isEmpty);
    });

    test('filters CompileOptimized vmTag samples', () {
      final result = aggregator.aggregate(makeCpuSamples(
        functions: [userFunc],
        samples: [
          makeSample(stack: [0], vmTag: 'CompileOptimized')
        ],
      ));
      expect(result, isEmpty);
    });

    test('filters CompileUnoptimized vmTag samples', () {
      final result = aggregator.aggregate(makeCpuSamples(
        functions: [userFunc],
        samples: [
          makeSample(stack: [0], vmTag: 'CompileUnoptimized')
        ],
      ));
      expect(result, isEmpty);
    });

    test('filters Native vmTag samples', () {
      final result = aggregator.aggregate(makeCpuSamples(
        functions: [userFunc],
        samples: [
          makeSample(stack: [0], vmTag: 'Native')
        ],
      ));
      expect(result, isEmpty);
    });

    test('filters Idle vmTag samples', () {
      final result = aggregator.aggregate(makeCpuSamples(
        functions: [userFunc],
        samples: [
          makeSample(stack: [0], vmTag: 'Idle')
        ],
      ));
      expect(result, isEmpty);
    });

    test('filters VM vmTag samples', () {
      final result = aggregator.aggregate(makeCpuSamples(
        functions: [userFunc],
        samples: [
          makeSample(stack: [0], vmTag: 'VM')
        ],
      ));
      expect(result, isEmpty);
    });

    test('keeps samples with null vmTag', () {
      final result = aggregator.aggregate(makeCpuSamples(
        functions: [userFunc],
        samples: [
          makeSample(stack: [0])
        ],
      ));
      expect(result, hasLength(1));
    });

    test('keeps samples with empty vmTag', () {
      final result = aggregator.aggregate(makeCpuSamples(
        functions: [userFunc],
        samples: [
          makeSample(stack: [0], vmTag: '')
        ],
      ));
      expect(result, hasLength(1));
    });

    test('all samples excluded returns empty list', () {
      final result = aggregator.aggregate(makeCpuSamples(
        functions: [userFunc],
        samples: [
          makeSample(stack: [0], vmTag: 'GC'),
          makeSample(stack: [0], vmTag: 'Native'),
          makeSample(stack: [0], vmTag: 'Idle'),
        ],
      ));
      expect(result, isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // Framework filtering
  // ---------------------------------------------------------------------------

  group('framework filtering', () {
    test('dart:core functions excluded when < 50% of ticks', () {
      final funcs = [
        makeClassFunc(
            funcName: 'build',
            className: 'W',
            libraryUri: 'package:app/w.dart'),
        makeTopLevelFunc(funcName: 'print', libraryUri: 'dart:core'),
      ];
      // User: 3, framework: 1 → framework = 25% < 50% → excluded
      final samples = [
        makeSample(stack: [0]),
        makeSample(stack: [0]),
        makeSample(stack: [0]),
        makeSample(stack: [1]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result, hasLength(1));
      expect(result[0].functionName, 'build');
      expect(result[0].percentage, 100.0); // recomputed from user-only
    });

    test('package:flutter/ functions excluded when < 50%', () {
      final funcs = [
        makeClassFunc(
            funcName: 'build',
            className: 'W',
            libraryUri: 'package:app/w.dart'),
        makeClassFunc(
          funcName: 'performRebuild',
          className: 'ComponentElement',
          libraryUri: 'package:flutter/src/widgets/framework.dart',
        ),
      ];
      // User: 3, framework: 1
      final samples = [
        makeSample(stack: [0]),
        makeSample(stack: [0]),
        makeSample(stack: [0]),
        makeSample(stack: [1]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result, hasLength(1));
      expect(result[0].functionName, 'build');
    });

    test('framework functions kept when > 50% of ticks', () {
      final funcs = [
        makeClassFunc(
            funcName: 'build',
            className: 'W',
            libraryUri: 'package:app/w.dart'),
        makeClassFunc(
          funcName: 'performRebuild',
          className: 'ComponentElement',
          libraryUri: 'package:flutter/src/widgets/framework.dart',
        ),
      ];
      // User: 1, framework: 3 → framework = 75% > 50% → kept
      final samples = [
        makeSample(stack: [0]),
        makeSample(stack: [1]),
        makeSample(stack: [1]),
        makeSample(stack: [1]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result, hasLength(2));
      expect(result[0].functionName, 'performRebuild');
      expect(result[0].percentage, closeTo(75.0, 0.1));
    });

    test('exact 50% framework boundary excludes framework (threshold is >50%)',
        () {
      final funcs = [
        makeClassFunc(
            funcName: 'build',
            className: 'W',
            libraryUri: 'package:app/w.dart'),
        makeClassFunc(
          funcName: 'performRebuild',
          className: 'ComponentElement',
          libraryUri: 'package:flutter/src/widgets/framework.dart',
        ),
      ];
      // User: 2, framework: 2 → framework = 50% — NOT > 50% → excluded
      final samples = [
        makeSample(stack: [0]),
        makeSample(stack: [0]),
        makeSample(stack: [1]),
        makeSample(stack: [1]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      // Framework at exactly 50% should be excluded (threshold is strictly >50%)
      expect(result, hasLength(1));
      expect(result[0].functionName, 'build');
      expect(result[0].percentage, 100.0); // recomputed from user-only
    });

    test('mixed user + framework functions — correct ranking', () {
      final funcs = [
        makeClassFunc(
            funcName: 'build',
            className: 'W',
            libraryUri: 'package:app/w.dart'),
        makeClassFunc(
            funcName: 'decode',
            className: 'Parser',
            libraryUri: 'package:app/p.dart'),
        makeTopLevelFunc(funcName: 'print', libraryUri: 'dart:core'),
      ];
      // User0: 2, User1: 3, Framework: 1 → framework < 50% → excluded
      // User-only: decode=60%, build=40%
      final samples = [
        makeSample(stack: [0]),
        makeSample(stack: [0]),
        makeSample(stack: [1]),
        makeSample(stack: [1]),
        makeSample(stack: [1]),
        makeSample(stack: [2]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result, hasLength(2));
      expect(result[0].functionName, 'decode');
      expect(result[0].percentage, closeTo(60.0, 0.1));
      expect(result[1].functionName, 'build');
      expect(result[1].percentage, closeTo(40.0, 0.1));
    });
  });

  // ---------------------------------------------------------------------------
  // Edge cases
  // ---------------------------------------------------------------------------

  group('edge cases', () {
    test('sample with empty stack is skipped', () {
      final funcs = [
        makeClassFunc(
            funcName: 'f', className: 'C', libraryUri: 'package:app/a.dart'),
      ];
      final samples = [
        CpuSample(tid: 1, timestamp: 1000000, stack: []),
        makeSample(stack: [0]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result, hasLength(1));
      expect(result[0].percentage, 100.0);
    });

    test('sample with null stack is skipped', () {
      final funcs = [
        makeClassFunc(
            funcName: 'f', className: 'C', libraryUri: 'package:app/a.dart'),
      ];
      final samples = [
        CpuSample(tid: 1, timestamp: 1000000, stack: null),
        makeSample(stack: [0]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result, hasLength(1));
    });

    test('sample with negative function index is skipped gracefully', () {
      final funcs = [
        makeClassFunc(
            funcName: 'f', className: 'C', libraryUri: 'package:app/a.dart'),
      ];
      final samples = [
        makeSample(stack: [-1]), // negative index
        makeSample(stack: [0]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result, hasLength(1));
      expect(result[0].functionName, 'f');
      expect(result[0].percentage, 100.0);
    });

    test('sample with out-of-bounds function index is skipped', () {
      final funcs = [
        makeClassFunc(
            funcName: 'f', className: 'C', libraryUri: 'package:app/a.dart'),
      ];
      final samples = [
        makeSample(stack: [99]), // out of bounds
        makeSample(stack: [0]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      expect(result, hasLength(1));
      expect(result[0].percentage, 100.0);
    });

    test('only exclusive ticks counted (top of stack)', () {
      // stack[0] is the top (leaf) function, stack[1..n] are callers
      final funcs = [
        makeClassFunc(
            funcName: 'leaf', className: 'A', libraryUri: 'package:app/a.dart'),
        makeClassFunc(
            funcName: 'caller',
            className: 'B',
            libraryUri: 'package:app/b.dart'),
      ];
      // leaf is top-of-stack in all samples; caller only appears deeper
      final samples = [
        makeSample(stack: [0, 1]),
        makeSample(stack: [0, 1]),
        makeSample(stack: [0]),
      ];

      final result = aggregator
          .aggregate(makeCpuSamples(functions: funcs, samples: samples));
      // Only 'leaf' should appear — caller never at top of stack
      expect(result, hasLength(1));
      expect(result[0].functionName, 'leaf');
      expect(result[0].percentage, 100.0);
    });

    test('custom topN parameter', () {
      final funcs = List.generate(
        10,
        (i) => makeClassFunc(
            funcName: 'f$i',
            className: 'C$i',
            libraryUri: 'package:app/$i.dart'),
      );
      final samples = List.generate(10, (i) => makeSample(stack: [i]));

      final result = aggregator.aggregate(
        makeCpuSamples(functions: funcs, samples: samples),
        topN: 3,
      );
      expect(result, hasLength(3));
    });
  });

  // ---------------------------------------------------------------------------
  // Call chain extraction
  // ---------------------------------------------------------------------------
  group('call chain extraction', () {
    test('basic chain from user root to hot function', () {
      // Stack: [layout(0), performLayout(1), MyWidget.build(2)]
      // Chain should be: MyWidget.build → performLayout → layout
      final funcs = [
        makeClassFunc(
            funcName: 'layout',
            className: 'RenderBox',
            libraryUri: 'package:flutter/rendering.dart'),
        makeClassFunc(
            funcName: 'performLayout',
            className: 'RenderFlex',
            libraryUri: 'package:flutter/rendering.dart'),
        makeClassFunc(
            funcName: 'build',
            className: 'MyWidget',
            libraryUri: 'package:app/my_widget.dart'),
      ];
      final samples = [
        makeSample(stack: [0, 1, 2]),
        makeSample(stack: [0, 1, 2]),
      ];

      final result = aggregator.aggregate(
        makeCpuSamples(functions: funcs, samples: samples),
      );

      expect(result, hasLength(1));
      expect(result[0].callChain, isNotNull);
      expect(result[0].callChain, [
        'MyWidget.build',
        'RenderFlex.performLayout',
        'RenderBox.layout',
      ]);
    });

    test('user code at top of stack produces single-entry chain', () {
      // Stack: [MyWidget.build(0)] — user code is already at top
      final funcs = [
        makeClassFunc(
            funcName: 'build',
            className: 'MyWidget',
            libraryUri: 'package:app/my_widget.dart'),
      ];
      final samples = [
        makeSample(stack: [0])
      ];

      final result = aggregator.aggregate(
        makeCpuSamples(functions: funcs, samples: samples),
      );

      expect(result, hasLength(1));
      expect(result[0].callChain, ['MyWidget.build']);
    });

    test('framework-only stack annotated with (framework)', () {
      // All framework — no user code in stack
      final funcs = [
        makeClassFunc(
            funcName: 'layout',
            className: 'RenderBox',
            libraryUri: 'package:flutter/rendering.dart'),
        makeClassFunc(
            funcName: 'performLayout',
            className: 'RenderFlex',
            libraryUri: 'package:flutter/rendering.dart'),
        makeClassFunc(
            funcName: 'buildScope',
            className: 'BuildOwner',
            libraryUri: 'package:flutter/widgets.dart'),
      ];
      // Need >50% framework to keep these in results
      final samples = [
        makeSample(stack: [0, 1, 2]),
        makeSample(stack: [0, 1, 2]),
      ];

      final result = aggregator.aggregate(
        makeCpuSamples(functions: funcs, samples: samples),
      );

      expect(result, hasLength(1));
      expect(result[0].callChain, isNotNull);
      expect(result[0].callChain![0], contains('(framework)'));
    });

    test('chain truncated at depth 5', () {
      // 8 frames deep: user root at [7], hot at [0]
      final funcs = List.generate(
        8,
        (i) => makeClassFunc(
          funcName: 'f$i',
          className: 'C$i',
          libraryUri: i == 7
              ? 'package:app/root.dart'
              : 'package:flutter/rendering.dart',
        ),
      );
      // Need framework >50% since 7/8 are framework
      final samples = [
        makeSample(stack: [0, 1, 2, 3, 4, 5, 6, 7])
      ];

      final result = aggregator.aggregate(
        makeCpuSamples(functions: funcs, samples: samples),
      );

      expect(result, hasLength(1));
      expect(result[0].callChain, isNotNull);
      expect(result[0].callChain!.length, 5);
      // Root preserved
      expect(result[0].callChain![0], 'C7.f7');
      // Truncation marker
      expect(result[0].callChain![2], '...');
      // Hot function preserved
      expect(result[0].callChain![4], 'C0.f0');
    });

    test('inclusive percentage >= exclusive percentage', () {
      // Function at index 0 is top of stack in 2 samples,
      // but appears anywhere in 4 samples total
      final funcs = [
        makeClassFunc(
            funcName: 'build',
            className: 'MyWidget',
            libraryUri: 'package:app/w.dart'),
        makeClassFunc(
            funcName: 'render',
            className: 'Renderer',
            libraryUri: 'package:app/r.dart'),
      ];
      final samples = [
        makeSample(stack: [0]), // func 0 exclusive + inclusive
        makeSample(stack: [0]), // func 0 exclusive + inclusive
        makeSample(stack: [1, 0]), // func 0 inclusive only (func 1 exclusive)
        makeSample(stack: [1, 0]), // func 0 inclusive only (func 1 exclusive)
      ];

      final result = aggregator.aggregate(
        makeCpuSamples(functions: funcs, samples: samples),
      );

      for (final attr in result) {
        expect(
          attr.inclusivePercentage,
          greaterThanOrEqualTo(attr.percentage),
          reason:
              '${attr.displayName}: inclusive ${attr.inclusivePercentage} should be >= exclusive ${attr.percentage}',
        );
      }

      // Verify specific values for func 0
      final myWidget = result.firstWhere((a) => a.className == 'MyWidget');
      expect(myWidget.percentage, 50.0); // 2/4 exclusive
      expect(myWidget.inclusivePercentage, 100.0); // 4/4 inclusive
    });

    test('most common chain wins when multiple paths exist', () {
      // func 0 (hot) reached via two different paths
      final funcs = [
        makeClassFunc(
            funcName: 'layout',
            className: 'RenderBox',
            libraryUri: 'package:flutter/rendering.dart'),
        makeClassFunc(
            funcName: 'buildA',
            className: 'WidgetA',
            libraryUri: 'package:app/a.dart'),
        makeClassFunc(
            funcName: 'buildB',
            className: 'WidgetB',
            libraryUri: 'package:app/b.dart'),
      ];
      // Path via WidgetA: 3 samples, path via WidgetB: 1 sample
      // Framework >50% so all kept
      final samples = [
        makeSample(stack: [0, 1]),
        makeSample(stack: [0, 1]),
        makeSample(stack: [0, 1]),
        makeSample(stack: [0, 2]),
      ];

      final result = aggregator.aggregate(
        makeCpuSamples(functions: funcs, samples: samples),
      );

      final layoutAttr = result.firstWhere((a) => a.functionName == 'layout');
      expect(layoutAttr.callChain, isNotNull);
      // Path A (via WidgetA) should win — 3 samples vs 1
      expect(layoutAttr.callChain!, contains('WidgetA.buildA'));
    });

    test('null chain when no matching samples', () {
      // No samples at all
      final funcs = [
        makeClassFunc(
            funcName: 'build',
            className: 'MyWidget',
            libraryUri: 'package:app/w.dart'),
      ];

      final result = aggregator.aggregate(
        makeCpuSamples(functions: funcs, samples: []),
      );

      expect(result, isEmpty);
    });

    test('chain stops at first user root from top', () {
      // Stack: [layout(0/fw), MyHelper.run(1/user), performLayout(2/fw), MyWidget.build(3/user)]
      // First user code from top (index 0) is MyHelper.run at index 1
      // Chain should root at MyHelper.run, NOT go up to MyWidget.build
      // Framework 3/5 = 60% > 50%, so all functions kept
      final funcs2 = [
        makeClassFunc(
            funcName: 'layout',
            className: 'RenderBox',
            libraryUri: 'package:flutter/rendering.dart'),
        makeClassFunc(
            funcName: 'run',
            className: 'MyHelper',
            libraryUri: 'package:app/helper.dart'),
        makeClassFunc(
            funcName: 'performLayout',
            className: 'RenderFlex',
            libraryUri: 'package:flutter/rendering.dart'),
        makeClassFunc(
            funcName: 'build',
            className: 'MyWidget',
            libraryUri: 'package:app/my_widget.dart'),
        makeClassFunc(
            funcName: 'buildScope',
            className: 'BuildOwner',
            libraryUri: 'package:flutter/widgets.dart'),
      ];
      // 3 framework + 2 user = 5. Framework = 3/5 = 60% > 50%, all kept
      final samples = [
        makeSample(stack: [0, 1, 2, 3, 4]),
        makeSample(stack: [0, 1, 2, 3, 4]),
        makeSample(stack: [0, 1, 2, 3, 4]),
      ];

      final result = aggregator.aggregate(
        makeCpuSamples(functions: funcs2, samples: samples),
      );

      final layoutAttr = result.firstWhere((a) => a.functionName == 'layout');
      expect(layoutAttr.callChain, isNotNull);
      // Chain should root at MyHelper.run (first user code from top),
      // not MyWidget.build (further up the stack)
      expect(layoutAttr.callChain![0], 'MyHelper.run');
      expect(layoutAttr.callChain!.last, 'RenderBox.layout');
    });
  });
}
