import 'package:one_one_app/one_one.dart';

class AndroidVoiceNudgeBridge {
  static const MethodChannel _channel = MethodChannel('app.oneone/voice_nudge');
  static final StreamController<void> _actionSignals =
      StreamController<void>.broadcast();
  static final StreamController<void> _registrationSignals =
      StreamController<void>.broadcast();
  static final StreamController<NudgeDeliveryResult> _deliveryResults =
      StreamController<NudgeDeliveryResult>.broadcast();
  static final StreamController<NudgeRecipientResponse> _recipientResponses =
      StreamController<NudgeRecipientResponse>.broadcast();
  static final StreamController<String> _receivedSignals =
      StreamController<String>.broadcast();
  static final StreamController<ActiveNudge> _incomingSignals =
      StreamController<ActiveNudge>.broadcast();
  static final StreamController<IncomingNudgeStatusUpdate>
  _incomingStatusSignals =
      StreamController<IncomingNudgeStatusUpdate>.broadcast();
  static bool _handlerInstalled = false;

  static Stream<void> get actionSignals {
    _installHandler();
    return _actionSignals.stream;
  }

  static Stream<void> get registrationSignals {
    _installHandler();
    return _registrationSignals.stream;
  }

  /// Full incoming-nudge payloads (FCM received while Flutter is alive).
  static Stream<ActiveNudge> get incomingSignals {
    _installHandler();
    return _incomingSignals.stream;
  }

  /// Native accept/decline/snooze that happened outside Flutter (notification
  /// actions) so the in-app prompt can drop that event immediately.
  static Stream<IncomingNudgeStatusUpdate> get incomingStatusSignals {
    _installHandler();
    return _incomingStatusSignals.stream;
  }

  /// Emits the `groupId` of a nudge the instant the native side receives it
  /// (FCM arrived / playback starting), before the user taps accept. Used to
  /// prefetch/warm LiveKit so accept is faster.
  static Stream<String> get receivedSignals {
    _installHandler();
    return _receivedSignals.stream;
  }

  /// Real-time played/failed outcomes for ring + voice nudges this device
  /// sent, pushed the instant the receiver's device genuinely starts (or
  /// fails to start) playback. Only fires while the app is foregrounded.
  static Stream<NudgeDeliveryResult> get deliveryResults {
    _installHandler();
    return _deliveryResults.stream;
  }

  /// Accept / decline / snooze replies for nudges this device sent.
  static Stream<NudgeRecipientResponse> get recipientResponses {
    _installHandler();
    return _recipientResponses.stream;
  }

