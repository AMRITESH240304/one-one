import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/core/logging/user_facing_copy.dart';
import 'package:one_one_app/features/online/livekit_status.dart';

void main() {
  group('UserFacingCopy', () {
    test('keeps short user-facing delivery copy', () {
      expect(
        UserFacingCopy.sanitize('No active friends were found for this nudge.'),
        'No active friends were found for this nudge.',
      );
    });

    test('strips FCM-BE-W1 from sender delivery errors', () {
      expect(
        UserFacingCopy.containsInternalIdentifier(
          'FCM rejected every target device. Check the backend FCM-BE-W1 error code.',
        ),
        isTrue,
      );
      expect(
        UserFacingCopy.sanitize(
          'FCM rejected every target device. Check the backend FCM-BE-W1 error code.',
        ),
        UserFacingCopy.notificationDeliveryFailure,
      );
    });

    test('strips W1/W2 notification handling phrases', () {
      const leak = 'W1 and W2 notification handling failed';
      expect(UserFacingCopy.containsInternalIdentifier(leak), isTrue);
      expect(
        UserFacingCopy.sanitize(leak),
        UserFacingCopy.notificationDeliveryFailure,
      );
    });

    test('strips bracketed worker checkpoints and channel IDs', () {
      expect(
        UserFacingCopy.containsInternalIdentifier(
          '[FCM-W1] Ignored data message',
        ),
        isTrue,
      );
      expect(
        UserFacingCopy.containsInternalIdentifier('[FCM-W2] unknown type'),
        isTrue,
      );
      expect(
        UserFacingCopy.containsInternalIdentifier('channel walkie_alerts_v2'),
        isTrue,
      );
      expect(
        UserFacingCopy.containsInternalIdentifier('posted to voice_nudges'),
        isTrue,
      );
    });

    test('does not flag ordinary user copy', () {
      expect(
        UserFacingCopy.containsInternalIdentifier(
          UserFacingCopy.notificationDeliveryFailure,
        ),
        isFalse,
      );
      expect(
        UserFacingCopy.containsInternalIdentifier(
          'Couldn’t send the nudge. Check your connection.',
        ),
        isFalse,
      );
    });
  });

  group('FcmHandlingContext', () {
    test(
      'builds structured Crashlytics information with worker and app state',
      () {
        final information = FcmHandlingContext.information(
          worker: 'W1',
          groupId: 'group-1',
          eventId: 'event-9',
          kind: 'voice_nudge',
          timestamp: DateTime.utc(2026, 8, 18, 17, 20, 0),
          inBackground: true,
        );

        expect(information, [
          'worker: W1',
          'groupId: group-1',
          'eventId: event-9',
          'kind: voice_nudge',
          'timestamp: 2026-08-18T17:20:00.000Z',
          'appState: background',
        ]);
        expect(
          FcmHandlingContext.failureReason,
          'fcm_notification_handling_failure',
        );
      },
    );

    test('uses dashes for missing payload fields', () {
      final information = FcmHandlingContext.information(
        worker: 'W2',
        inBackground: false,
        timestamp: DateTime.utc(2026, 8, 18),
      );
      expect(information[1], 'groupId: -');
      expect(information[2], 'eventId: -');
      expect(information[3], 'kind: -');
      expect(information.last, 'appState: foreground');
    });
  });

  test('LiveKit status sanitizer never surfaces FCM worker strings', () {
    expect(
      LiveKitStatus.sanitizeError('W1 and W2 notification handling'),
      UserFacingCopy.notificationDeliveryFailure,
    );
  });
}
