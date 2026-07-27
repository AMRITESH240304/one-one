import 'crashlytics_service.dart';
import 'firebase_analytics_service.dart';

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
