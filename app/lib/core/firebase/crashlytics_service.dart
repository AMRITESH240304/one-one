import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/foundation.dart';

/// Thin wrapper around [FirebaseCrashlytics] for app-wide crash reporting.
class CrashlyticsService {
  CrashlyticsService._();

  static final FirebaseCrashlytics _crashlytics = FirebaseCrashlytics.instance;

  static Future<void> initialize() async {
    // Keep collection on in debug so the Crashlytics test page works during
    // development. Gate on kReleaseMode later if you want debug builds quiet.
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
  }

  static Future<void> recordFatalError(
    Object error,
    StackTrace? stack, {
    String? reason,
    Iterable<Object> information = const [],
  }) {
    return recordError(
      error,
      stack,
      reason: reason,
      fatal: true,
      information: information,
    );
  }

  static Future<void> recordFlutterFatalError(FlutterErrorDetails details) {
    debugPrint(
      '[Crashlytics] Flutter fatal error recorded '
      'exception=${details.exceptionAsString()}',
    );
    return _crashlytics.recordFlutterFatalError(details);
  }

  static Future<void> log(String message) async {
    debugPrint('[Crashlytics] log: $message');
    await _crashlytics.log(message);
  }

  static Future<void> setUserIdentifier(String? userId) async {
    final id = userId?.trim() ?? '';
    debugPrint('[Crashlytics] setUserIdentifier=${id.isEmpty ? '(cleared)' : id}');
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

  /// Forces a native Android crash. Used only by the Crashlytics test page.
  static void crash() {
    debugPrint('[Crashlytics] native crash triggered');
    _crashlytics.crash();
  }
}
