import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';

/// Native method channel for the current audio output route and media mute.
class AudioOutputContract {
  static const String flutterChannel = 'app.oneone/audio_output';
  static const String methodGetState = 'getState';
  static const String methodSetMuted = 'setMuted';
  static const String methodOnStateChanged = 'onStateChanged';
}

enum AudioOutputRoute { speaker, earpiece, headset, bluetooth }

enum AudioOutputGlyphKind { speaker, earpiece, headset, muted }

class AudioOutputState {
  const AudioOutputState({required this.route, required this.muted});

  final AudioOutputRoute route;
  final bool muted;

  factory AudioOutputState.fromMap(Map<Object?, Object?>? raw) {
    final routeName = raw?['route']?.toString();
    return AudioOutputState(
      route: parseAudioOutputRoute(routeName),
      muted: raw?['muted'] == true,
    );
  }

  Map<String, Object> toMap() => {'route': route.name, 'muted': muted};

  @override
  bool operator ==(Object other) {
    return other is AudioOutputState &&
        other.route == route &&
        other.muted == muted;
  }

  @override
  int get hashCode => Object.hash(route, muted);
}

AudioOutputRoute parseAudioOutputRoute(String? value) {
  return switch (value) {
    'earpiece' => AudioOutputRoute.earpiece,
    'headset' => AudioOutputRoute.headset,
    'bluetooth' => AudioOutputRoute.bluetooth,
    _ => AudioOutputRoute.speaker,
  };
}

/// Single call-bar glyph: Volume2 when speaker, outline speaker when earpiece,
/// headphones when an external device is active, VolumeX when muted.
AudioOutputGlyphKind resolveAudioOutputGlyph({
  required AudioOutputRoute route,
  required bool muted,
}) {
  if (muted) return AudioOutputGlyphKind.muted;
  return switch (route) {
    AudioOutputRoute.speaker => AudioOutputGlyphKind.speaker,
    AudioOutputRoute.earpiece => AudioOutputGlyphKind.earpiece,
    AudioOutputRoute.headset ||
    AudioOutputRoute.bluetooth => AudioOutputGlyphKind.headset,
  };
}

String audioOutputTooltip({
  required AudioOutputGlyphKind kind,
  required bool speakerPreferenceOn,
}) {
  return switch (kind) {
    AudioOutputGlyphKind.muted => 'Muted — hold to unmute',
    AudioOutputGlyphKind.headset =>
      speakerPreferenceOn
          ? 'Headphones — tap to prefer speaker after unplug, hold to mute'
          : 'Headphones — tap to prefer phone after unplug, hold to mute',
    AudioOutputGlyphKind.speaker =>
      'Speaker — tap to switch to phone, hold to mute',
    AudioOutputGlyphKind.earpiece =>
      'Phone — tap to switch to speaker, hold to mute',
  };
}

/// Reads/writes the platform audio route + media mute, and applies the same
/// mute to LiveKit remote playback so a call actually goes silent.
class AudioOutputBridge {
  AudioOutputBridge._();

  static const MethodChannel _channel = MethodChannel(
    AudioOutputContract.flutterChannel,
  );

  static final StreamController<AudioOutputState> _changes =
      StreamController<AudioOutputState>.broadcast();

  static bool _handlerInstalled = false;

  static Stream<AudioOutputState> get changes {
    _ensureHandler();
    return _changes.stream;
  }

  static void _ensureHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != AudioOutputContract.methodOnStateChanged) return;
      final args = call.arguments;
      if (args is Map) {
        _changes.add(
          AudioOutputState.fromMap(Map<Object?, Object?>.from(args)),
        );
      }
    });
  }

  static Future<AudioOutputState?> getState() async {
    _ensureHandler();
    try {
      final raw = await _channel.invokeMethod<dynamic>(
        AudioOutputContract.methodGetState,
      );
      if (raw is Map) {
        return AudioOutputState.fromMap(Map<Object?, Object?>.from(raw));
      }
    } on MissingPluginException {
      // iOS simulator / older builds without the native plugin.
    } catch (error, stack) {
      debugPrint('AudioOutput getState failed: $error\n$stack');
    }
    return null;
  }

  static Future<AudioOutputState?> setMuted(bool muted) async {
    _ensureHandler();
    try {
      final raw = await _channel.invokeMethod<dynamic>(
        AudioOutputContract.methodSetMuted,
        muted,
      );
      if (raw is Map) {
        return AudioOutputState.fromMap(Map<Object?, Object?>.from(raw));
      }
    } on MissingPluginException {
      // Native mute is best-effort; LiveKit track mute still applies.
    } catch (error, stack) {
      debugPrint('AudioOutput setMuted failed: $error\n$stack');
    }
    return null;
  }

  /// Silence (or restore) remote LiveKit audio independently of the speaker
  /// route. Used with native media mute so long-press actually mutes a call.
  static Future<void> applyRemotePlaybackMute(Room? room, bool muted) async {
    if (room == null) return;
    for (final participant in room.remoteParticipants.values) {
      for (final publication in participant.audioTrackPublications) {
        final track = publication.track;
        if (track == null) continue;
        try {
          if (muted) {
            await track.disable();
          } else {
            await track.enable();
          }
        } catch (_) {
          // Some devices reject per-track mute; native mute still applies.
        }
      }
    }
  }
}
