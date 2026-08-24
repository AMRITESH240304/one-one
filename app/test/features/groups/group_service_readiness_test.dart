import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  const owner = GroupMemberSummary(
    userId: 'owner',
    displayName: 'Owner',
    role: 'owner',
    memberState: 'active',
  );

  test('service is unavailable to a group owner alone', () {
    expect(
      groupHasServicePeer(members: const [owner], currentUserId: 'owner'),
      isFalse,
    );
  });

  test('service becomes available when another active member joins', () {
    const friend = GroupMemberSummary(
      userId: 'friend',
      displayName: 'Friend',
      role: 'member',
      memberState: 'active',
    );

    expect(
      groupHasServicePeer(
        members: const [owner, friend],
        currentUserId: 'owner',
      ),
      isTrue,
    );
  });

  test('inactive members do not enable service', () {
    const inactiveFriend = GroupMemberSummary(
      userId: 'friend',
      displayName: 'Friend',
      role: 'member',
      memberState: 'removed',
    );

    expect(
      groupHasServicePeer(
        members: const [owner, inactiveFriend],
        currentUserId: 'owner',
      ),
      isFalse,
    );
  });

  test('nudge is shown only while an active friend is offline', () {
    const friend = GroupMemberSummary(
      userId: 'friend',
      displayName: 'Friend',
      role: 'member',
      memberState: 'active',
    );
    const members = [owner, friend];

    expect(
      groupNeedsNudge(
        members: members,
        currentUserId: 'owner',
        availability: const {},
      ),
      isTrue,
    );
    expect(
      groupNeedsNudge(
        members: members,
        currentUserId: 'owner',
        availability: const {
          'friend': MemberAvailability(
            desiredState: 'online',
            effectiveState: 'live',
            canReceiveLiveAudio: true,
          ),
        },
      ),
      isFalse,
    );
  });

  test('unchanged membership snapshots do not trigger a reload', () {
    const friend = GroupMemberSummary(
      userId: 'friend',
      displayName: 'Friend',
      role: 'member',
      memberState: 'active',
    );
    const members = [owner, friend];
    final unchanged = {
      'owner': {'role': 'owner', 'memberState': 'active'},
      'friend': {'role': 'member', 'memberState': 'active'},
    };
    final changed = {
      'owner': {'role': 'owner', 'memberState': 'active'},
      'friend': {'role': 'member', 'memberState': 'removed'},
    };
    // Historical removed rows must not invalidate an otherwise-matching active set.
    final withHistoricalRemoved = {
      'owner': {'role': 'owner', 'memberState': 'active'},
      'friend': {'role': 'member', 'memberState': 'active'},
      'ex': {'role': 'member', 'memberState': 'removed'},
    };

    expect(
      groupMembershipMatchesSnapshot(
        members: members,
        snapshotValue: unchanged,
      ),
      isTrue,
    );
    expect(
      groupMembershipMatchesSnapshot(
        members: members,
        snapshotValue: changed,
      ),
      isFalse,
    );
    expect(
      groupMembershipMatchesSnapshot(
        members: members,
        snapshotValue: withHistoricalRemoved,
      ),
      isTrue,
    );
  });
}
