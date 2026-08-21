import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/features/nudges/data/android_voice_nudge_bridge.dart';
import 'package:one_one_app/features/nudges/nudge_cooldowns.dart';
import 'package:one_one_app/features/nudges/nudge_status_memory.dart';

void main() {
  group('NudgeDeliveryFailure', () {
    test('classifies receiver-side permission and policy failures', () {
      for (final reason in [
        'permission_denied_notifications',
        'background_fg_service_blocked',
        'permission_denied_foreground_service',
        'timeout',
        'fcm_not_delivered',
        'app_force_stopped',
      ]) {
        expect(
          NudgeDeliveryFailure.isReceiverDeviceBlocked(reason),
          isTrue,
          reason: reason,
        );
      }
    });

    test('classifies Duo-side playback failures', () {
      for (final reason in [
        'playback_error',
        'playback_service_start_error',
        'download_error',
        'download_failed',
      ]) {
        final result = NudgeDeliveryResult(
          eventId: 'evt',
          status: 'failed',
          reason: reason,
        );
        expect(result.isReceiverDeviceBlocked, isFalse, reason: reason);
        expect(result.isDuoBug, isTrue, reason: reason);
      }
    });

    test('timeout on device is a lock, not a Duo bug', () {
      const result = NudgeDeliveryResult(
        eventId: 'evt',
        status: 'failed',
        reason: 'timeout',
      );
      expect(result.isReceiverDeviceBlocked, isTrue);
      expect(result.isDuoBug, isFalse);
    });
  });

  group('LastNudgeRecipientSignifier persistence (B1)', () {
    late NudgeStatusMemory memory;

    setUp(() {
      memory = NudgeStatusMemory.instance;
      memory.clear('group-a');
    });

    tearDown(() {
      memory.clear('group-a');
    });

    test('reopen keeps lock when deviceBlocked + failureReason are stored', () {
      memory.record(
        'group-a',
        LastNudgeState(
          eventId: 'evt-1',
          status: LastNudgeStatus.failed,
          message: 'failed',
          at: DateTime.now(),
          kind: NudgeKind.ring,
          signifiers: const [
            LastNudgeRecipientSignifier(
              userId: 'u1',
              displayName: 'Ada',
              failed: true,
              deviceBlocked: true,
              failureReason: 'battery_optimization_active',
            ),
            LastNudgeRecipientSignifier(
              userId: 'u2',
              displayName: 'Bob',
              failed: true,
              deviceBlocked: false,
              failureReason: 'playback_error',
            ),
          ],
        ),
      );

      final restored = memory.forGroup('group-a')!;
      expect(restored.signifiers[0].deviceBlocked, isTrue);
      expect(restored.signifiers[0].failureReason, 'battery_optimization_active');
      expect(restored.signifiers[1].deviceBlocked, isFalse);
      expect(restored.signifiers[1].failureReason, 'playback_error');

      // Mimic sheet restore classification.
      final lockResult = NudgeDeliveryResult(
        eventId: restored.eventId,
        status: 'failed',
        reason: restored.signifiers[0].failureReason,
      );
      final skullResult = NudgeDeliveryResult(
        eventId: restored.eventId,
        status: 'failed',
        reason: restored.signifiers[1].failureReason,
      );
      expect(lockResult.isReceiverDeviceBlocked, isTrue);
      expect(skullResult.isReceiverDeviceBlocked, isFalse);
      expect(skullResult.isDuoBug, isTrue);
    });

    test('decline/snooze reply preserves deviceBlocked', () {
      memory.record(
        'group-a',
        LastNudgeState(
          eventId: 'evt-2',
          status: LastNudgeStatus.failed,
          message: 'failed',
          at: DateTime.now(),
          kind: NudgeKind.voice,
          signifiers: const [
            LastNudgeRecipientSignifier(
              userId: 'u1',
              displayName: 'Ada',
              failed: true,
              deviceBlocked: true,
              failureReason: 'timeout',
            ),
          ],
        ),
      );

      final updated = memory.applyRecipientResponse(
        eventId: 'evt-2',
        groupId: 'group-a',
        responderUserId: 'u1',
        responderName: 'Ada',
        action: 'decline',
      );
      expect(updated, isTrue);

      final signifier = memory.forGroup('group-a')!.signifiers.single;
      expect(signifier.reply, NudgeRecipientReply.declined);
      expect(signifier.deviceBlocked, isTrue);
      expect(signifier.failureReason, 'timeout');
      expect(signifier.failed, isTrue);
    });
  });
}
