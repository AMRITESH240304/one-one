import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/features/nudges/models/media_volume_reading.dart';

void main() {
  group('MediaVolumeBand', () {
    test('classifies muted, very low, low, and ok', () {
      expect(MediaVolumeBandX.fromPercent(0), MediaVolumeBand.muted);
      expect(MediaVolumeBandX.fromPercent(1), MediaVolumeBand.veryLow);
      expect(MediaVolumeBandX.fromPercent(24), MediaVolumeBand.veryLow);
      expect(MediaVolumeBandX.fromPercent(25), MediaVolumeBand.low);
      expect(MediaVolumeBandX.fromPercent(49), MediaVolumeBand.low);
      expect(MediaVolumeBandX.fromPercent(50), MediaVolumeBand.ok);
      expect(MediaVolumeBandX.fromPercent(100), MediaVolumeBand.ok);
    });

    test('formats the sender-facing warning copy', () {
      expect(
        MediaVolumeBand.muted.warningMessage('Ada'),
        '⚠️ Ada is muted',
      );
      expect(
        MediaVolumeBand.veryLow.warningMessage('Ada'),
        "⚠️ Ada's volume is very low (<25%)",
      );
      expect(
        MediaVolumeBand.low.warningMessage('Ada'),
        "⚠️ Ada's volume is low (<50%)",
      );
      expect(MediaVolumeBand.ok.warningMessage('Ada'), isNull);
    });

    test('maps playback attention flags', () {
      expect(
        MediaVolumeBandX.fromAttention('volume_muted'),
        MediaVolumeBand.muted,
      );
      expect(
        MediaVolumeBandX.fromAttention('volume_very_low'),
        MediaVolumeBand.veryLow,
      );
      expect(
        MediaVolumeBandX.fromAttention('volume_low'),
        MediaVolumeBand.low,
      );
      expect(MediaVolumeBandX.fromAttention(null), isNull);
    });
  });

  group('MediaVolumeReading', () {
    final now = DateTime.utc(2026, 8, 18, 12);

    test('parses a group snapshot and clamps the percent', () {
      final readings = MediaVolumeReading.parseGroup(
        groupId: 'g1',
        raw: {
          'u1': {
            'userId': 'u1',
            'groupId': 'g1',
            'volumeLevel': 0,
            'timestamp': now.millisecondsSinceEpoch,
          },
          'u2': {
            'volumeLevel': '140',
            'timestamp': now.millisecondsSinceEpoch ~/ 1000,
          },
          'bad': {'volumeLevel': 10},
        },
      );
      expect(readings, hasLength(2));
      final muted = readings.firstWhere((r) => r.userId == 'u1');
      expect(muted.band, MediaVolumeBand.muted);
      expect(muted.isFresh(now), isTrue);
      final clamped = readings.firstWhere((r) => r.userId == 'u2');
      expect(clamped.volumeLevel, 100);
      expect(clamped.band, MediaVolumeBand.ok);
    });

    test('treats readings older than 5 minutes as stale', () {
      final reading = MediaVolumeReading(
        userId: 'u1',
        groupId: 'g1',
        volumeLevel: 0,
        timestamp: now.subtract(const Duration(minutes: 5, seconds: 1)),
      );
      expect(reading.isFresh(now), isFalse);
      expect(
        reading.isFresh(now.subtract(const Duration(seconds: 2))),
        isTrue,
      );
    });
  });

  group('MediaVolumeFeedback', () {
    final now = DateTime.utc(2026, 8, 18, 12);
    const recipients = [
      MediaVolumeRecipient(userId: 'ada', displayName: 'Ada Lovelace'),
      MediaVolumeRecipient(userId: 'bob', displayName: 'Bob'),
    ];

    MediaVolumeReading reading({
      required String userId,
      required int volumeLevel,
      Duration age = Duration.zero,
    }) {
      return MediaVolumeReading(
        userId: userId,
        groupId: 'g1',
        volumeLevel: volumeLevel,
        timestamp: now.subtract(age),
      );
    }

    test('surfaces per-user warnings and never claims all-OK when muted', () {
      final feedback = MediaVolumeFeedback.fromReadings(
        readings: [
          reading(userId: 'ada', volumeLevel: 0),
          reading(userId: 'bob', volumeLevel: 80),
        ],
        recipients: recipients,
        now: now,
      );
      expect(feedback.hasWarnings, isTrue);
      expect(feedback.warnings, ['⚠️ Ada is muted']);
      expect(
        MediaVolumeFeedback.successMessage(
          recipientCount: 2,
          singleFirstName: 'Ada',
        ),
        'Everyone received the nudge \u2713',
      );
    });

    test('omits stale and missing readings instead of warning or claiming OK', () {
      final feedback = MediaVolumeFeedback.fromReadings(
        readings: [
          reading(
            userId: 'ada',
            volumeLevel: 0,
            age: const Duration(minutes: 6),
          ),
        ],
        recipients: recipients,
        now: now,
      );
      expect(feedback.hasWarnings, isFalse);
      expect(feedback.bandsByUserId, isEmpty);
      expect(
        MediaVolumeFeedback.successMessage(recipientCount: 2),
        'Everyone received the nudge \u2713',
      );
    });

    test('reports very-low and low bands together', () {
      final feedback = MediaVolumeFeedback.fromReadings(
        readings: [
          reading(userId: 'ada', volumeLevel: 10),
          reading(userId: 'bob', volumeLevel: 40),
        ],
        recipients: recipients,
        now: now,
      );
      expect(feedback.warnings, [
        "⚠️ Ada's volume is very low (<25%)",
        "⚠️ Bob's volume is low (<50%)",
      ]);
    });
  });
}
