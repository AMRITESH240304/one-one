import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/features/online/voice_overlay_bridge.dart';

void main() {
  test('call-mode timeout announcement matches the spoken overlay copy', () {
    expect(
      VoiceOverlayBridge.callModeTimeoutAnnouncement,
      "Switching back to walkie-talkie mode. It's been fifteen minutes.",
    );
  });
}
