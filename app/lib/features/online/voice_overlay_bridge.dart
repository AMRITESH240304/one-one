import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android TTS overlay for in-session mode announcements.
///
/// Playback uses the current media volume and is skipped when media is muted.
/// Non-Android platforms no-op. Callers should fire-and-forget so the
/// walkie-talkie switch is not delayed by speech.
class VoiceOverlayBridge {
  VoiceOverlayBridge._();

  static const MethodChannel _channel = MethodChannel(
    'app.oneone/voice_overlay',
  );

  static const String callModeTimeoutAnnouncement =
      "Switching back to walkie-talkie mode. It's been fifteen minutes.";

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Pre-loads the Android TTS engine so the timeout announcement can start
  /// immediately when the call-mode cap fires.
  static Future<void> warmup() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('warmup');
    } on MissingPluginException {
      // Native overlay is Android-only.
    } catch (error, stack) {
      debugPrint('VoiceOverlay warmup failed: $error\n$stack');
    }
  }

  /// Speaks [callModeTimeoutAnnouncement] if media volume is not muted.
  /// Does not wait for speech to finish.
  static Future<void> announceCallModeTimeout() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('announceCallModeTimeout');
    } on MissingPluginException {
      // Native overlay is Android-only.
    } catch (error, stack) {
      debugPrint('VoiceOverlay announce failed: $error\n$stack');
    }
  }
}
