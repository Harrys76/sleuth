import 'dart:convert';
import 'dart:io';

/// One GC event of a recorded dump (`tool/device_pass.dart gc-dump`).
typedef RecordedGc = ({
  String? gcType,
  String? reason,
  double cumulativePauseSeconds,
  DateTime at,
});

/// The app isolate's GC events of a recorded dump, in timestamp order.
/// The pause is the VM's cumulative `new.time + old.time`.
List<RecordedGc> loadGcEvents(String path) {
  final json =
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  final appIsolateId =
      (json['provenance'] as Map<String, dynamic>)['appIsolateId'] as String?;
  double time(Object? space) =>
      space is Map ? ((space['time'] as num?) ?? 0).toDouble() : 0;
  final events = <RecordedGc>[
    for (final e in (json['events'] as List).cast<Map<String, dynamic>>())
      if (appIsolateId == null ||
          (e['isolate'] as Map<String, dynamic>?)?['id'] == appIsolateId)
        (
          gcType: e['gcType'] as String?,
          reason: e['reason'] as String?,
          cumulativePauseSeconds: time(e['new']) + time(e['old']),
          at: DateTime.fromMillisecondsSinceEpoch(e['timestamp'] as int),
        ),
  ]..sort((a, b) => a.at.compareTo(b.at));
  return events;
}
