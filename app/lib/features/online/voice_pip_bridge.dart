import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

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

  Stream<VoicePipAction> get actions => _actions.stream;

  Future<void> setSessionState({
    required bool active,
    required bool isTalking,
  }) async {
    try {
      await _channel.invokeMethod<void>('setSessionState', {
        'active': active,
        'isTalking': isTalking,
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
    }
  }

  Future<void> dispose() async {
    _channel.setMethodCallHandler(null);
    isInPictureInPicture.dispose();
    await _actions.close();
  }
}
