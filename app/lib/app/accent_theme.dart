import 'package:flutter/material.dart';

class AccentOption {
  const AccentOption({
    required this.key,
    required this.label,
    required this.color,
  });

  final String key;
  final String label;
  final Color color;
}

const List<AccentOption> accentOptions = [
  AccentOption(key: 'coral', label: 'Coral', color: Color(0xffff5a5f)),
  AccentOption(key: 'lime', label: 'Lime', color: Color(0xff9bdc28)),
  AccentOption(key: 'sky', label: 'Sky', color: Color(0xff25a9ff)),
  AccentOption(key: 'violet', label: 'Violet', color: Color(0xff8b5cf6)),
  AccentOption(key: 'amber', label: 'Amber', color: Color(0xffffb020)),
  AccentOption(key: 'pink', label: 'Pink', color: Color(0xffec4899)),
  AccentOption(key: 'teal', label: 'Teal', color: Color(0xff00b8a9)),
  AccentOption(key: 'indigo', label: 'Indigo', color: Color(0xff6366f1)),
  AccentOption(key: 'orange', label: 'Orange', color: Color(0xffff7a3d)),
  AccentOption(key: 'mint', label: 'Mint', color: Color(0xff34d399)),
  AccentOption(key: 'yellow', label: 'Yellow', color: Color(0xffeab308)),
  AccentOption(key: 'cyan', label: 'Cyan', color: Color(0xff22d3ee)),
];

Color accentColorForKey(String key) {
  for (final option in accentOptions) {
    if (option.key == key) return option.color;
  }

  return accentOptions.first.color;
}

class AccentThemeController {
  AccentThemeController._();

  static final ValueNotifier<String> accentKey = ValueNotifier<String>(
    accentOptions.first.key,
  );

  static void setAccentKey(String key) {
    final next = accentOptions.any((option) => option.key == key)
        ? key
        : accentOptions.first.key;
    // Avoid notifying listeners when nothing changed — a root rebuild of
    // MaterialApp-dependent trees while widgets are mid-save/pop can crash.
    if (accentKey.value == next) return;
    accentKey.value = next;
  }
}
