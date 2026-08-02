import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

import 'firebase_analytics_service.dart';

/// Thin wrapper around [FirebaseCrashlytics] for app-wide crash reporting.
class CrashlyticsService {
  CrashlyticsService._();

  static final FirebaseCrashlytics _crashlytics = FirebaseCrashlytics.instance;

  static Future<void> initialize() async {
    // Keep collection on in debug so local verification still uploads reports.
    // Gate on kReleaseMode later if you want debug builds quiet.
    await _crashlytics.setCrashlyticsCollectionEnabled(true);
    debugPrint(
      '[Crashlytics] initialized collectionEnabled='
      '${_crashlytics.isCrashlyticsCollectionEnabled}',
    );
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
    await _crashlytics.recordFlutterFatalError(details);
    await AnalyticsService.logError(
      errorType: details.exception.runtimeType.toString(),
      feature: 'flutter_framework',
      isFatal: true,
      reason: details.exceptionAsString(),
    );
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
