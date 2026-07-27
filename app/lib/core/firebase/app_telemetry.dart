import 'crashlytics_service.dart';
import 'firebase_analytics_service.dart';
import 'firebase_performance_service.dart';

/// Dual-writes important product breadcrumbs to Analytics + Crashlytics.
class AppTelemetry {
  AppTelemetry._();

  static Future<void> breadcrumb(
    String message, {
    String? analyticsEvent,
    Map<String, Object>? parameters,
  }) async {
    await CrashlyticsService.log(message);
    if (analyticsEvent != null) {
      await AnalyticsService.logCustomEvent(
        analyticsEvent,
        parameters: parameters,
      );
    }
  }

  /// Convenience wrapper for a named Performance custom code trace.
  static Future<T> trace<T>(
    String name,
    Future<T> Function() action, {
    Map<String, String>? attributes,
  }) {
    return PerformanceService.trace(name, action, attributes: attributes);
  }

  static Future<void> identifyUser({
    required String userId,
    String? appVersion,
    String? deviceId,
    String? environment,
  }) async {
    await Future.wait([
      AnalyticsService.setUserId(userId),
      CrashlyticsService.setUserIdentifier(userId),
      AnalyticsService.setUserProperties({
        if (appVersion != null) 'app_version': appVersion,
        if (environment != null) 'environment': environment,
        'platform': 'android',
      }),
      if (appVersion != null || deviceId != null)
        CrashlyticsService.setCustomKeys({
          if (appVersion != null) 'app_version': appVersion,
          if (deviceId != null) 'device_id': deviceId,
          'user_id': userId,
        }),
    ]);
  }

  static Future<void> clearUser() async {
    await Future.wait([
      AnalyticsService.setUserId(null),
      CrashlyticsService.setUserIdentifier(null),
    ]);
  }
}
