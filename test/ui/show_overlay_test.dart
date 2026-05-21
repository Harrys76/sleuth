import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';

void main() {
  test('showOverlay: defaults true, settable, threaded through copyWith', () {
    expect(const SleuthConfig().showOverlay, isTrue);
    const off = SleuthConfig(showOverlay: false);
    expect(off.showOverlay, isFalse);
    expect(off.copyWith().showOverlay, isFalse); // preserved
    expect(const SleuthConfig().copyWith(showOverlay: false).showOverlay,
        isFalse); // flipped
  });
}
