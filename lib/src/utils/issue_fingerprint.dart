import '../models/performance_issue.dart';
import 'measurement_text.dart';

/// Every field of [issue] the overlay renders, joined into one string.
///
/// Leaves out timestamps, ranking scores and trace arguments, which change
/// every scan without changing what a reader sees. The controller publishes
/// a new issue list only when the joined fingerprints change, and the card
/// list keeps a card whose issue has the same fingerprint. An issue is
/// immutable, so the string is kept per issue.
String issueFingerprint(PerformanceIssue issue) =>
    _fingerprints[issue] ??= _fingerprintOf(issue);

final Expando<String> _fingerprints = Expando('Sleuth issue fingerprint');

String _fingerprintOf(PerformanceIssue i) {
  final b = StringBuffer()
    ..write(i.stableId)
    ..write('|')
    ..write(i.severity.name)
    ..write('|')
    ..write(i.confidence.name)
    ..write('|')
    ..write(i.category.name)
    ..write('|')
    ..write(i.title)
    ..write('|')
    ..write(i.detail)
    ..write('|')
    ..write(i.fixHint)
    ..write('|')
    ..write(i.widgetName)
    ..write('|')
    ..write(i.ancestorChain)
    ..write('|')
    ..write(i.routeName)
    ..write('|')
    ..write(i.tabVisitIndex)
    ..write('|')
    // Two first visits of tabs on one route differ only here, and the
    // card compares it with the current screen.
    ..write(i.scaffoldHashKey)
    ..write('|')
    ..write(i.observationSource?.name)
    ..write('|')
    ..write(i.interactionContext?.name)
    ..write('|')
    ..write(i.debugModeDisclaimer)
    ..write('|')
    ..write(i.fixEffort?.name)
    ..write('|')
    ..write(i.confidenceReason)
    ..write('|')
    ..write(i.rootCauseIds?.join(','))
    ..write('|')
    ..write(i.downstreamIds?.join(','))
    ..write('|')
    // As the card's Measured row shows it, not the raw value: a held
    // rate moves in its last digits while the row reads the same.
    ..write(measuredText(i));
  return b.toString();
}