  static void _installHandler() {
    if (_handlerInstalled || !Platform.isAndroid) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      try {
        await _handleNativeCall(call);
      } catch (error, stack) {
        debugPrint(
          '[OneOneFCM][DART-FCM-W2] Native FCM bridge handler failed '
          'method=${call.method} ${error.runtimeType}: $error',
        );
        final raw = call.arguments;
        final map = raw is Map
            ? raw.map((key, value) => MapEntry(key.toString(), value))
            : const <String, dynamic>{};
        unawaited(
          CrashlyticsService.recordFcmNotificationHandlingFailure(
            error: error,
            stack: stack,
            worker: 'DART-FCM-W2',
            groupId: map['groupId']?.toString(),
            eventId: map['eventId']?.toString() ?? map['nudgeId']?.toString(),
            kind: map['type']?.toString() ?? map['kind']?.toString(),
          ),
        );
      }
    });
  }

  static Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method == 'onNudgeActionAvailable') {
      _actionSignals.add(null);
    } else if (call.method == 'onFcmRegistrationRenewed') {
      debugPrint('[OneOneFCM][DART-06] Native registration renewed');
      _registrationSignals.add(null);
    } else if (call.method == 'onNudgeReceived') {
      final groupId = call.arguments?.toString().trim() ?? '';
      if (groupId.isNotEmpty) _receivedSignals.add(groupId);
    } else if (call.method == 'onIncomingNudge') {
      final raw = call.arguments;
      if (raw is Map) {
        final map = raw.map((key, value) => MapEntry(key.toString(), value));
        final nudge = parseIncomingNudge(map);
        if (nudge != null) {
          _incomingSignals.add(nudge);
        } else {
          debugPrint(
            '[OneOneFCM][DART-FCM-W1] Incoming nudge payload missing fields',
          );
          unawaited(
            CrashlyticsService.recordFcmNotificationHandlingFailure(
              error: StateError(
                'Incoming FCM nudge payload missing required fields',
              ),
              worker: 'DART-FCM-W1',
              groupId: map['groupId']?.toString(),
              eventId: map['eventId']?.toString() ?? map['nudgeId']?.toString(),
              kind: map['type']?.toString() ?? map['kind']?.toString(),
            ),
          );
        }
      }
    } else if (call.method == 'onIncomingNudgeStatus') {
      final raw = call.arguments;
      if (raw is Map) {
        final update = IncomingNudgeStatusUpdate.tryParse(
          raw.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (update != null) _incomingStatusSignals.add(update);
      }
    } else if (call.method == 'onNudgeDeliveryResult') {
      final raw = call.arguments;
      if (raw is Map) {
        final result = NudgeDeliveryResult.tryParse(
          raw.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (result != null) _deliveryResults.add(result);
      }
    } else if (call.method == 'onNudgeResponse') {
      final raw = call.arguments;
      if (raw is Map) {
        final response = NudgeRecipientResponse.tryParse(
          raw.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (response != null) _recipientResponses.add(response);
      }
    }
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

  /// Cached incoming nudges recorded by the native FCM receiver, including
  /// locally declined/accepted statuses from notification actions.
  Future<List<ActiveNudge>> listIncomingNudges() async {
    if (!Platform.isAndroid) return const [];
    _installHandler();
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'listIncomingNudges',
      );
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map(
            (item) => parseIncomingNudge(
              item.map((key, value) => MapEntry(key.toString(), value)),
            ),
          )
          .whereType<ActiveNudge>()
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> dismissIncomingNudge(String eventId) async {
    if (!Platform.isAndroid || eventId.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('dismissIncomingNudge', eventId);
    } catch (_) {
      // Local notification cancel is best-effort.
    }
  }

  /// Event IDs that share the same shade notification as [eventId].
  ///
  /// Rings batched within a 10-minute window return every member; voice and
  /// unpaired events return `[eventId]` alone.
  Future<List<String>> eventIdsSharingNotification(String eventId) async {
    if (!Platform.isAndroid || eventId.isEmpty) return [eventId];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'eventIdsSharingNotification',
        eventId,
      );
      final ids = raw
          ?.map((value) => value?.toString().trim() ?? '')
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      if (ids == null || ids.isEmpty) return [eventId];
      return ids;
    } catch (_) {
      return [eventId];
    }
  }

  /// Shows a "you are online" shade notification on the sender's device after
  /// a background auto-connect completes (the app never came to the foreground).
  Future<void> showYouAreOnlineNotification({
    required String groupId,
    String? groupName,
  }) async {
    if (!Platform.isAndroid || groupId.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('showYouAreOnlineNotification', {
        'groupId': groupId,
        if (groupName != null && groupName.isNotEmpty) 'groupName': groupName,
      });
    } catch (_) {
      // Best-effort — the sender is already live.
    }
  }

  /// B5: Schedule a 10-minute expiry alarm on the sender's device after a
  /// nudge is successfully dispatched. Cancelled on accept / decline / snooze
  /// (native FCM response and Flutter defense-in-depth). Delivery ("played")
  /// does not clear the accept window.
  Future<void> scheduleSenderNudgeExpiry({
    required String eventId,
    required String recipientName,
    required String recipientUserId,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('scheduleSenderNudgeExpiry', {
        'eventId': eventId,
        'recipientName': recipientName,
        'recipientUserId': recipientUserId,
      });
    } catch (_) {
      // Non-fatal — expiry is best-effort.
    }
  }

  Future<void> cancelSenderNudgeExpiry(String eventId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('cancelSenderNudgeExpiry', eventId);
    } catch (_) {
      // Non-fatal.
    }
  }

  Future<void> clearChatPile(String groupId) async {
    if (!Platform.isAndroid || groupId.isEmpty) return;
    try {
      await _channel.invokeMethod<void>('clearChatPile', groupId);
    } catch (_) {
      // Local notification cancel is best-effort.
    }
  }

  /// Group whose chat-pile notification the user just tapped, if any.
  Future<String?> takePendingChatPileOpen() async {
    if (!Platform.isAndroid) return null;
    _installHandler();
    try {
      final groupId = await _channel.invokeMethod<String>(
        'takePendingChatPileOpen',
      );
      final trimmed = groupId?.trim();
      return trimmed == null || trimmed.isEmpty ? null : trimmed;
    } catch (_) {
      return null;
    }
  }

  /// Local STREAM_MUSIC level as 0–100. Null on non-Android or if native
  /// read fails. Another device's volume cannot be read from here.
  Future<int?> getMediaVolumePercent() async {
    if (!Platform.isAndroid) return null;
    try {
      final raw = await _channel.invokeMethod<int>('getMediaVolumePercent');
      if (raw == null) return null;
      return raw.clamp(0, 100);
    } catch (_) {
      return null;
    }
  }

  /// Pushes the Settings haptic tier to native so incoming nudge playback
  /// (which can run with Flutter paused) uses the same pattern.
  static Future<void> setHapticsIntensity(HapticsIntensity intensity) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>(
        'setHapticsIntensity',
        intensity.storageKey,
      );
    } catch (_) {
      // Native sync is best-effort; Light remains the native default.
    }
  }

  /// Shared instance so multiple widgets can call platform methods without
  /// re-creating the channel handler.
  static final AndroidVoiceNudgeBridge shared = AndroidVoiceNudgeBridge();
}

