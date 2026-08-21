/// Three-tier haptic intensity for incoming nudges (voice, ring, and
/// notification). Light is the historical default: two bursts at start and
/// two at end. Medium plays a double-double burst pattern. Wild vibrates
/// continuously for the whole nudge.
enum HapticsIntensity {
  light,
  medium,
  wild;

  static const HapticsIntensity defaultValue = light;

  static HapticsIntensity parse(String? value) {
    return switch (value) {
      'medium' => medium,
      'wild' => wild,
      _ => light,
    };
  }

  String get storageKey => name;

  String get emoji => switch (this) {
    light => '🌿',
    medium => '⚡',
    wild => '🔥',
  };

  String get label => switch (this) {
    light => 'Light',
    medium => 'Pulse',
    wild => 'Wild',
  };

  String get subtitle => switch (this) {
    light => 'Two taps at the start and two at the end.',
    medium => 'A double-double burst — two quick pairs.',
    wild => 'Continuous vibration for the whole nudge.',
  };
}
