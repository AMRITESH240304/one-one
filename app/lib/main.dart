import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app/one_one_app.dart';
import 'app/startup_performance.dart';
import 'core/firebase/crashlytics_service.dart';

Future<void> main() async {
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => logStartupMilestone('first Flutter frame'),
    );

    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);
    FlutterForegroundTask.initCommunicationPort();

    await Firebase.initializeApp();
    debugPrint('[Crashlytics] Firebase initialized');
    await CrashlyticsService.initialize();

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