class NudgeNotificationAction {
  const NudgeNotificationAction({
    required this.action,
    required this.eventId,
    required this.groupId,
    this.senderUserId,
  });

  /// `accept` and `connect` auto-join live (Case 1 / sender connect).
  /// `open` is a notification-body tap — show the in-app prompt (Case 2).
  final String action;
  final String eventId;
  final String groupId;
  final String? senderUserId;

  bool get isOpenOnly => action == 'open';
  bool get isAutoJoin => action == 'accept' || action == 'connect';

  static NudgeNotificationAction? tryParse(Map<String, dynamic> raw) {
    final action = raw['action']?.toString().trim() ?? '';
    final eventId = raw['eventId']?.toString().trim() ?? '';
    final groupId = raw['groupId']?.toString().trim() ?? '';
    if (!const {'accept', 'connect', 'open'}.contains(action) ||
        eventId.isEmpty ||
        groupId.isEmpty) {
      return null;
    }
    final senderUserId = raw['senderUserId']?.toString().trim();
    return NudgeNotificationAction(
      action: action,
      eventId: eventId,
      groupId: groupId,
      senderUserId: senderUserId == null || senderUserId.isEmpty
          ? null
          : senderUserId,
    );
  }
}

class IncomingNudgeStatusUpdate {
  const IncomingNudgeStatusUpdate({
    required this.nudgeId,
    required this.status,
    this.snoozedUntil,
  });

  final String nudgeId;
  final ActiveNudgeStatus status;
  final DateTime? snoozedUntil;

  static IncomingNudgeStatusUpdate? tryParse(Map<String, dynamic> raw) {
    final nudgeId =
        raw['eventId']?.toString().trim() ??
        raw['nudgeId']?.toString().trim() ??
        '';
    if (nudgeId.isEmpty) return null;
    final statusName = raw['status']?.toString().trim() ?? '';
    final status = ActiveNudgeStatus.values
        .where((value) => value.name == statusName)
        .firstOrNull;
    if (status == null) return null;
    final snoozedUntilMs = int.tryParse(
      raw['snoozedUntilMs']?.toString() ?? '',
    );
    return IncomingNudgeStatusUpdate(
      nudgeId: nudgeId,
      status: status,
      snoozedUntil: snoozedUntilMs == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(snoozedUntilMs),
    );
  }
}

ActiveNudge? parseIncomingNudge(Map<String, dynamic> raw) {
  final nudgeId =
      raw['eventId']?.toString().trim() ??
      raw['nudgeId']?.toString().trim() ??
      '';
  final groupId = raw['groupId']?.toString().trim() ?? '';
  final senderId =
      raw['senderUserId']?.toString().trim() ??
      raw['senderId']?.toString().trim() ??
      '';
  if (nudgeId.isEmpty || groupId.isEmpty) return null;
  final arrivedAtMs = int.tryParse(raw['arrivedAtMs']?.toString() ?? '');
  final sentAt = arrivedAtMs != null
      ? DateTime.fromMillisecondsSinceEpoch(arrivedAtMs)
      : DateTime.now();
  final statusName = raw['status']?.toString().trim();
  final status = ActiveNudgeStatus.values
      .where((value) => value.name == statusName)
      .firstOrNull;
  final snoozedUntilMs = int.tryParse(raw['snoozedUntilMs']?.toString() ?? '');
  final senderName = raw['senderName']?.toString().trim();
  return ActiveNudge(
    nudgeId: nudgeId,
    groupId: groupId,
    senderId: senderId,
    sentAt: sentAt,
    status: status ?? ActiveNudgeStatus.pending,
    senderName: senderName == null || senderName.isEmpty ? null : senderName,
    snoozedUntil: snoozedUntilMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(snoozedUntilMs),
  );
}

