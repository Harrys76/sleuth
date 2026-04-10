// ignore_for_file: file_names
// The cookbook files are numbered to suggest a reading order. The leading
// digits trip the `file_names` lint, which expects lower_case_with_underscores
// identifiers without a leading digit. We intentionally keep the numeric
// prefix because it's the first thing readers see in the directory listing.

import 'package:flutter/material.dart';
import 'package:sleuth/sleuth.dart';

/// Cookbook 01 — The minimal custom detector.
///
/// Counts [Tooltip] widgets in the build tree and emits one info-level
/// [PerformanceIssue] per Tooltip on every scan.
///
/// This is the simplest shape a custom detector can take. It extends
/// [SimpleStructuralDetector], which handles all the per-scan plumbing for
/// you (issue list, highlight list, enabled flag, dispose). You only have
/// to answer two questions:
///
/// 1. **Which elements are interesting?** → [inspect] receives every
///    [Element] in the tree and decides whether it matches.
/// 2. **What issue should we emit when we find one?** → call [report] from
///    inside [inspect] with the issue metadata.
///
/// Use this shape when:
///
/// - You're inspecting widget structure (no VM / timeline data required).
/// - One matching element maps to one emitted issue — no aggregation,
///   no cross-scan counters, no depth tracking.
/// - You want the simplest possible implementation so the rule stays
///   obvious to readers.
///
/// If you need cross-scan state (rebuild counters, rolling windows) or
/// ancestor-chain tracking, skip this helper and extend [BaseDetector]
/// directly — see `02_runtime_callback_detector.dart` and
/// `03_hybrid_vm_structural_detector.dart` for those shapes.
///
/// ### Wiring
///
/// ```dart
/// Sleuth.track(
///   child: const MyApp(),
///   config: SleuthConfig(
///     customDetectors: [TooltipUsageDetector()],
///   ),
/// );
/// ```
///
/// ### Disabling without removing
///
/// The constructor passes `key: 'tooltip_usage'` to the super class. That
/// makes the detector respond to [SleuthConfig.disabledCustomDetectorKeys]:
///
/// ```dart
/// SleuthConfig(
///   customDetectors: [TooltipUsageDetector()],
///   disabledCustomDetectorKeys: {'tooltip_usage'},
/// )
/// ```
class TooltipUsageDetector extends SimpleStructuralDetector {
  TooltipUsageDetector()
    : super(
        name: 'Tooltip Usage',
        description: 'Counts Tooltip widgets in the build tree',
        // Stable key lets this detector be disabled via
        // SleuthConfig.disabledCustomDetectorKeys without removing the
        // instance from the detector list.
        key: 'tooltip_usage',
      );

  /// Framework-provided tooltip messages that Material widgets create
  /// automatically (AppBar back button, drawer hamburger, etc.).
  /// These are not user-authored and should not be flagged.
  static const _frameworkMessages = <String>{
    'Back',
    'Close',
    'Open navigation menu',
    'Search',
    'Show menu',
    'More',
    'Dismiss',
  };

  @override
  void inspect(Element element) {
    // Cheap type check first — [inspect] runs on every element in the
    // visible tree, so keep this path allocation-free for non-matches.
    if (element.widget is! Tooltip) return;

    final tooltip = element.widget as Tooltip;
    final message = tooltip.message ?? '';

    // Skip standard Material framework tooltips (e.g. AppBar back button).
    if (_frameworkMessages.contains(message)) return;

    // stableId should be STABLE across rebuilds so the correlator can
    // dedupe the finding over the life of the app. Do NOT use
    // `identityHashCode(element.widget)` — Flutter creates a fresh Widget
    // instance on every rebuild, so identity-based IDs generate one new
    // issue per rebuild and flood the overlay.
    //
    // Here we key on the Tooltip's `message`, which is user-authored and
    // stable across rebuilds. Two tooltips with the same message will
    // dedupe to a single issue — an acceptable tradeoff for a cookbook
    // example. A production detector that needs per-instance dedup should
    // use widget source location (file:line) from `DiagnosticsNode`.
    final keySuffix = message.isEmpty ? 'anonymous' : message;

    report(
      stableId: 'tooltip_usage::$keySuffix',
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      title: 'Tooltip detected',
      detail: message.isEmpty
          ? 'A Tooltip widget is present in the build tree.'
          : 'Tooltip "$message" is present in the build tree.',
      fixHint:
          'Tooltips are usually fine — this detector is a cookbook example. '
          'A real detector would flag a more specific anti-pattern.',
      element: element,
    );
  }
}
