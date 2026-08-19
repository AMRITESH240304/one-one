import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../logging/log_level.dart';
import '../logging/log_manager.dart';
import '../logging/user_facing_copy.dart';
import 'firebase_analytics_service.dart';

/// Canonical non-fatal nudge failure reasons shown in Crashlytics.
abstract final class NudgeFailureReason {
  static const permissionDeniedMicrophone = 'permission_denied_microphone';
  static const permissionDeniedFirebase = 'permission_denied_firebase';
  static const fcmNotDelivered = 'fcm_not_delivered';
  static const downloadFailed = 'download_failed';
  static const playbackFailed = 'playback_failed';
  static const volumeTooLow = 'volume_too_low';
  static const dndActive = 'dnd_active';
  static const livekitSessionFailed = 'livekit_session_failed';
  static const backgroundFgServiceBlocked = 'background_fg_service_blocked';
  static const unknown = 'unknown';

  static const Set<String> all = {
    permissionDeniedMicrophone,
    permissionDeniedFirebase,
    fcmNotDelivered,
    downloadFailed,
    playbackFailed,
    volumeTooLow,
    dndActive,
    livekitSessionFailed,
    backgroundFgServiceBlocked,
    unknown,
  };

  static String canonicalize(String? reason) {
    switch (reason) {
      case permissionDeniedMicrophone:
      case permissionDeniedFirebase:
      case fcmNotDelivered:
      case downloadFailed:
      case playbackFailed:
      case volumeTooLow:
      case dndActive:
      case livekitSessionFailed:
      case backgroundFgServiceBlocked:
        return reason!;
      case 'permission_denied_foreground_service':
        return backgroundFgServiceBlocked;
      case 'download_error':
        return downloadFailed;
      case 'playback_error':
      case 'playback_service_start_error':
      case 'timeout':
        return playbackFailed;
      case 'volume_low':
      case 'volume_very_low':
      case 'volume_muted':
        return volumeTooLow;
      default:
        return unknown;
    }
  }
}

String _deviceLogReason(String reason) {
  switch (reason) {
    case NudgeFailureReason.permissionDeniedMicrophone:
    case NudgeFailureReason.permissionDeniedFirebase:
    case NudgeFailureReason.backgroundFgServiceBlocked:
      return 'permission denied';
    case NudgeFailureReason.volumeTooLow:
      return 'volume too low';
    case NudgeFailureReason.dndActive:
      return 'DND active';
    case NudgeFailureReason.downloadFailed:
    case NudgeFailureReason.fcmNotDelivered:
      return 'network error';
    default:
      return 'unknown';
  }
}

/// Thin wrapper around [FirebaseCrashlytics] for app-wide crash reporting.
class CrashlyticsService {
  CrashlyticsService._();

  static final FirebaseCrashlytics _crashlytics = FirebaseCrashlytics.instance;
  static String _appVersion = '';
  static String _deviceModel = '';

  static Future<void> initialize() async {
    // Keep collection on in debug so local verification still uploads reports.
    await _crashlytics.setCrashlyticsCollectionEnabled(true);
    await _primeSessionKeys();
    debugPrint(
      '[Crashlytics] initialized collectionEnabled='
      '${_crashlytics.isCrashlyticsCollectionEnabled}',
    );
  }

  static Future<void> _primeSessionKeys() async {
    try {
      final package = await PackageInfo.fromPlatform();
      _appVersion = '${package.version}+${package.buildNumber}';
      _deviceModel = Platform.localHostname;
      await setCustomKeys({
        'app_version': _appVersion,
        'android_version': Platform.operatingSystemVersion,
        'device_model': _deviceModel,
      });
    } catch (error) {
      debugPrint('[Crashlytics] session key prime failed: $error');
    }
  }

