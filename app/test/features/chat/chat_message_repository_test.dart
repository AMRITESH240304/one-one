import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/features/chat/data/chat_message_repository.dart';

void main() {
  group('ChatMessageRepository.sanitize', () {
    test('trims and collapses internal whitespace', () {
      expect(
        ChatMessageRepository.sanitize('  On   my   way  '),
        'On my way',
      );
    });

    test('rejects empty or whitespace-only input', () {
      expect(ChatMessageRepository.sanitize(''), isNull);
      expect(ChatMessageRepository.sanitize('   '), isNull);
    });

    test('allows exactly the 12-word cap', () {
      final twelveWords = List.generate(12, (i) => 'word$i').join(' ');
      expect(ChatMessageRepository.sanitize(twelveWords), twelveWords);
    });

    test('rejects messages over the 12-word cap', () {
      final thirteenWords = List.generate(13, (i) => 'word$i').join(' ');
      expect(ChatMessageRepository.sanitize(thirteenWords), isNull);
    });
  });
}
