import 'package:one_one_app/one_one.dart';

/// Flutter-side haptic patterns matching the three Settings tiers.
///
/// Used to preview the chosen intensity in Settings. Native incoming
/// voice-nudge playback applies the same intensity via
/// [HapticsPreferenceStore]. Sender recording and other UI feedback use
/// fixed defaults instead.
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
