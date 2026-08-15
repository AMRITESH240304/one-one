import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import 'accent_theme.dart';
import 'firebase_setup_blocked_screen.dart';
import 'google_auth_screen.dart';
import 'startup_gate_screen.dart';
import 'startup_performance.dart';
import '../core/firebase/crashlytics_service.dart';
import '../core/firebase/firebase_analytics_service.dart';
import '../core/firebase/firebase_bootstrap.dart';
import '../core/logging/log_level.dart';
import '../core/logging/log_manager.dart';
import '../features/service_status/service_status_gate.dart';

class OneOneApp extends StatelessWidget {
  const OneOneApp({super.key});

  ThemeData _themeFor(Color seedColor) {
    return ThemeData(
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
    );
  }

  @override
  Widget build(BuildContext context) {
    // MaterialApp must NOT live inside a ValueListenableBuilder that rebuilds
    // on accent changes — recreating MaterialApp tears down the navigator
    // element tree while screens are still mid setState/pop after save and
    // trips '_dependents.isEmpty'. Accent is applied via Theme in `builder`.
    return MaterialApp(
      title: 'Duo',
      debugShowCheckedModeBanner: false,
      navigatorObservers: [AnalyticsService.observer],
      routes: {
        '/auth': (_) => const WithForegroundTask(
          child: _AuthSessionLifecycle(child: _FirebaseGate()),
        ),
      },
      theme: _themeFor(accentColorForKey(AccentThemeController.accentKey.value)),
      builder: (context, child) {
        return ValueListenableBuilder<String>(
          valueListenable: AccentThemeController.accentKey,
          builder: (context, accentKey, _) {
            return Theme(
              data: _themeFor(accentColorForKey(accentKey)),
              child: ScreenUtilInit(
                designSize: const Size(393, 873),
                minTextAdapt: true,
                splitScreenMode: true,
                child: child,
              ),
            );
          },
        );
      },
      home: const WithForegroundTask(
        child: _AuthSessionLifecycle(child: _FirebaseGate()),
      ),
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
    switch (state) {
      case AppLifecycleState.resumed:
        LogManager.log(LogLevel.info, 'AppLifecycle', 'App foregrounded');
        unawaited(AnalyticsService.logSessionStarted());
        unawaited(_refreshFirebaseToken());
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.hidden:
        break;
      case AppLifecycleState.paused:
        LogManager.log(LogLevel.info, 'AppLifecycle', 'App backgrounded');
      case AppLifecycleState.detached:
        LogManager.log(
          LogLevel.warn,
          'AppLifecycle',
          'App killed / detached (process teardown)',
        );
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
  late final Future<FirebaseApp> _firebaseInit = _initializeFirebase();

  Future<FirebaseApp> _initializeFirebase() async {
    final stopwatch = Stopwatch()..start();
    // main.dart kicks this off the instant runApp() returns, so by the time
    // this screen is on-screen the init is usually already in flight (or
    // done). Awaiting the shared future here — rather than calling
    // Firebase.initializeApp() again — guarantees Firebase only ever
    // initializes once.
    final app = await FirebaseBootstrap.start();
    logStartupMilestone('Firebase ready', stopwatch);
    await CrashlyticsService.log('firebase_gate_ready');
    return app;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FirebaseApp>(
      future: _firebaseInit,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          // Brand splash only — GoogleAuthScreen constructs IdentityRepository,
          // which touches FirebaseAuth and must not run before init finishes.
          return const BrandSplashScreen();
        }

        if (snapshot.hasError) {
          return FirebaseSetupBlockedScreen(
            errorText: snapshot.error.toString(),
          );
        }

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
      },
    );
  }
}
