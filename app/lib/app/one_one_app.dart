import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'accent_theme.dart';
import 'google_auth_screen.dart';
import 'startup_gate_screen.dart';
import 'startup_performance.dart';
import '../core/firebase/crashlytics_service.dart';
import '../core/firebase/firebase_analytics_service.dart';
import '../features/service_status/service_status_gate.dart';

class OneOneApp extends StatelessWidget {
  const OneOneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: AccentThemeController.accentKey,
      builder: (context, accentKey, _) {
        final seedColor = accentColorForKey(accentKey);

        return MaterialApp(
          title: 'One One',
          debugShowCheckedModeBanner: false,
          navigatorObservers: [AnalyticsService.observer],
          routes: {
            '/auth': (_) => const WithForegroundTask(
              child: _AuthSessionLifecycle(child: _FirebaseGate()),
            ),
          },
          builder: (context, child) {
            return ScreenUtilInit(
              designSize: const Size(393, 873),
              minTextAdapt: true,
              splitScreenMode: true,
              child: child,
            );
          },
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: seedColor,
              brightness: Brightness.dark,
            ),
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xff101010),
            canvasColor: const Color(0xff101010),
            fontFamily: GoogleFonts.poppins().fontFamily,
            textTheme: GoogleFonts.poppinsTextTheme(
              ThemeData(brightness: Brightness.dark).textTheme,
            ),
            primaryTextTheme: GoogleFonts.poppinsTextTheme(
              ThemeData(brightness: Brightness.dark).textTheme,
            ),
            useMaterial3: true,
          ),
          home: const WithForegroundTask(
            child: _AuthSessionLifecycle(child: _FirebaseGate()),
          ),
        );
      },
    );
  }
}

class _AuthSessionLifecycle extends StatefulWidget {
  const _AuthSessionLifecycle({required this.child});

  final Widget child;

  @override
  State<_AuthSessionLifecycle> createState() => _AuthSessionLifecycleState();
}

class _AuthSessionLifecycleState extends State<_AuthSessionLifecycle>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(AnalyticsService.logSessionStarted());
      unawaited(_refreshFirebaseToken());
    }
  }

  Future<void> _refreshFirebaseToken() async {
    try {
      await FirebaseAuth.instance.currentUser?.getIdToken();
    } catch (_) {
      // Keep the mounted session intact; Firebase retries token refresh on use.
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _FirebaseGate extends StatefulWidget {
  const _FirebaseGate();

  @override
  State<_FirebaseGate> createState() => _FirebaseGateState();
}

class _FirebaseGateState extends State<_FirebaseGate> {
  @override
  void initState() {
    super.initState();
    // Firebase is already initialized in main.dart before runApp.
    // Telemetry is fire-and-forget — never block the first frame on it.
    unawaited(_logFirebaseReady());
  }

  Future<void> _logFirebaseReady() async {
    final stopwatch = Stopwatch()..start();
    logStartupMilestone('Firebase ready', stopwatch);
    try {
      await CrashlyticsService.log('firebase_gate_ready');
    } catch (_) {
      // Telemetry failure must never block the UI.
    }
  }

  @override
  Widget build(BuildContext context) {
    // No FutureBuilder — go straight to the auth-gated content on the very
    // first frame. The native window background is the same yellow as the
    // welcome screen, so there is zero visual break between launch and Flutter.
    return ServiceStatusGate(
      child: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.userChanges(),
        initialData: FirebaseAuth.instance.currentUser,
        builder: (context, authSnapshot) {
          final user = authSnapshot.data;
          if (user == null ||
              user.isAnonymous ||
              !user.providerData.any(
                (provider) => provider.providerId == 'google.com',
              )) {
            return const GoogleAuthScreen();
          }

          return const StartupGateScreen();
        },
      ),
    );
  }
}
