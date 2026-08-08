import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/firebase/crashlytics_service.dart';

class AndroidVoiceNudgeBridge {
  static const MethodChannel _channel = MethodChannel('app.oneone/voice_nudge');
  static final StreamController<void> _actionSignals =
      StreamController<void>.broadcast();
  static final StreamController<void> _registrationSignals =
      StreamController<void>.broadcast();
  static final StreamController<NudgeDeliveryResult> _deliveryResults =
      StreamController<NudgeDeliveryResult>.broadcast();
  static bool _handlerInstalled = false;

  static Stream<void> get actionSignals {
    _installHandler();
    return _actionSignals.stream;
  }

  static Stream<void> get registrationSignals {
    _installHandler();
    return _registrationSignals.stream;
  }

  /// Real-time played/failed outcomes for ring + voice nudges this device
  /// sent, pushed the instant the receiver's device genuinely starts (or
  /// fails to start) playback. Only fires while the app is foregrounded.
  static Stream<NudgeDeliveryResult> get deliveryResults {
    _installHandler();
    return _deliveryResults.stream;
  }

  static void _installHandler() {
    if (_handlerInstalled || !Platform.isAndroid) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNudgeActionAvailable') {
        _actionSignals.add(null);
      } else if (call.method == 'onFcmRegistrationRenewed') {
        debugPrint('[OneOneFCM][DART-06] Native registration renewed');
        _registrationSignals.add(null);
      } else if (call.method == 'onNudgeDeliveryResult') {
        final raw = call.arguments;
        if (raw is Map) {
          final result = NudgeDeliveryResult.tryParse(
            raw.map((key, value) => MapEntry(key.toString(), value)),
          );
          if (result != null) _deliveryResults.add(result);
        }
      }
    });
  }

  Future<String?> getFcmToken() async {
    if (!Platform.isAndroid) return null;
    debugPrint('[OneOneFCM][DART-01] Requesting Android FCM registration');
    try {
      final token = await _channel.invokeMethod<String>('getFcmToken');
      final cleanToken = token?.trim();
      if (cleanToken == null || cleanToken.isEmpty) {
        debugPrint(
          '[OneOneFCM][DART-E1] Native registration returned no identifier',
        );
        return null;
      }
      debugPrint(
        '[OneOneFCM][DART-02] Registration identifier received '
        'length=${cleanToken.length} suffix=${_suffix(cleanToken)}',
      );
      return cleanToken;
    } on PlatformException catch (error, stack) {
      debugPrint(
        '[OneOneFCM][DART-E2] Native registration failed '
        'code=${error.code} message=${error.message}',
      );
      await CrashlyticsService.recordError(
        error,
        stack,
        reason: 'fcm_native_registration_failed',
      );
      rethrow;
    } catch (error, stack) {
      debugPrint(
        '[OneOneFCM][DART-E3] Registration bridge failed '
        '${error.runtimeType}: $error',
      );
      await CrashlyticsService.recordError(
        error,
        stack,
        reason: 'fcm_registration_bridge_failed',
      );
      rethrow;
    }
  }

  Future<NudgeNotificationAction?> takePendingNudgeAction() async {
    if (!Platform.isAndroid) return null;
    _installHandler();
    final raw = await _channel.invokeMapMethod<String, dynamic>(
      'takePendingNudgeAction',
    );
    if (raw == null) return null;
    return NudgeNotificationAction.tryParse(raw);
  }
}

class NudgeNotificationAction {
  const NudgeNotificationAction({
    required this.action,
    required this.eventId,
    required this.groupId,
  });

  final String action;
  final String eventId;
  final String groupId;

  static NudgeNotificationAction? tryParse(Map<String, dynamic> raw) {
    final action = raw['action']?.toString().trim() ?? '';
    final eventId = raw['eventId']?.toString().trim() ?? '';
    final groupId = raw['groupId']?.toString().trim() ?? '';
    if (!const {'accept', 'connect'}.contains(action) ||
        eventId.isEmpty ||
        groupId.isEmpty) {
      return null;
    }
    return NudgeNotificationAction(
      action: action,
      eventId: eventId,
      groupId: groupId,
    );
  }
}

/// Outcome of a ring/voice nudge this device sent, reported once the
/// receiver's device genuinely started (or failed to start) playback.
class NudgeDeliveryResult {
  const NudgeDeliveryResult({
    required this.eventId,
    required this.status,
    this.reason,
    this.recipientName,
  });

  final String eventId;

  /// `played` or `failed`.
  final String status;

  /// Machine-readable reason code (e.g. `receiver_volume_muted`) when known.
  final String? reason;
  final String? recipientName;

  bool get played => status == 'played';

  static NudgeDeliveryResult? tryParse(Map<String, dynamic> raw) {
    final eventId = raw['eventId']?.toString().trim() ?? '';
    final status = raw['status']?.toString().trim() ?? '';
    if (eventId.isEmpty || !const {'played', 'failed'}.contains(status)) {
      return null;
    }
    return NudgeDeliveryResult(
      eventId: eventId,
      status: status,
      reason: raw['reason']?.toString().trim().isEmpty ?? true
          ? null
          : raw['reason'].toString().trim(),
      recipientName: raw['recipientName']?.toString().trim().isEmpty ?? true
          ? null
          : raw['recipientName'].toString().trim(),
    );
  }
}

String _suffix(String value) =>
    value.length <= 6 ? value : value.substring(value.length - 6);
