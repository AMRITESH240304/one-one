import 'dart:async';

import 'package:flutter/services.dart';

import '../identity/models/haptics_intensity.dart';

/// Flutter-side haptic patterns matching the three Settings tiers.
///
/// Native playback (incoming voice / ring / notification nudges) uses the
/// same intensity via [HapticsPreferenceStore]. This helper covers in-app
/// sender recording so the chosen tier is felt immediately while holding.
class NudgeHaptics {
  NudgeHaptics._();

  static Timer? _wildTimer;

  static Future<void> playStart(HapticsIntensity intensity) async {
    stopWild();
    switch (intensity) {
      case HapticsIntensity.light:
        await _doubleTap();
      case HapticsIntensity.medium:
        await _doubleDouble();
      case HapticsIntensity.wild:
        await HapticFeedback.mediumImpact();
        _wildTimer = Timer.periodic(const Duration(milliseconds: 180), (_) {
          unawaited(HapticFeedback.mediumImpact());
        });
    }
  }

  static Future<void> playEnd(HapticsIntensity intensity) async {
    stopWild();
    switch (intensity) {
      case HapticsIntensity.light:
        await _doubleTap();
      case HapticsIntensity.medium:
        await _doubleDouble();
      case HapticsIntensity.wild:
        await HapticFeedback.heavyImpact();
    }
  }

  static void stopWild() {
    _wildTimer?.cancel();
    _wildTimer = null;
  }

  static Future<void> _doubleTap() async {
    await HapticFeedback.mediumImpact();
    await Future<void>.delayed(const Duration(milliseconds: 90));
    await HapticFeedback.mediumImpact();
  }

  static Future<void> _doubleDouble() async {
    await _doubleTap();
    await Future<void>.delayed(const Duration(milliseconds: 160));
    await _doubleTap();
  }
}
