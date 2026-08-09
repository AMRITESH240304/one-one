import 'dart:async';

import 'package:firebase_database/firebase_database.dart';

import '../../../core/firebase/app_database.dart';
import '../../../core/network/api_client.dart';

/// Reads/writes ephemeral group chat bubbles (Prompt 5).
///
/// Messages live at `groupMessages/{groupId}/{messageId}` — a push-keyed
/// sibling of `memberAvailability`/`handRaises` — so RTDB security rules and
/// listener teardown follow the same shape already used elsewhere in the
/// screen. Sending writes the bubble directly (client has write access, same
/// as presence) then best-effort asks the backend to fan out a push
/// notification, mirroring `OnlineRepository.notifyGoneOffline`.
class ChatMessageRepository {
  ChatMessageRepository({ApiClient? apiClient, FirebaseDatabase? database})
    : _apiClient = apiClient ?? ApiClient(),
      _database = database ?? AppDatabase.instance();

  final ApiClient _apiClient;
  final FirebaseDatabase _database;

  /// Short, chip-style bubbles — not a full chat thread.
  static const int maxWords = 10;

  /// Rolling window of past messages kept visible on every client.
  static const int visibleLimit = 5;

  /// Hard cap: a bubble never stays longer than this, even if still in the
  /// rolling window of [visibleLimit] messages.
  static const Duration lifetime = Duration(minutes: 10);

  DatabaseReference groupMessagesRef(String groupId) =>
      _database.ref('groupMessages/$groupId');

  /// Collapses whitespace and enforces the [maxWords] cap. Returns null for
  /// empty or over-length input so callers can treat that as "don't send".
  static String? sanitize(String rawText) {
    final normalized = rawText.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) return null;
    if (normalized.split(' ').length > maxWords) return null;
    return normalized;
  }

  Future<void> sendMessage({
    required String groupId,
    required String senderUserId,
    required String senderDisplayName,
    required String text,
  }) async {
    final sanitized = sanitize(text);
    if (sanitized == null) {
      throw ArgumentError.value(
        text,
        'text',
        'Message must be 1-$maxWords words.',
      );
    }

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final ref = groupMessagesRef(groupId).push();
    final messageId = ref.key;
    if (messageId == null) {
      throw StateError('Failed to allocate a chat message id.');
    }

    await ref.set({
      'messageId': messageId,
      'groupId': groupId,
      'senderUserId': senderUserId,
      'senderDisplayName': senderDisplayName,
      'text': sanitized,
      'createdAt': now,
      'expiresAt': now + lifetime.inSeconds,
    });

    unawaited(_notifyGroup(groupId));
  }

  /// Best-effort push fan-out — the bubble is already live in-app via RTDB,
  /// so a failed/slow notification call must never block or fail sendMessage.
  Future<void> _notifyGroup(String groupId) async {
    try {
      await _apiClient.postJson(
        '/v1/groups/$groupId/chat-messages/notify',
        const {},
      );
    } catch (_) {
      // Non-fatal — see doc comment above.
    }
  }
}
