import 'package:one_one_app/one_one.dart';

/// Short start/stop tones and haptics for push-to-talk.
class TalkFeedback {
  TalkFeedback._();

  static final AudioPlayer _player = AudioPlayer();
  static bool _configured = false;

  static Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _player.setReleaseMode(ReleaseMode.stop);
    await _player.setPlayerMode(PlayerMode.lowLatency);
    _configured = true;
  }

  static Future<void> talkStarted({required bool hapticsEnabled}) async {
    if (hapticsEnabled) {
      await _hapticStart();
    }
    await _playAsset('sounds/talk_start.wav');
  }

  static Future<void> talkStopped({required bool hapticsEnabled}) async {
    if (hapticsEnabled) {
      await _hapticStop();
    }
    await _playAsset('sounds/talk_stop.wav');
  }

  /// Short confirmation after the local participant successfully joins.
  static Future<void> joined() => _playAsset('sounds/talk_start.wav');

  /// A remote participant began speaking while this device is transmitting.
  /// The haptic setting is supplied at event time so mid-call toggles apply.
  static Future<void> remoteSpeakerStarted({
    required bool hapticsEnabled,
  }) async {
    await Future.wait<void>([
      _playAsset('sounds/talk_start.wav'),
      if (hapticsEnabled) HapticFeedback.lightImpact(),
    ]);
  }

  static Future<void> _hapticStart() async {
    await HapticFeedback.lightImpact();
  }

  static Future<void> _hapticStop() async {
    await HapticFeedback.selectionClick();
  }

  static Future<void> _playAsset(String assetPath) async {
    try {
      await _ensureConfigured();
      await _player.stop();
      await _player.play(AssetSource(assetPath));
    } catch (error, stack) {
      debugPrint('TalkFeedback play failed: $error\n$stack');
    }
  }
}
