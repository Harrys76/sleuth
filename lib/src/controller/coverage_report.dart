import 'package:flutter/foundation.dart';

import '../models/base_detector.dart';

/// How much of one built-in check can run.
enum CheckCoverage {
  /// Every signal the check reads is available.
  on,

  /// A hybrid check without the VM: its structural or frame half runs, the
  /// VM half does not.
  partial,

  /// The check reads only the VM, and the VM is not connected.
  needsVm,

  /// The check needs an opt-in that is off: `profilePlatformChannels` for
  /// the platform channel check, a `Sleuth.trackResource` call for the
  /// tracked resource check.
  optInOff,

  /// Left out of `SleuthConfig.enabledDetectors`.
  disabled,
}

/// The coverage of every built-in check for the current VM link and
/// config. Custom detectors are not counted.
@immutable
class CoverageReport {
  const CoverageReport(this.byType);

  /// Builds the report from the enabled types, each enabled type's
  /// lifecycle, and the signals the checks depend on.
  ///
  /// A hybrid check without the VM counts as [CheckCoverage.on] when debug
  /// callbacks feed it ([debugFeedsRebuild], [debugFeedsRepaint]).
  factory CoverageReport.compute({
    required Set<DetectorType> enabled,
    required DetectorLifecycle? Function(DetectorType type) lifecycleOf,
    required bool vmConnected,
    required bool profilePlatformChannels,
    required bool resourcesTracked,
    bool debugFeedsRebuild = false,
    bool debugFeedsRepaint = false,
  }) {
    CheckCoverage coverageOf(DetectorType type) {
      if (!enabled.contains(type)) return CheckCoverage.disabled;
      switch (type) {
        case DetectorType.platformChannel:
          if (!vmConnected) return CheckCoverage.needsVm;
          return profilePlatformChannels
              ? CheckCoverage.on
              : CheckCoverage.optInOff;
        case DetectorType.trackedResource:
          return resourcesTracked ? CheckCoverage.on : CheckCoverage.optInOff;
        default:
          break;
      }
      switch (lifecycleOf(type)) {
        case DetectorLifecycle.vmOnly:
          return vmConnected ? CheckCoverage.on : CheckCoverage.needsVm;
        case DetectorLifecycle.hybrid:
          if (vmConnected) return CheckCoverage.on;
          final fed =
              (type == DetectorType.rebuild && debugFeedsRebuild) ||
              (type == DetectorType.repaint && debugFeedsRepaint);
          return fed ? CheckCoverage.on : CheckCoverage.partial;
        case DetectorLifecycle.runtime:
        case DetectorLifecycle.structural:
        case null:
          return CheckCoverage.on;
      }
    }

    return CoverageReport({
      for (final type in DetectorType.values)
        if (type != DetectorType.custom) type: coverageOf(type),
    });
  }

  /// Coverage of each built-in check.
  final Map<DetectorType, CheckCoverage> byType;

  /// Number of checks with [coverage].
  int count(CheckCoverage coverage) =>
      byType.values.where((c) => c == coverage).length;

  /// The checks with [coverage], in [DetectorType] order.
  List<DetectorType> typesWith(CheckCoverage coverage) => [
    for (final e in byType.entries)
      if (e.value == coverage) e.key,
  ];

  @override
  bool operator ==(Object other) =>
      other is CoverageReport && mapEquals(byType, other.byType);

  @override
  int get hashCode => Object.hashAllUnordered(
    byType.entries.map((e) => Object.hash(e.key, e.value)),
  );

  @override
  String toString() =>
      'CoverageReport(on: ${count(CheckCoverage.on)}, '
      'partial: ${count(CheckCoverage.partial)}, '
      'needsVm: ${count(CheckCoverage.needsVm)}, '
      'optInOff: ${count(CheckCoverage.optInOff)}, '
      'disabled: ${count(CheckCoverage.disabled)})';
}
