import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app/one_one_app.dart';
import 'app/startup_performance.dart';
import 'core/firebase/crashlytics_service.dart';
import 'core/firebase/firebase_analytics_service.dart';
import 'core/firebase/firebase_performance_service.dart';
import 'features/online/livekit_connection_warmer.dart';
import 'features/subscriptions/revenue_cat_service.dart';

Future<void> main() async {
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // Touch-load the WebRTC native library in the background now so the
    // jingle_peerconnection_so load does not sit on the first go-online path.
    unawaited(LiveKitConnectionWarmer.instance.ensureWebRtcInitialized());
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => logStartupMilestone('first Flutter frame'),
    );

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    FlutterForegroundTask.initCommunicationPort();

    await Firebase.initializeApp();
    debugPrint('[Firebase] initialized');
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      unawaited(CrashlyticsService.recordFlutterFatalError(details));
    };

    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(
        CrashlyticsService.recordFatalError(
          error,
          stack,
          reason: 'platform_dispatcher',
        ),
      );
      return true;
    };

    runApp(const OneOneApp());
    // Firebase Auth is needed before the first frame; telemetry is not.
    unawaited(CrashlyticsService.initialize());
    unawaited(AnalyticsService.initialize());
    unawaited(PerformanceService.initialize());
    // RevenueCat initializes in the background so subscription state is
    // available by the time the user reaches any gated feature.
    unawaited(RevenueCatService.initialize());
  }, (error, stack) {
    debugPrint('[Crashlytics] zone error: $error');
    unawaited(
      CrashlyticsService.recordFatalError(
        error,
        stack,
        reason: 'runZonedGuarded',
      ),
    );
  });
}
