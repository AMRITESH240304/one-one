import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models/online_session.dart';

enum VoicePipAction { toggleMicrophone }

VoicePipAction? parseVoicePipAction(String? value) {
  return switch (value) {
    'toggle_microphone' => VoicePipAction.toggleMicrophone,
    _ => null,
  };
}

class VoicePipBridge {
  VoicePipBridge() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const MethodChannel _channel = MethodChannel('app.oneone/voice_pip');

  final ValueNotifier<bool> isInPictureInPicture = ValueNotifier(false);
  final StreamController<VoicePipAction> _actions =
      StreamController<VoicePipAction>.broadcast();
  final StreamController<void> _processTeardown =
      StreamController<void>.broadcast();

  Stream<VoicePipAction> get actions => _actions.stream;

  /// Fired when Android is about to kill the task or voice foreground service.
  Stream<void> get processTeardown => _processTeardown.stream;

  Future<void> setSessionState({
    required bool active,
    required bool isTalking,
    OnlineSession? session,
  }) async {
    try {
      await _channel.invokeMethod<void>('setSessionState', {
        'active': active,
        'isTalking': isTalking,
        if (session != null) ...session.toPresenceHandle(),
      });
    } on MissingPluginException {
      // PiP is Android-only.
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onPipModeChanged':
        isInPictureInPicture.value = call.arguments == true;
        return;
      case 'onPipAction':
        final action = parseVoicePipAction(call.arguments as String?);
        if (action != null) _actions.add(action);
        return;
      case 'onProcessTeardown':
        if (!_processTeardown.isClosed) _processTeardown.add(null);
        return;
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    isInPictureInPicture.dispose();
    await _actions.close();
    await _processTeardown.close();
  }
}
