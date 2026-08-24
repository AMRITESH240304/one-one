import 'package:one_one_app/one_one.dart';

/// Persists which group the user was last active in so cold launches (app
/// killed and reopened) can restore focus to that group instead of always
/// defaulting to the first group in the carousel.
class LastActiveGroupStore {
  const LastActiveGroupStore._();

  static String _key(String userId) => 'one_one_last_active_group_$userId';

  /// Returns the persisted group id for [userId], or null if none is stored
  /// (e.g. first launch).
  static Future<String?> read(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key(userId));
    return (value == null || value.isEmpty) ? null : value;
  }

  /// Records [groupId] as the last group [userId] was active in.
  static Future<void> write(String userId, String groupId) async {
    if (userId.isEmpty || groupId.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(userId), groupId);
  }
}
