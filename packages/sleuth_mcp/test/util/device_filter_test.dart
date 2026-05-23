import 'package:sleuth_mcp/src/util/device_filter.dart';
import 'package:test/test.dart';

void main() {
  group('isMobileFlutterDevice', () {
    test('category=desktop → false', () {
      expect(
        isMobileFlutterDevice({'category': 'desktop'}),
        isFalse,
      );
    });

    test('no category, targetPlatform=ios → true (Flutter 3.41.4 shape)', () {
      // Flutter 3.41.4 `flutter devices --machine` omits `category`; the
      // targetPlatform fallback keeps the mobile filter from dropping every device.
      expect(
        isMobileFlutterDevice({
          'name': 'iPhone 12',
          'id': '00008101-XYZ',
          'targetPlatform': 'ios',
        }),
        isTrue,
      );
    });

    test('no category, targetPlatform=android-arm64 → true', () {
      expect(
        isMobileFlutterDevice({'targetPlatform': 'android-arm64'}),
        isTrue,
      );
    });

    test('no category, targetPlatform=web-javascript → false', () {
      expect(
        isMobileFlutterDevice({'targetPlatform': 'web-javascript'}),
        isFalse,
      );
    });

    test('empty map → false', () {
      expect(isMobileFlutterDevice(const <String, Object?>{}), isFalse);
    });

    test('category=mobile takes precedence over targetPlatform=web', () {
      expect(
        isMobileFlutterDevice({
          'category': 'mobile',
          'targetPlatform': 'web-javascript',
        }),
        isTrue,
      );
    });
  });
}