  static Future<void> recordError(
    Object error,
    StackTrace? stack, {
    String? reason,
    bool fatal = false,
    String? feature,
    String? screenName,
    Iterable<Object> information = const [],
  }) async {
    debugPrint(
      '[Crashlytics] error recorded fatal=$fatal '
      'reason=${reason ?? '-'} error=$error',
    );
    LogManager.log(
      fatal ? LogLevel.fatal : LogLevel.error,
      'CrashlyticsService',
      'Caught ${fatal ? 'fatal' : 'non-fatal'} error reason=${reason ?? '-'} '
          'error=$error',
    );
    await _crashlytics.recordError(
      error,
      stack,
      reason: reason,
      fatal: fatal,
      information: information,
      printDetails: kDebugMode,
    );
    await AnalyticsService.logError(
      errorType: error.runtimeType.toString(),
      feature: feature,
      screenName: screenName,
      isFatal: fatal,
      reason: reason,
    );
  }

  /// Non-fatal FCM notification-handling failure.
  ///
  /// Filterable in Crashlytics by `reason=fcm_notification_handling_failure`.
  /// Worker / channel identifiers stay in this report — never in user-facing UI.
  static Future<void> recordFcmNotificationHandlingFailure({
    required Object error,
    StackTrace? stack,
    required String worker,
    String? groupId,
    String? eventId,
    String? kind,
    DateTime? timestamp,
    bool? inBackground,
  }) async {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final background =
        inBackground ??
        (lifecycle != null && lifecycle != AppLifecycleState.resumed);
    final information = FcmHandlingContext.information(
      worker: worker,
      groupId: groupId,
      eventId: eventId,
      kind: kind,
      timestamp: timestamp,
      inBackground: background,
    );
    await setCustomKeys({
      'reason': FcmHandlingContext.failureReason,
      'fcm_worker': worker,
      'fcm_kind': kind ?? '',
      'group_id': groupId ?? '',
      'nudge_event_id': eventId ?? '',
      'was_app_in_background': background,
    });
    await recordError(
      error,
      stack ?? StackTrace.current,
      reason: FcmHandlingContext.failureReason,
      fatal: false,
      feature: 'fcm',
      information: information,
    );
  }

  static Future<void> recordFatalError(
    Object error,
    StackTrace? stack, {
    String? reason,
    String? feature,
    String? screenName,
    Iterable<Object> information = const [],
  }) {
    return recordError(
      error,
      stack,
      reason: reason,
      fatal: true,
      feature: feature,
      screenName: screenName,
      information: information,
    );
  }

  static Future<void> recordFlutterFatalError(
    FlutterErrorDetails details,
  ) async {
    debugPrint(
      '[Crashlytics] Flutter fatal error recorded '
      'exception=${details.exceptionAsString()}',
    );
    LogManager.log(
      LogLevel.fatal,
      'CrashlyticsService',
      'Flutter fatal error: ${details.exceptionAsString()}',
    );
    await _crashlytics.recordFlutterFatalError(details);
    await AnalyticsService.logError(
      errorType: details.exception.runtimeType.toString(),
      feature: 'flutter_framework',
      isFatal: true,
      reason: details.exceptionAsString(),
    );
  }

