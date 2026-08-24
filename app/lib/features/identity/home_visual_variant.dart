import 'package:one_one_app/one_one.dart';

// ---------------------------------------------------------------------------
// Enum — 4 pre-release design variants for home screen backdrop evaluation.
// Remove before next public release or gate behind compile-time flag.
// ---------------------------------------------------------------------------

enum HomeVisualVariant {
  /// 1 — current production look.
  defaultLook(
    label: 'Default (current)',
    subtitle: 'Opacity 0.35, blur 40 — the shipped look.',
    backdropOpacity: 0.35,
    blurSigma: 40,
  ),

  /// 2 — lighter/more transparent backdrop.
  light(
    label: 'Light — transparent',
    subtitle: 'Opacity 0.18, blur 40 — softer background.',
    backdropOpacity: 0.18,
    blurSigma: 40,
  ),

  /// 3 — more opaque, crisper.
  vivid(
    label: 'Vivid — more opaque, crisper',
    subtitle: 'Opacity 0.52, blur 22 — richer colours, less blur.',
    backdropOpacity: 0.52,
    blurSigma: 22,
  ),

  /// 4 — heavy blur / dream-like.
  heavyBlur(
    label: 'Heavy blur — dream-like',
    subtitle: 'Opacity 0.35, blur 72 — very smooth, diffuse.',
    backdropOpacity: 0.35,
    blurSigma: 72,
  );

  const HomeVisualVariant({
    required this.label,
    required this.subtitle,
    required this.backdropOpacity,
    required this.blurSigma,
  });

  final String label;
  final String subtitle;
  final double backdropOpacity;
  final double blurSigma;
}

// ---------------------------------------------------------------------------
// Controller
// ---------------------------------------------------------------------------

/// Manages the active [HomeVisualVariant] and the testing-section unlock
/// state. Persisted to SharedPreferences so the team's selection survives
/// app restarts during evaluation.
///
/// The testing section in Settings is hidden until [unlockTesting] is called
/// (tap "Settings" title 7 times rapidly). Remove this controller and its
/// references before the next public release.
class HomeVisualVariantController {
  HomeVisualVariantController._();

  static const _prefKeyVariant = 'home_visual_variant';
  static const _prefKeyUnlocked = 'home_visual_testing_unlocked';

  /// Whether the hidden testing section has been unlocked by the team.
  static final ValueNotifier<bool> unlocked = ValueNotifier<bool>(false);

  /// The currently active home screen visual variant.
  static final ValueNotifier<HomeVisualVariant> current =
      ValueNotifier<HomeVisualVariant>(HomeVisualVariant.defaultLook);

  /// Load persisted state. Call once on settings screen init.
  static Future<void> ensureLoaded() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefKeyVariant);
      if (raw != null) {
        final match = HomeVisualVariant.values.where((v) => v.name == raw).firstOrNull;
        if (match != null) current.value = match;
      }
      unlocked.value = prefs.getBool(_prefKeyUnlocked) ?? false;
    } catch (_) {
      // Best-effort; defaults remain if prefs fail.
    }
  }

  /// Persist and apply a variant selection.
  static Future<void> setVariant(HomeVisualVariant variant) async {
    current.value = variant;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefKeyVariant, variant.name);
    } catch (_) {}
  }

  /// Unlock the testing section. Called after the hidden tap sequence.
  static Future<void> unlockTesting() async {
    unlocked.value = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKeyUnlocked, true);
    } catch (_) {}
  }
}
