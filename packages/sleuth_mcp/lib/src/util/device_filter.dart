/// Mobile = `category == 'mobile'` (newer flutter SDKs) OR
/// `targetPlatform` starts with `ios` / `android` (Flutter 3.41.4 and
/// earlier — no `category` field).
///
/// Both `list_devices` and `attach_app`'s device-probe use this so the
/// scope (Android + iOS only) is enforced consistently.
bool isMobileFlutterDevice(Map<String, Object?> d) {
  final category = d['category'];
  if (category is String) return category == 'mobile';
  final target = d['targetPlatform'];
  if (target is String) {
    return target.startsWith('ios') || target.startsWith('android');
  }
  return false;
}