  /// Non-fatal nudge failure with the required Crashlytics custom keys.
  static Future<void> recordNudgeFailure({
    required Object error,
    StackTrace? stack,
    required String failureReason,
    String? senderId,
    String? receiverId,
    String? groupId,
    String? livekitRoomState,
    String? eventId,
    Map<String, Object> extras = const {},
  }) async {
    // Copy before merge — callers may pass `const {}`. Plugin key writes
    // and map spreads are safe; in-place extras mutation is not.
    final reason = NudgeFailureReason.canonicalize(failureReason);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final inBackground =
        lifecycle != null && lifecycle != AppLifecycleState.resumed;
    String networkType = 'Unknown';
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.contains(ConnectivityResult.wifi)) {
        networkType = 'WiFi';
      } else if (results.contains(ConnectivityResult.mobile)) {
        networkType = 'Mobile';
      } else if (results.contains(ConnectivityResult.none) || results.isEmpty) {
        networkType = 'None';
      } else {
        networkType = results.first.name;
      }
    } catch (_) {}

    await setCustomKeys({
      'nudge_sender_id': senderId ?? '',
      'nudge_receiver_id': receiverId ?? '',
      'group_id': groupId ?? '',
      'failure_reason': reason,
      'network_type': networkType,
      'device_model': _deviceModel,
      'android_version': Platform.operatingSystemVersion,
      'app_version': _appVersion,
      'was_app_in_background': inBackground,
      'livekit_room_state': livekitRoomState ?? '',
      if (eventId != null) 'nudge_event_id': eventId,
      ...Map<String, Object>.of(extras),
    });
    await recordError(
      error,
      stack ?? StackTrace.current,
      reason: reason,
      fatal: false,
      feature: 'nudge',
    );
    LogManager.log(
      LogLevel.error,
      'NudgeService',
      'Nudge not delivered: ${_deviceLogReason(reason)} '
          '(failure_reason=$reason networkType=$networkType '
          'background=$inBackground eventId=${eventId ?? '-'})',
      userId: receiverId ?? senderId,
      groupId: groupId,
    );
  }

  /// Non-fatal bug report for the invalid "single user alone in a room" state.
  ///
  /// Captures the LiveKit-room context explaining how the user ended up alone
  /// (including how many participants were present at connect) and attaches a
  /// tail of the on-device logs so a "went south" state is diagnosable without
  /// reproducing it on-device.
  static Future<void> recordSoloParticipant({
    required String userId,
    String? groupId,
    required String roomName,
    required String livekitConnectionState,
    required int remoteParticipantCount,
    required int remoteCountAtConnect,
    required int remoteCountAtSoloStart,
    required int soloDurationSeconds,
    String entryReason = 'unknown',
    String? connectionMode,
  }) async {
    const reason = 'single_user_in_room';
    final deviceLogTail = _deviceLogTail(120);

    await setCustomKeys({
      'solo_user_id': userId,
      'group_id': groupId ?? '',
      'solo_room_name': roomName,
      'livekit_connection_state': livekitConnectionState,
      'solo_remote_count': remoteParticipantCount,
      'solo_remote_count_at_connect': remoteCountAtConnect,
      'solo_remote_count_at_solo_start': remoteCountAtSoloStart,
      'solo_duration_seconds': soloDurationSeconds,
      'solo_entry_reason': entryReason,
      'connection_mode': connectionMode ?? '',
    });

    final error = StateError(
      'Single-user-in-room: $userId was the sole connected participant in '
      'room "$roomName" for $soloDurationSeconds s '
      '(remoteCountAtConnect=$remoteCountAtConnect, '
      'remoteCountAtSoloStart=$remoteCountAtSoloStart, '
      'entryReason=$entryReason, mode=${connectionMode ?? 'unknown'}).',
    );

    await recordError(
      error,
      StackTrace.current,
      reason: reason,
      fatal: false,
      feature: 'presence',
      information: deviceLogTail,
    );

    LogManager.log(
      LogLevel.error,
      'SoloParticipantGuard',
      'Reported single-user-in-room as non-fatal bug '
          '(room=$roomName remoteCountAtConnect=$remoteCountAtConnect '
          'soloDurationSeconds=$soloDurationSeconds entryReason=$entryReason '
          'mode=${connectionMode ?? '-'})',
      userId: userId,
      groupId: groupId,
    );
  }

  /// Returns the most recent [maxLines] on-device log lines (oldest → newest),
  /// suitable for attaching to a non-fatal report.
  static List<String> _deviceLogTail(int maxLines) {
    final snapshot = LogManager.memorySnapshot();
    if (snapshot.length <= maxLines) return snapshot;
    return snapshot.sublist(snapshot.length - maxLines);
  }

  static Future<void> log(String message) async {
    debugPrint('[Crashlytics] log: $message');
    await _crashlytics.log(message);
  }

  static Future<void> setUserIdentifier(String? userId) async {
    final id = userId?.trim() ?? '';
    debugPrint(
      '[Crashlytics] setUserIdentifier=${id.isEmpty ? '(cleared)' : id}',
    );
    await _crashlytics.setUserIdentifier(id);
  }

  static Future<void> setCustomKey(String key, Object value) async {
    debugPrint('[Crashlytics] setCustomKey $key=$value');
    await _crashlytics.setCustomKey(key, value);
  }

  static Future<void> setCustomKeys(Map<String, Object> keys) async {
    for (final entry in keys.entries) {
      await setCustomKey(entry.key, entry.value);
    }
  }

  /// Forces a native Android crash. Dev/verification only.
  static void crash() {
    debugPrint('[Crashlytics] native crash triggered');
    _crashlytics.crash();
  }
}
