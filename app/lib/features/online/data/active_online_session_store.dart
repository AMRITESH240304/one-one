import 'package:one_one_app/one_one.dart';

/// Survives process death so a later launch can clear leftover RTDB presence.
class ActiveOnlineSessionStore {
  const ActiveOnlineSessionStore._();

  static const _key = 'one_one_active_online_session';

  static Future<void> save(OnlineSession session) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(session.toPresenceHandle()));
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static Future<OnlineSession?> read() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return OnlineSession.fromPresenceHandle(decoded);
    } catch (_) {
      return null;
    }
  }
}
