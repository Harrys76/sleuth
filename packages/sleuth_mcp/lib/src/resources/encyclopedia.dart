import 'dart:async';

import '../bridge/vm_bridge.dart';

/// Cached `ext.sleuth.encyclopedia` resource. Cache key = sessionUuid.
/// The generation counter guards against concurrent `read()` ↔
/// `invalidate()` interleaving: a read's post-await write only lands if
/// the generation captured before the await is still current.
class EncyclopediaResource {
  EncyclopediaResource({required this.bridge});

  final VmBridge bridge;
  String? _cachedSessionUuid;
  Map<String, Object?>? _cached;
  int _generation = 0;

  Future<Map<String, Object?>> read() async {
    final gen = _generation;
    final currentUuid = bridge.baselineSessionUuid;
    final cached = _cached;
    if (cached != null && _cachedSessionUuid == currentUuid) {
      return cached;
    }
    final envelope = await bridge.callExtension('ext.sleuth.encyclopedia');
    if (gen == _generation) {
      _cached = envelope;
      _cachedSessionUuid = currentUuid;
    }
    return envelope;
  }

  /// Drop any cached payload. Next [read] re-fetches.
  void invalidate() {
    _generation++;
    _cached = null;
    _cachedSessionUuid = null;
  }
}
