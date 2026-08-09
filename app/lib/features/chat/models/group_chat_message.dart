/// A single ephemeral chat bubble sent to a group.
///
/// Bubbles are lightweight and self-expiring — there's no edit/delete flow,
/// just [expiresAt], which every render site checks via [isExpired] instead
/// of relying on the backend to prune old rows.
class GroupChatMessage {
  const GroupChatMessage({
    required this.messageId,
    required this.groupId,
    required this.senderUserId,
    required this.senderDisplayName,
    required this.text,
    required this.createdAt,
    required this.expiresAt,
  });

  final String messageId;
  final String groupId;
  final String senderUserId;
  final String senderDisplayName;
  final String text;

  /// Unix seconds.
  final int createdAt;

  /// Unix seconds. Bubbles are hidden client-side once `now >= expiresAt`
  /// (at most 10 minutes from send), independent of whether the RTDB row
  /// has actually been removed.
  final int expiresAt;

  bool get isExpired =>
      expiresAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Seconds remaining until [isExpired] becomes true. Never negative.
  int get secondsUntilExpiry {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final remaining = expiresAt - now;
    return remaining > 0 ? remaining : 0;
  }

  static GroupChatMessage? tryParse(String messageId, Object? value) {
    if (value is! Map) return null;

    final groupId = value['groupId']?.toString();
    final senderUserId = value['senderUserId']?.toString();
    final text = value['text']?.toString();
    final createdAt = _asInt(value['createdAt']);
    final expiresAt = _asInt(value['expiresAt']);
    if (groupId == null ||
        groupId.isEmpty ||
        senderUserId == null ||
        senderUserId.isEmpty ||
        text == null ||
        text.isEmpty ||
        createdAt == null ||
        expiresAt == null) {
      return null;
    }

    return GroupChatMessage(
      messageId: messageId,
      groupId: groupId,
      senderUserId: senderUserId,
      senderDisplayName: value['senderDisplayName']?.toString() ?? 'Someone',
      text: text,
      createdAt: createdAt,
      expiresAt: expiresAt,
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}
