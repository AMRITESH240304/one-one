import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  test('voice nudges stay on hardware AAC-LC in an M4A container', () {
    expect(VoiceNudgeAudio.encoder, AudioEncoder.aacLc);
    expect(VoiceNudgeAudio.numChannels, 1);
    expect(VoiceNudgeAudio.contentType, 'audio/mp4');
    expect(VoiceNudgeAudio.fileExtension, 'm4a');
    expect(VoiceNudgeAudio.recordConfig.encoder, AudioEncoder.aacLc);
    expect(VoiceNudgeAudio.recordConfig.bitRate, VoiceNudgeAudio.bitRate);
    expect(VoiceNudgeAudio.recordConfig.sampleRate, VoiceNudgeAudio.sampleRate);
  });

  test('speech-tuned AAC is about half the previous 64 kbps payload', () {
    const shortMs = 1500;
    final longMs = VoiceNudgeAudio.maxRecordingDuration.inMilliseconds;

    expect(VoiceNudgeAudio.maxRecordingDuration, const Duration(seconds: 5));
    expect(VoiceNudgeAudio.maxAcceptedDurationMs, 6000);
    expect(VoiceNudgeAudio.expectedPayloadBytes(shortMs), 8048);
    expect(VoiceNudgeAudio.legacyPayloadBytes(shortMs), 14048);
    expect(VoiceNudgeAudio.expectedPayloadBytes(longMs), 22048);
    expect(VoiceNudgeAudio.legacyPayloadBytes(longMs), 42048);

    final shortReduction =
        1 -
        VoiceNudgeAudio.expectedPayloadBytes(shortMs) /
            VoiceNudgeAudio.legacyPayloadBytes(shortMs);
    final longReduction =
        1 -
        VoiceNudgeAudio.expectedPayloadBytes(longMs) /
            VoiceNudgeAudio.legacyPayloadBytes(longMs);
    expect(shortReduction, greaterThan(0.40));
    expect(longReduction, closeTo(0.48, 0.02));
    expect(VoiceNudgeAudio.expectedPayloadBytes(longMs), lessThan(96 * 1024));
  });
}
