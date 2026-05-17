import 'dart:async';
import 'dart:collection' show LinkedHashSet;
import 'dart:convert';

import 'package:meta/meta.dart';

import '../analyzer/causal_graph.dart';
import '../controller/sleuth_controller.dart';
import '../models/route_session.dart';
import '../utils/issue_explanation_builder.dart';
import 'connection_mode.dart';
import 'service_extension_registry.dart';

/// MCP envelope shape version. Distinct from `SessionSnapshot.schemaVersion`.
const int kMcpEnvelopeSchemaVersion = 1;

/// Stamped on `ext.sleuth.diagnose`. Keep in sync with `pubspec.yaml`.
const String kSleuthPackageVersion = '0.32.0';

typedef ExtensionHandler = FutureOr<Map<String, Object?>> Function(
  SleuthController controller,
  Map<String, String> args,
);

Map<String, Object?> envelopeOk({
  required SleuthController controller,
  required Object? data,
}) {
  return <String, Object?>{
    'connectionMode': computeConnectionMode(controller).name,
    'schemaVersion': kMcpEnvelopeSchemaVersion,
    'sessionUuid': controller.sessionUuid,
    'data': sanitizeForJson(data),
  };
}

/// Envelope keys callers cannot override via `envelopeError`'s `extra`.
const Set<String> _kReservedEnvelopeKeys = {
  'connectionMode',
  'schemaVersion',
  'sessionUuid',
  'error',
  'stack',
};

Map<String, Object?> envelopeError({
  required SleuthController controller,
  required String error,
  String? stack,
  Map<String, Object?>? extra,
}) {
  final filteredExtra = extra == null
      ? const <String, Object?>{}
      : <String, Object?>{
          for (final entry in extra.entries)
            if (!_kReservedEnvelopeKeys.contains(entry.key))
              entry.key: entry.value,
        };
  return <String, Object?>{
    'connectionMode': computeConnectionMode(controller).name,
    'schemaVersion': kMcpEnvelopeSchemaVersion,
    'sessionUuid': controller.sessionUuid,
    'error': error,
    if (stack != null) 'stack': stack,
    ...filteredExtra,
  };
}

const int _kMaxSanitizeDepth = 256;
const int _kReprMaxLength = 1024;

/// Rebuild [value] into a JSON-encodable tree. Cycles, depth overflow,
/// non-encodable leaves, non-`String` map keys colliding after string
/// coercion, and non-`List` `Iterable`s each get a typed envelope marker
/// instead of throwing. Identity-based cycle detection avoids
/// false-positives on `Map` subclasses with custom `==`.
@visibleForTesting
Object? sanitizeForJson(Object? value) {
  final visited = LinkedHashSet<Object>(
    equals: identical,
    hashCode: identityHashCode,
  );
  return _sanitize(value, visited, 0);
}

String _truncatedRepr(Object value) {
  final s = value.toString();
  if (s.length <= _kReprMaxLength) return s;
  return '${s.substring(0, _kReprMaxLength)}…';
}

Map<String, Object?> _cycleEnvelope(Object value) => <String, Object?>{
      '__cycle': true,
      'repr': _truncatedRepr(value),
    };

Map<String, Object?> _truncatedEnvelope(Object? value, int depth) =>
    <String, Object?>{
      '__truncated': true,
      'depth': depth,
      'repr': value == null ? 'null' : _truncatedRepr(value),
    };

Object? _sanitize(Object? value, Set<Object> visited, int depth) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  if (depth >= _kMaxSanitizeDepth) {
    return _truncatedEnvelope(value, depth);
  }
  if (value is Map) {
    if (!visited.add(value)) return _cycleEnvelope(value);
    try {
      final out = <String, Object?>{};
      for (final entry in value.entries) {
        final key = '${entry.key}';
        final sanitised = _sanitize(entry.value, visited, depth + 1);
        if (out.containsKey(key)) {
          // Non-`String` key collided with an existing entry after coercion.
          out[key] = <String, Object?>{
            '__keyCollision': true,
            'prior': out[key],
            'next': sanitised,
          };
        } else {
          out[key] = sanitised;
        }
      }
      return out;
    } finally {
      visited.remove(value);
    }
  }
  if (value is List) {
    if (!visited.add(value)) return _cycleEnvelope(value);
    try {
      return [for (final e in value) _sanitize(e, visited, depth + 1)];
    } finally {
      visited.remove(value);
    }
  }
  if (value is Iterable) {
    if (!visited.add(value)) return _cycleEnvelope(value);
    try {
      return [for (final e in value) _sanitize(e, visited, depth + 1)];
    } catch (e) {
      return <String, Object?>{
        '__nonSerializable': value.runtimeType.toString(),
        'iterationError': '$e',
        'repr': _truncatedRepr(value),
      };
    } finally {
      visited.remove(value);
    }
  }
  try {
    jsonEncode(value);
    return value;
  } catch (_) {
    return <String, Object?>{
      '__nonSerializable': value.runtimeType.toString(),
      'repr': _truncatedRepr(value),
    };
  }
}

// Handlers — one per ext.sleuth.* extension. Pure over controller state.

