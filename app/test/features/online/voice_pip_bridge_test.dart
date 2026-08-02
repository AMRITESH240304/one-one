import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/features/online/voice_pip_bridge.dart';

void main() {
  test('maps supported PiP actions and ignores unknown actions', () {
    expect(
      parseVoicePipAction('toggle_microphone'),
      VoicePipAction.toggleMicrophone,
    );
    expect(parseVoicePipAction('mute'), isNull);
    expect(parseVoicePipAction('unknown'), isNull);
  });
}
