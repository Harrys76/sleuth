import 'package:flutter/foundation.dart';

import 'issue_measurement.dart';
import 'performance_issue.dart';

/// An issue the user marked as not useful in the overlay this session.
///
/// Marks live in memory for the session only. Exports and the
/// `ext.sleuth.*` payloads carry them, so whoever reads an export can see
/// which issues the user found unhelpful.
@immutable
final class NotUsefulMark {
  const NotUsefulMark({
    required this.key,
    this.stableId,
    required this.title,
    required this.category,
    required this.severity,
    required this.confidence,
    this.measurement,
    this.route,
    required this.markedAt,
    this.live = true,
  });

  /// The mark for [issue] under [key], taken at [markedAt].
  factory NotUsefulMark.fromIssue(
    PerformanceIssue issue, {
    required String key,
    required DateTime markedAt,
  }) => NotUsefulMark(
    key: key,
    stableId: issue.stableId,
    title: issue.title,
    category: issue.category,
    severity: issue.severity,
    confidence: issue.confidence,
    measurement: issue.measurement,
    route: issue.sourceRoute ?? issue.routeName,
    markedAt: markedAt,
  );

  /// The overlay's list key of the issue: its stable id, or its title
  /// when it has none, plus its widget name.
  final String key;

  final String? stableId;

  /// The issue's title when it was marked.
  final String title;

  final IssueCategory category;

  final IssueSeverity severity;

  final IssueConfidence confidence;

  /// The issue's measurement when it was marked.
  final IssueMeasurement? measurement;

  /// The route the issue was reported on.
  final String? route;

  final DateTime markedAt;

  /// Whether the issue was still reported when the mark was read.
  final bool live;

  /// A copy with [live] set.
  NotUsefulMark withLive(bool live) => live == this.live
      ? this
      : NotUsefulMark(
          key: key,
          stableId: stableId,
          title: title,
          category: category,
          severity: severity,
          confidence: confidence,
          measurement: measurement,
          route: route,
          markedAt: markedAt,
          live: live,
        );

  Map<String, dynamic> toJson() => {
    'key': key,
    'stableId': ?stableId,
    'title': title,
    'category': category.name,
    'severity': severity.name,
    'confidence': confidence.name,
    if (measurement case final m? when m.hasFiniteValue)
      'measurement': m.toJson(),
    'route': ?route,
    'markedAt': markedAt.toIso8601String(),
    'live': live,
  };

  /// Reads a mark written by [toJson], or returns null when a required
  /// field is missing or not one this release knows.
  static NotUsefulMark? fromJson(Object? json) {
    if (json is! Map) return null;
    final key = json['key'];
    final title = json['title'];
    final category = _byName(IssueCategory.values, json['category']);
    final severity = _byName(IssueSeverity.values, json['severity']);
    final confidence = _byName(IssueConfidence.values, json['confidence']);
    final markedAt = json['markedAt'] is String
        ? DateTime.tryParse(json['markedAt'] as String)
        : null;
    if (key is! String ||
        title is! String ||
        category == null ||
        severity == null ||
        confidence == null ||
        markedAt == null) {
      return null;
    }
    final stableId = json['stableId'];
    final route = json['route'];
    return NotUsefulMark(
      key: key,
      stableId: stableId is String ? stableId : null,
      title: title,
      category: category,
      severity: severity,
      confidence: confidence,
      measurement: IssueMeasurement.fromJson(json['measurement']),
      route: route is String ? route : null,
      markedAt: markedAt,
      live: json['live'] != false,
    );
  }

  static T? _byName<T extends Enum>(List<T> values, Object? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is NotUsefulMark &&
      other.key == key &&
      other.stableId == stableId &&
      other.title == title &&
      other.category == category &&
      other.severity == severity &&
      other.confidence == confidence &&
      other.measurement == measurement &&
      other.route == route &&
      other.markedAt == markedAt &&
      other.live == live;

  @override
  int get hashCode => Object.hash(
    key,
    stableId,
    title,
    category,
    severity,
    confidence,
    measurement,
    route,
    markedAt,
    live,
  );
}
