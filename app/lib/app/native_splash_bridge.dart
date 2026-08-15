import 'dart:async';

import 'package:flutter/services.dart';

/// Bridges to the native Android splash (`MainActivity.installSplashScreen`
/// + `setKeepOnScreenCondition`). The native splash renders the same brand
/// background/logo as our Flutter loading screens and stays on top of
/// everything — engine boot, Firebase init, identity/group prefetch — until
/// this fires. That gives a single continuous splash instead of a native
/// splash handing off to a second, different-looking Flutter splash.
///
/// Safe to call from multiple call sites and multiple times; only the first
/// call has any effect.
class NativeSplashBridge {
  NativeSplashBridge._();

  static const MethodChannel _channel = MethodChannel('app/splash');
  static bool _sent = false;

  /// Tells the native side the first real, interactive screen (sign-in CTA,
  /// home, onboarding, or an error screen) is on screen and it's safe to
  /// dismiss the native splash.
  static void markReady() {
    if (_sent) return;
    _sent = true;
    unawaited(
      _channel.invokeMethod<void>('flutterReady').catchError((_) {}),
    );
  }
}
