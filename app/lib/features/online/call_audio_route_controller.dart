import 'audio_output_bridge.dart';

/// Explicit user-driven output mode for a live session.
///
/// Independent of who is speaking/listening. External headphones still
/// override speaker/earpiece for actual routing, but this enum is the only
/// thing taps and long-presses mutate.
enum CallAudioUserMode { speaker, earpiece, muted }

/// Deterministic audio-output state machine for live LiveKit sessions (E1).
///
/// Rules:
/// - On connect → [CallAudioUserMode.speaker]
/// - Tap while speaker → earpiece
/// - Tap while earpiece → speaker
/// - Long-press while not muted → muted
/// - Tap while muted → speaker
/// - Headset/Bluetooth (when connected) override speaker/earpiece for display
///   and device routing; they do not clear the underlying user mode.
class CallAudioRouteController {
  CallAudioUserMode _userMode = CallAudioUserMode.speaker;
  AudioOutputRoute _deviceRoute = AudioOutputRoute.speaker;
  bool _sessionActive = false;

  CallAudioUserMode get userMode => _userMode;

  /// Last observed platform route (may be headset/bluetooth).
  AudioOutputRoute get deviceRoute => _deviceRoute;

  bool get sessionActive => _sessionActive;

  bool get muted => _userMode == CallAudioUserMode.muted;

  bool get headphonesConnected =>
      _deviceRoute == AudioOutputRoute.headset ||
      _deviceRoute == AudioOutputRoute.bluetooth;

  /// Route shown in the call-bar glyph (headphones win when plugged in).
  AudioOutputRoute get displayRoute {
    if (headphonesConnected) return _deviceRoute;
    return switch (_userMode) {
      CallAudioUserMode.earpiece => AudioOutputRoute.earpiece,
      CallAudioUserMode.speaker ||
      CallAudioUserMode.muted => AudioOutputRoute.speaker,
    };
  }

  AudioOutputGlyphKind get glyphKind => resolveAudioOutputGlyph(
    route: displayRoute,
    muted: muted,
  );

  /// LiveKit `setSpeakerOn` argument for the current non-muted preference.
  bool get speakerOn => _userMode != CallAudioUserMode.earpiece;

  /// Persisted settings value (`speaker` / `earpiece`) for the non-muted mode.
  String get preferenceName =>
      _userMode == CallAudioUserMode.earpiece ? 'earpiece' : 'speaker';

  /// Proximity blanking only in earpiece mode without headphones (E2).
  bool get proximityEnabled =>
      _sessionActive &&
      _userMode == CallAudioUserMode.earpiece &&
      !headphonesConnected;

  /// Call when a LiveKit room connect completes. Always starts on speaker,
  /// unmuted — never inherits a stale mute or earpiece preference (E1/E3).
  void onSessionConnected() {
    _sessionActive = true;
    _userMode = CallAudioUserMode.speaker;
  }

  void onSessionEnded() {
    _sessionActive = false;
    _userMode = CallAudioUserMode.speaker;
  }

  /// Platform reported a route change (headphones plug/unplug, etc.).
  /// Never changes [userMode] — only the observed device route.
  void onDeviceRouteChanged(AudioOutputRoute route) {
    _deviceRoute = route;
  }

  /// Single tap: speaker↔earpiece, or muted→speaker.
  CallAudioUserMode onTap() {
    if (_userMode == CallAudioUserMode.muted) {
      _userMode = CallAudioUserMode.speaker;
      return _userMode;
    }
    _userMode = _userMode == CallAudioUserMode.speaker
        ? CallAudioUserMode.earpiece
        : CallAudioUserMode.speaker;
    return _userMode;
  }

  /// Long-press: enter mute. If already muted, return to speaker.
  CallAudioUserMode onLongPress() {
    if (_userMode == CallAudioUserMode.muted) {
      _userMode = CallAudioUserMode.speaker;
    } else {
      _userMode = CallAudioUserMode.muted;
    }
    return _userMode;
  }

  /// Settings screen changed speaker/earpiece while a session may be live.
  /// Ignored when muted — mute stays until an explicit tap/long-press.
  void applySettingsPreference(String preference) {
    if (_userMode == CallAudioUserMode.muted) return;
    _userMode = preference == 'earpiece'
        ? CallAudioUserMode.earpiece
        : CallAudioUserMode.speaker;
  }

  /// Restores an explicit mode after a failed platform write.
  void restoreMode(CallAudioUserMode mode) {
    _userMode = mode;
  }
}
