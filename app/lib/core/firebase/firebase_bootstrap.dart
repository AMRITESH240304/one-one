import 'package:firebase_core/firebase_core.dart';

/// Single owner of `Firebase.initializeApp()`.
///
/// Started immediately after `runApp()` in `main.dart` so the first Flutter
/// frame never blocks on it. `_FirebaseGate` awaits this same future instead
/// of calling `Firebase.initializeApp()` itself, so init only ever runs once
/// no matter which caller reaches it first.
class FirebaseBootstrap {
  FirebaseBootstrap._();

  static Future<FirebaseApp>? _future;

  /// Kicks off (or returns the in-flight/completed) Firebase init.
  static Future<FirebaseApp> start() {
    return _future ??= _init();
  }

  static Future<FirebaseApp> _init() {
    return Firebase.apps.isEmpty
        ? Firebase.initializeApp()
        : Future.value(Firebase.app());
  }
}
