import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

/// Production Analytics wrapper for One One.
///
/// Event names follow Firebase conventions (snake_case, ≤40 chars).
class AnalyticsService {
  AnalyticsService._();

  static final FirebaseAnalytics _analytics = FirebaseAnalytics.instance;

  static FirebaseAnalyticsObserver get observer =>
      FirebaseAnalyticsObserver(analytics: _analytics);

  static Future<void> initialize() async {
    await _analytics.setAnalyticsCollectionEnabled(true);
    await logAppOpen();
    _debug('initialized collectionEnabled=true');
  }

  // ─── Core ───────────────────────────────────────────────────────────────

  static Future<void> logCustomEvent(
    String name, {
    Map<String, Object>? parameters,
  }) {
    return _log(name, parameters: parameters);
  }

  static Future<void> logScreenView({
    required String screenName,
    String? screenClass,
  }) {
    return _log(
      'screen_view',
      parameters: {
        'screen_name': screenName,
        if (screenClass != null) 'screen_class': screenClass,
      },
    );
  }

  static Future<void> logButtonClick({
    required String buttonName,
    String? screenName,
    String? feature,
  }) {
    return _log(
      'button_click',
      parameters: {
        'button_name': buttonName,
        if (screenName != null) 'screen_name': screenName,
        if (feature != null) 'feature': feature,
      },
    );
  }

  static Future<void> logFeatureUsed({
    required String feature,
    Map<String, Object>? parameters,
  }) {
    return _log(
      'feature_used',
      parameters: {'feature': feature, ...?parameters},
    );
  }

  static Future<void> logApiCall({
    required String endpoint,
    required String method,
    int? statusCode,
    bool success = true,
    int? durationMs,
  }) {
    return _log(
      success ? 'api_call' : 'api_failure',
      parameters: {
        'endpoint': _truncate(endpoint),
        'method': method,
        if (statusCode != null) 'status_code': statusCode,
        if (durationMs != null) 'duration_ms': durationMs,
      },
    );
  }

  static Future<void> logError({
    required String errorType,
    String? feature,
    String? screenName,
    bool isFatal = false,
    String? reason,
  }) {
    return _log(
      'app_error',
      parameters: {
        'error_type': _truncate(errorType),
        'is_fatal': isFatal ? 1 : 0,
        if (feature != null) 'feature': feature,
        if (screenName != null) 'screen_name': screenName,
        if (reason != null) 'reason': _truncate(reason),
      },
    );
  }

  // ─── Auth / identity ────────────────────────────────────────────────────

  static Future<void> logLogin({String method = 'google'}) {
    return _log('login', parameters: {'method': method});
  }

  static Future<void> logSignUp({String method = 'google'}) {
    return _log('sign_up', parameters: {'method': method});
  }

  static Future<void> logLogout() {
    return _log('logout');
  }

  static Future<void> logAccountDeleted() {
    return _log('account_deleted');
  }

  static Future<void> logProfileUpdated({String? field}) {
    return _log(
      'profile_updated',
      parameters: {if (field != null) 'field': field},
    );
  }

  static Future<void> logSetupCompleted() {
    return _log('setup_completed');
  }

  // ─── Presence / talk ────────────────────────────────────────────────────

