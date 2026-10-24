import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/utils/issue_metadata_builder.dart';

PerformanceIssue _issue(IssueConfidence confidence, {String? reason}) =>
    PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.paint,
      confidence: confidence,
      title: 'T',
      detail: 'D',
      fixHint: 'F',
      confidenceReason: reason,
    );

void main() {
  group('IssueMetadataBuilder.evidence', () {
    // A reason can end in advice; the confidence reads as its own
    // sentence after it.
    test('a possible issue after a reason that ends in advice', () {
      expect(
        IssueMetadataBuilder.evidence(
          _issue(
            IssueConfidence.possible,
            reason:
                'Structural scan only. Enable debug callbacks for paint '
                'evidence',
          ),
        ),
        'Structural scan only. Enable debug callbacks for paint evidence. '
        'Sleuth rates it possible, since no runtime signal confirmed it.',
      );
    });

    test('likely and confirmed', () {
      expect(
        IssueMetadataBuilder.evidence(
          _issue(IssueConfidence.likely, reason: 'Rebuild evidence.'),
        ),
        'Rebuild evidence. Sleuth rates it likely, not confirmed.',
      );
      expect(
        IssueMetadataBuilder.evidence(_issue(IssueConfidence.confirmed)),
        'From the overlay heuristics. Sleuth rates it confirmed.',
      );
    });
  });
}
