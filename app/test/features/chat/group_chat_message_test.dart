import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/features/chat/models/group_chat_message.dart';

void main() {
  group('GroupChatMessage.tryParse', () {
    test('parses a well-formed RTDB row', () {
      final message = GroupChatMessage.tryParse('msg1', {
        'groupId': 'group1',
        'senderUserId': 'user1',
        'senderDisplayName': 'Ada',
        'text': 'On my way',
        'createdAt': 1000,
        'expiresAt': 1900,
      });

      expect(message, isNotNull);
      expect(message!.messageId, 'msg1');
      expect(message.senderDisplayName, 'Ada');
      expect(message.text, 'On my way');
      expect(message.createdAt, 1000);
      expect(message.expiresAt, 1900);
    });

    test('falls back to a generic sender name when missing', () {
      final message = GroupChatMessage.tryParse('msg1', {
        'groupId': 'group1',
        'senderUserId': 'user1',
        'text': 'On my way',
        'createdAt': 1000,
        'expiresAt': 1900,
      });

      expect(message!.senderDisplayName, 'Someone');
    });

    test('rejects rows missing required fields', () {
      expect(
        GroupChatMessage.tryParse('msg1', {
          'groupId': 'group1',
          'senderUserId': 'user1',
          'createdAt': 1000,
          'expiresAt': 1900,
        }),
        isNull,
      );
      expect(GroupChatMessage.tryParse('msg1', 'not a map'), isNull);
      expect(GroupChatMessage.tryParse('msg1', null), isNull);
    });
  });

  group('GroupChatMessage.isExpired', () {
    test('is true once expiresAt has passed', () {
      final past = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60;
      final message = GroupChatMessage(
        messageId: 'msg1',
        groupId: 'group1',
        senderUserId: 'user1',
        senderDisplayName: 'Ada',
        text: 'hi',
        createdAt: past - 900,
        expiresAt: past,
      );

      expect(message.isExpired, isTrue);
      expect(message.secondsUntilExpiry, 0);
    });

    test('is false while still within its 10-minute window', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final message = GroupChatMessage(
        messageId: 'msg1',
        groupId: 'group1',
        senderUserId: 'user1',
        senderDisplayName: 'Ada',
        text: 'hi',
        createdAt: now,
        expiresAt: now + 600,
      );

      expect(message.isExpired, isFalse);
      expect(message.secondsUntilExpiry, greaterThan(0));
    });
  });
}