  static Future<void> logGoOnline({
    required String groupId,
    required String connectionMode,
    bool joinedCallMode = false,
  }) {
    return _log(
      'go_online',
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'connection_mode': connectionMode,
        'joined_call_mode': joinedCallMode ? 1 : 0,
      },
    );
  }

  static Future<void> logGoAway({
    required String groupId,
    required String reason,
  }) {
    return _log(
      'go_away',
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'reason': reason,
      },
    );
  }

  static Future<void> logTalkStart({required String groupId}) {
    return _log(
      'talk_start',
      parameters: {'group_id_suffix': _idSuffix(groupId)},
    );
  }

  static Future<void> logTalkStop({
    required String groupId,
    required String reason,
  }) {
    return _log(
      'talk_stop',
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'reason': reason,
      },
    );
  }

  static Future<void> logConnectionModeChanged({
    required String groupId,
    required String mode,
  }) {
    return _log(
      'connection_mode_changed',
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'mode': mode,
      },
    );
  }

  static Future<void> logHandRaise({
    required String groupId,
    required bool raised,
  }) {
    return _log(
      'hand_raise',
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'raised': raised ? 1 : 0,
      },
    );
  }

  static Future<void> logDailyUsageCapReached({required String groupId}) {
    return _log(
      'daily_usage_cap_reached',
      parameters: {'group_id_suffix': _idSuffix(groupId)},
    );
  }

  // ─── Groups / invites ───────────────────────────────────────────────────

  static Future<void> logGroupCreated({required String groupId}) {
    return _log(
      'group_created',
      parameters: {'group_id_suffix': _idSuffix(groupId)},
    );
  }

  static Future<void> logGroupJoined({
    required String groupId,
    String source = 'invite',
  }) {
    return _log(
      'group_joined',
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'source': source,
      },
    );
  }

  static Future<void> logGroupLeft({required String groupId}) {
    return _log(
      'group_left',
      parameters: {'group_id_suffix': _idSuffix(groupId)},
    );
  }

  static Future<void> logInviteCreated({required String groupId}) {
    return _log(
      'invite_created',
      parameters: {'group_id_suffix': _idSuffix(groupId)},
    );
  }

  // ─── Nudges ─────────────────────────────────────────────────────────────

  static Future<void> logNudgeSent({
    required String groupId,
    required String kind,
    required String targetScope,
    int? audioBytes,
    int? durationMs,
  }) {
    return _log(
      'nudge_sent',
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'kind': kind,
        'target_scope': targetScope,
        if (audioBytes != null) 'audio_bytes': audioBytes,
        if (durationMs != null) 'duration_ms': durationMs,
      },
    );
  }

  static Future<void> logNudgeResponded({
    required String groupId,
    required String action,
    int? snoozeMinutes,
  }) {
    return _log(
      'nudge_responded',
      parameters: {
        'group_id_suffix': _idSuffix(groupId),
        'action': action,
        if (snoozeMinutes != null) 'snooze_minutes': snoozeMinutes,
      },
    );
  }

  // ─── App lifecycle ──────────────────────────────────────────────────────

  static Future<void> logAppOpen() {
    return _log('app_open');
  }

  static Future<void> logSessionStarted() {
    return _log('session_started');
  }

  static Future<void> logServiceStatusBlocked({required String status}) {
    return _log(
      'service_status_blocked',
      parameters: {'status': status},
    );
  }

  // ─── User identity / properties ─────────────────────────────────────────

  static Future<void> setUserId(String? userId) async {
    final id = userId?.trim();
    _debug('setUserId=${id == null || id.isEmpty ? '(cleared)' : id}');
    await _analytics.setUserId(id: (id == null || id.isEmpty) ? null : id);
  }

  static Future<void> setUserProperty({
    required String name,
    required String? value,
  }) async {
    _debug('setUserProperty $name=$value');
    await _analytics.setUserProperty(name: name, value: value);
  }

  static Future<void> setUserProperties(Map<String, String?> properties) async {
    for (final entry in properties.entries) {
      await setUserProperty(name: entry.key, value: entry.value);
    }
  }

  static Future<void> resetAnalytics() async {
    _debug('resetAnalyticsData');
    await _analytics.resetAnalyticsData();
  }

  // ─── Internals ──────────────────────────────────────────────────────────

  static Future<void> _log(
    String name, {
    Map<String, Object>? parameters,
  }) async {
    final cleanParams = parameters == null
        ? null
        : Map<String, Object>.fromEntries(
            parameters.entries.where((e) => e.value.toString().isNotEmpty),
          );
    if (kDebugMode) {
      final buffer = StringBuffer('Analytics Event:\n$name');
      if (cleanParams != null && cleanParams.isNotEmpty) {
        buffer.write('\nparameters:');
        for (final entry in cleanParams.entries) {
          buffer.write('\n  ${entry.key}=${entry.value}');
        }
      }
      debugPrint(buffer.toString());
    }
    await _analytics.logEvent(name: name, parameters: cleanParams);
  }

  static String _idSuffix(String id) {
    final clean = id.trim();
    if (clean.length <= 8) return clean;
    return clean.substring(clean.length - 8);
  }

  static String _truncate(String value, [int max = 100]) {
    final clean = value.trim();
    if (clean.length <= max) return clean;
    return clean.substring(0, max);
  }

  static void _debug(String message) {
    if (kDebugMode) debugPrint('[Analytics] $message');
  }
}
