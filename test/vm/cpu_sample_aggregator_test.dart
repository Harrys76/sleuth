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
}
