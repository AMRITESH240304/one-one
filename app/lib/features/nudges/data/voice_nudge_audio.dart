import 'package:record/record.dart';

/// Speech-tuned AAC-LC in an M4A container.
///
/// Voice nudges are already lossy-compressed; wrapping them in another
/// compressor would add encode/decode time without shrinking the payload.
/// These settings stay in the same `audio/mp4` container so older and newer
/// clients can play each other's files, while cutting the bitrate in half
/// versus the previous 64 kbps / 44.1 kHz capture.
class VoiceNudgeAudio {
  static const AudioEncoder encoder = AudioEncoder.aacLc;
  static const int bitRate = 32000;
  static const int sampleRate = 16000;
  static const int numChannels = 1;
  static const String contentType = 'audio/mp4';
  static const String fileExtension = 'm4a';

  /// Typical MPEG-4 box overhead for a short AAC clip.
  static const int containerOverheadBytes = 2048;

  /// Previous capture: AAC-LC 64 kbps / 44.1 kHz / mono.
  static const int legacyBitRate = 64000;

  static RecordConfig get recordConfig => const RecordConfig(
    encoder: encoder,
    bitRate: bitRate,
    sampleRate: sampleRate,
    numChannels: numChannels,
    autoGain: true,
    echoCancel: true,
    noiseSuppress: true,
  );

  /// CBR AAC payload plus container overhead. Real files land near this.
  static int expectedPayloadBytes(int durationMs) {
    final clampedMs = durationMs < 0 ? 0 : durationMs;
    final audioBytes = (bitRate / 8) * (clampedMs / 1000);
    return (audioBytes + containerOverheadBytes).round();
  }

  static int legacyPayloadBytes(int durationMs) {
    final clampedMs = durationMs < 0 ? 0 : durationMs;
    final audioBytes = (legacyBitRate / 8) * (clampedMs / 1000);
    return (audioBytes + containerOverheadBytes).round();
  }
}
