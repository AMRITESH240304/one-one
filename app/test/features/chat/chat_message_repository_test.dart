import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

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

    test('allows exactly the 10-word cap', () {
      final tenWords = List.generate(10, (i) => 'word$i').join(' ');
      expect(ChatMessageRepository.sanitize(tenWords), tenWords);
    });

    test('rejects messages over the 10-word cap', () {
      final elevenWords = List.generate(11, (i) => 'word$i').join(' ');
      expect(ChatMessageRepository.sanitize(elevenWords), isNull);
    });
  });
}