/// `ext.sleuth.snapshot` — full `SessionSnapshot.toJson()` payload.
FutureOr<Map<String, Object?>> extSnapshotHandler(
  SleuthController controller,
  Map<String, String> args,
) {
  final snapshot = controller.exportSnapshot();
  return envelopeOk(controller: controller, data: snapshot.toJson());
}

/// `ext.sleuth.issues` — currently-aggregated issues, optional `route` filter
/// against `routeName` or `sourceRoute`.
FutureOr<Map<String, Object?>> extIssuesHandler(
  SleuthController controller,
  Map<String, String> args,
) {
  final route = _nullIfEmpty(args['route']);
  final all = controller.issuesNotifier.value;
  final filtered = route == null
      ? all
      : all
          .where((i) => i.routeName == route || i.sourceRoute == route)
          .toList(growable: false);
  return envelopeOk(controller: controller, data: <String, Object?>{
    'issues': [for (final i in filtered) i.toJson()],
    if (route != null) 'route': route,
  });
}

/// `ext.sleuth.routeHealth` — per-route health rollup.
///
/// Without `route`, returns the full `routeHistoryNotifier` value as a
/// `routes: [...]` list. With `route`, returns a single matching session
/// (most recent if multiple share the name) or `error: 'unknown_route'`.
FutureOr<Map<String, Object?>> extRouteHealthHandler(
  SleuthController controller,
  Map<String, String> args,
) {
  final history = controller.routeHistoryNotifier.value;
  final route = _nullIfEmpty(args['route']);
  if (route == null) {
    return envelopeOk(controller: controller, data: <String, Object?>{
      'routes': [for (final r in history) r.toJson()],
    });
  }
  RouteSession? match;
  for (final r in history) {
    if (r.routeName == route) match = r;
  }
  if (match == null) {
    return envelopeError(
      controller: controller,
      error: 'unknown_route',
      extra: <String, Object?>{'route': route},
    );
  }
  return envelopeOk(controller: controller, data: match.toJson());
}

/// `ext.sleuth.explain` — encyclopedia entry for a `stableId`. Parametric /
/// dynamic suffixes resolve through `IssueExplanationBuilder.canonicalId`.
FutureOr<Map<String, Object?>> extExplainHandler(
  SleuthController controller,
  Map<String, String> args,
) {
  final stableId = args['stableId'];
  if (stableId == null || stableId.isEmpty) {
    return envelopeError(
      controller: controller,
      error: 'missing_required_arg',
      extra: <String, Object?>{'arg': 'stableId'},
    );
  }
  final canonical = IssueExplanationBuilder.canonicalId(stableId);
  final entry = IssueExplanationBuilder.allExplanations[canonical];
  if (entry == null) {
    return envelopeError(
      controller: controller,
      error: 'unknown_stable_id',
      extra: <String, Object?>{
        'stableId': stableId,
        'canonical': canonical,
      },
    );
  }
  return envelopeOk(controller: controller, data: <String, Object?>{
    'stableId': stableId,
    'canonical': canonical,
    'explanation': _explanationToMap(entry),
  });
}

/// `ext.sleuth.encyclopedia` — every available entry keyed by canonical id.
FutureOr<Map<String, Object?>> extEncyclopediaHandler(
  SleuthController controller,
  Map<String, String> args,
) {
  final entries = IssueExplanationBuilder.allExplanations;
  return envelopeOk(controller: controller, data: <String, Object?>{
    'count': entries.length,
    'entries': <String, Object?>{
      for (final entry in entries.entries)
        entry.key: _explanationToMap(entry.value),
    },
  });
}

/// `ext.sleuth.causalGraph` — rule set as `{trigger, effect}` maps.
FutureOr<Map<String, Object?>> extCausalGraphHandler(
  SleuthController controller,
  Map<String, String> args,
) {
  final rules = CausalGraphRule.rulesJson;
  return envelopeOk(controller: controller, data: <String, Object?>{
    'count': rules.length,
    'rules': rules,
  });
}

/// `ext.sleuth.diagnose` — operational health snapshot.
FutureOr<Map<String, Object?>> extDiagnoseHandler(
  SleuthController controller,
  Map<String, String> args,
) {
  return envelopeOk(controller: controller, data: <String, Object?>{
    'packageVersion': kSleuthPackageVersion,
    'initializedAtMicros': controller.initializedAt?.microsecondsSinceEpoch,
    'vmConnected': controller.isVmConnected,
    'captureMode': controller.config.captureMode,
    'lastCaptureExportFailure': controller.lastCaptureExportFailure,
    'unboundExtensionNames': ServiceExtensionRegistry.unboundNames,
  });
}

/// Treat empty string args as absent so an MCP client cannot drop
/// all results by sending `?route=`.
String? _nullIfEmpty(String? value) =>
    (value == null || value.isEmpty) ? null : value;

Map<String, Object?> _explanationToMap(IssueExplanation e) {
  return <String, Object?>{
    'displayName': e.displayName,
    'category': e.category.name,
    'whatItIs': e.whatItIs,
    'readingTheData': e.readingTheData,
    'whyItMatters': e.whyItMatters,
    'howToFix': e.howToFix,
    'whenToIgnore': e.whenToIgnore,
    'relatedIssues': e.relatedIssues,
  };
}