/// Sender-facing reply from a recipient (accept / decline / snooze).
class NudgeRecipientResponse {
  const NudgeRecipientResponse({
    required this.eventId,
    required this.groupId,
    required this.action,
    this.responderUserId,
    this.responderName,
    this.snoozeMinutes,
  });

  final String eventId;
  final String groupId;

  /// `accept`, `decline`, or `snooze`.
  final String action;
  final String? responderUserId;
  final String? responderName;
  final int? snoozeMinutes;

  bool get isDecline => action == 'decline';
  bool get isSnooze => action == 'snooze';
  bool get isAccept => action == 'accept';

  static NudgeRecipientResponse? tryParse(Map<String, dynamic> raw) {
    final eventId = raw['eventId']?.toString().trim() ?? '';
    final groupId = raw['groupId']?.toString().trim() ?? '';
    final action = raw['responseAction']?.toString().trim() ?? '';
    if (eventId.isEmpty ||
        groupId.isEmpty ||
        !const {'accept', 'decline', 'snooze'}.contains(action)) {
      return null;
    }
    final snoozeMinutes = int.tryParse(
      raw['snoozeMinutes']?.toString().trim() ?? '',
    );
    final responderUserId = raw['responderUserId']?.toString().trim();
    final responderName = raw['responderName']?.toString().trim();
    return NudgeRecipientResponse(
      eventId: eventId,
      groupId: groupId,
      action: action,
      responderUserId: responderUserId == null || responderUserId.isEmpty
          ? null
          : responderUserId,
      responderName: responderName == null || responderName.isEmpty
          ? null
          : responderName,
      snoozeMinutes: snoozeMinutes,
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
    this.attention,
    this.recipientName,
    this.recipientUserId,
  });

  final String eventId;

  /// `played` or `failed`. Reflects whether playback genuinely started, NOT
  /// whether the recipient could hear it.
  final String status;

  /// Machine-readable reason code when playback genuinely failed (e.g.
  /// `download_error`, `playback_error`, `timeout`).
  final String? reason;

  /// Audibility concern for an otherwise-successful playback
  /// (`volume_muted`, `volume_very_low`, or `volume_low`). This is a
  /// warning, never a failure.
  final String? attention;

  final String? recipientName;
  final String? recipientUserId;

  bool get played => status == 'played';

  /// True when the nudge played but the recipient probably didn't hear it
  /// (muted / very low volume).
  bool get playedButNotAudible => played && attention != null;

  /// Human-readable description of the audibility concern for UI display.
  String? get attentionLabel {
    return switch (attention) {
      'volume_muted' => 'their volume was muted',
      'volume_very_low' => 'their volume was very low',
      'volume_low' => 'their volume was too low',
      _ => null,
    };
  }

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
      attention: raw['attention']?.toString().trim().isEmpty ?? true
          ? null
          : raw['attention'].toString().trim(),
      recipientName: raw['recipientName']?.toString().trim().isEmpty ?? true
          ? null
          : raw['recipientName'].toString().trim(),
      recipientUserId: raw['recipientUserId']?.toString().trim().isEmpty ?? true
          ? null
          : raw['recipientUserId'].toString().trim(),
    );
  }
}

/// Shared delivery-failure reason normalization.
abstract final class NudgeDeliveryFailure {
  static String? canonicalReason(String? reason) {
    if (reason == null || reason.trim().isEmpty) return null;
    switch (reason.trim()) {
      case 'permission_denied_foreground_service':
        return 'background_fg_service_blocked';
      case 'download_error':
        return 'download_failed';
      case 'playback_service_start_error':
        return 'playback_error';
      default:
        return reason.trim();
    }
  }
}

String _suffix(String value) =>
    value.length <= 6 ? value : value.substring(value.length - 6);
