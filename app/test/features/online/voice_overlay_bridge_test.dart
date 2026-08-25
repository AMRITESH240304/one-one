import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  test('call-mode timeout announcement matches the spoken overlay copy', () {
    expect(
      VoiceOverlayBridge.callModeTimeoutAnnouncement,
      "Switching back to walkie-talkie mode. It's been fifteen minutes.",
    );
  });
}
