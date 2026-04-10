import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'base_detector.dart';
import 'performance_issue.dart';
import 'widget_highlight.dart';

/// Convenience base class for writing a structural custom detector without
/// the full [BaseDetector] boilerplate.
///
/// Most real-world custom detectors only need three things:
///
/// 1. Inspect each [Element] in the tree.
/// 2. Emit a [PerformanceIssue] when a pattern is found.
/// 3. Optionally highlight the offending widget in the overlay.
///
/// [SimpleStructuralDetector] handles everything else: lists, dispose, the
/// `isEnabled` flag, and the scan-cycle reset. Subclasses override a single
/// method — [inspect] — and call [report] when they find a problem.
///
/// ```dart
/// class MyDetector extends SimpleStructuralDetector {
///   MyDetector() : super(
///     key: 'my_rule',
///     name: 'My Rule',
///     description: 'Flags misuse of Foo',
///   );
///
///   @override
///   void inspect(Element element) {
///     if (element.widget is Foo && (element.widget as Foo).bad) {
///       report(
///         stableId: 'my_rule_${element.widget.runtimeType}',
///         severity: IssueSeverity.warning,
///         category: IssueCategory.build,
///         title: 'Bad Foo usage',
///         detail: 'Foo should not be used this way.',
///         fixHint: 'Use Bar instead.',
///         element: element,
///       );
///     }
///   }
/// }
/// ```
///
/// ### What this class is not
///
/// - **Not for VM / timeline detectors.** Structural only — if you need VM
///   timeline data, extend [BaseDetector] directly and pick
///   [DetectorLifecycle.hybrid] or [DetectorLifecycle.vmOnly].
/// - **Not a replacement for cross-scan accumulators.** The issue list is
///   cleared at the start of every scan. If you need to track state across
///   scans (rebuild counters, rolling windows), store it in your subclass
///   and reset it yourself in [onPrepareScan].
/// - **Not a pattern registry.** This helper is about reducing boilerplate
///   for a single detector. Apps should still compose multiple detectors
///   in [SleuthConfig.customDetectors] when they want to ship several
///   rules.
abstract class SimpleStructuralDetector extends BaseDetector {
  /// Creates a new simple structural detector.
  ///
  /// - [key] is the stable identifier used by
  ///   [SleuthConfig.disabledCustomDetectorKeys] to gate the detector
  ///   off at init time. Leave null to opt out of config-driven gating.
  /// - [name] is the human-readable label shown in the overlay.
  /// - [description] is a short summary of what the detector looks for.
  SimpleStructuralDetector({
    required super.name,
    required super.description,
    super.key,
  }) : super(
          type: DetectorType.custom,
          lifecycle: DetectorLifecycle.structural,
        );

  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => _issues;

  @override
  List<WidgetHighlight> get highlights => _highlights;

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Clears findings at the start of every scan.
  ///
  /// Subclasses that need extra per-scan state should override
  /// [onPrepareScan], not this method. The unified walk calls
  /// [prepareScan] once before visiting any element.
  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    onPrepareScan(context);
  }

  /// Optional hook for subclass per-scan state reset.
  ///
  /// Default is a no-op. Override this if your detector carries cross-walk
  /// state (e.g. a set of seen identity hash codes) that should reset at
  /// the start of every scan cycle.
  void onPrepareScan(BuildContext context) {}

  /// Delegates to [inspect] for each element in the unified walk.
  ///
  /// Marked `final` so subclasses cannot accidentally bypass the enabled
  /// check or the inspect contract.
  @override
  @nonVirtual
  void checkElement(Element element) {
    if (!_isEnabled) return;
    inspect(element);
  }

  /// Inspect a single element and emit issues via [report].
  ///
  /// Called once per element during the unified structural scan, in
  /// depth-first order. Never call this directly — the controller handles
  /// dispatch. Subclasses MUST override this.
  ///
  /// This method may be called very frequently (tens of thousands of times
  /// per second across large trees), so:
  /// - Do not allocate unless you have actually found a pattern match.
  /// - Guard expensive checks behind a cheap `widget is` type check first.
  /// - Do not walk the tree manually — the unified walk already visits
  ///   every element.
  void inspect(Element element);

  /// Emit a performance issue from within [inspect].
  ///
  /// Pass the [element] whose widget triggered the finding so that the
  /// helper can attach a [WidgetHighlight] for the overlay.
  ///
  /// [stableId] should be unique enough that the correlator can dedupe
  /// it across scans — prefix with the detector name and include the
  /// offending widget's type or location (e.g.
  /// `'my_rule_${element.widget.runtimeType}'`).
  ///
  /// Pass [observationSource] to override the default
  /// [ObservationSource.structural] when your detector uses a different
  /// data source; most simple structural detectors can leave it at the
  /// default.
  @protected
  void report({
    required String stableId,
    required IssueSeverity severity,
    required IssueCategory category,
    required String title,
    required String detail,
    required String fixHint,
    required Element element,
    IssueConfidence confidence = IssueConfidence.possible,
    ObservationSource observationSource = ObservationSource.structural,
  }) {
    _issues.add(
      PerformanceIssue(
        stableId: stableId,
        severity: severity,
        category: category,
        confidence: confidence,
        title: title,
        detail: detail,
        fixHint: fixHint,
        observationSource: observationSource,
        detectedAt: DateTime.now(),
      ),
    );

    final ro = element.renderObject;
    if (ro is RenderBox && ro.hasSize && ro.attached) {
      final offset = ro.localToGlobal(Offset.zero);
      _highlights.add(
        WidgetHighlight(
          rect: offset & ro.size,
          widgetName: element.widget.runtimeType.toString(),
          severity: severity,
          detectorName: name,
        ),
      );
    }
  }

  /// Clears the issue and highlight lists. Override [onDispose] for
  /// subclass-specific cleanup (cancel timers, close streams, etc).
  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    onDispose();
  }

  /// Optional hook for subclass cleanup in [dispose].
  ///
  /// Default is a no-op. Override this if your detector holds resources
  /// like [Timer]s, [StreamSubscription]s, or [ValueNotifier]s.
  void onDispose() {}
}
