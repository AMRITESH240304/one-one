/// In-memory (per app process) record of the most recent nudge delivery
/// failures, so the send-nudge sheet can surface reasons after the user
/// dismisses the sheet and reopens it.
///
/// Entries expire after [timeout] or when a successful delivery is recorded
/// for that recipient.
class NudgeFailureMemory {
  NudgeFailureMemory._();

  static final NudgeFailureMemory instance = NudgeFailureMemory._();

  /// How long a failure reason stays on the sheet when the user returns.
  static const Duration timeout = Duration(minutes: 15);

  final Map<String, NudgeFailureEntry> _byUserId = {};

  List<NudgeFailureEntry> get active {
    final now = DateTime.now();
    _byUserId.removeWhere((_, entry) => now.difference(entry.at) > timeout);
    return _byUserId.values.toList(growable: false)
      ..sort((a, b) => b.at.compareTo(a.at));
  }

  NudgeFailureEntry? forUser(String userId) {
    final entry = _byUserId[userId];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) > timeout) {
      _byUserId.remove(userId);
      return null;
    }
    return entry;
  }

  void record({
    required String userId,
    required String displayName,
    required String message,
    String? reasonCode,
  }) {
    if (userId.isEmpty) return;
    _byUserId[userId] = NudgeFailureEntry(
      userId: userId,
      displayName: displayName,
      message: message,
      reasonCode: reasonCode,
      at: DateTime.now(),
    );
  }

  void clearUser(String userId) {
    _byUserId.remove(userId);
  }

  void clearAll() {
    _byUserId.clear();
  }

  /// Clears failures for every user who succeeded on this send.
  void clearSuccessful(Iterable<String> userIds) {
    for (final id in userIds) {
      _byUserId.remove(id);
    }
  }
}

class NudgeFailureEntry {
  const NudgeFailureEntry({
    required this.userId,
    required this.displayName,
    required this.message,
    required this.at,
    this.reasonCode,
  });

  final String userId;
  final String displayName;
  final String message;
  final String? reasonCode;
  final DateTime at;
}
