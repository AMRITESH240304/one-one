import 'package:one_one_app/one_one.dart';

bool groupHasServicePeer({
  required List<GroupMemberSummary> members,
  required String currentUserId,
}) {
  return members.any(
    (member) =>
        member.userId != currentUserId && member.memberState == 'active',
  );
}

bool groupNeedsNudge({
  required List<GroupMemberSummary> members,
  required String currentUserId,
  required Map<String, MemberAvailability> availability,
}) {
  return members.any(
    (member) =>
        member.userId != currentUserId &&
        member.memberState == 'active' &&
        !(availability[member.userId]?.isLive ?? false),
  );
}

bool groupMembershipMatchesSnapshot({
  required List<GroupMemberSummary> members,
  required Object? snapshotValue,
}) {
  if (snapshotValue is! Map<Object?, Object?>) return members.isEmpty;

  // Ignore removed/left rows so historical membership does not force reloads.
  // Active rows whose users/{uid} was deleted (account deletion ghosts) still
  // make the active set larger than [members] until purge removes them — that
  // mismatch correctly triggers a refresh, and loadGroupMembers keeps filtering
  // them out of the UI.
  final activeByUserId = <String, Map<Object?, Object?>>{};
  for (final entry in snapshotValue.entries) {
    final raw = entry.value;
    if (raw is! Map<Object?, Object?>) continue;
    if ((raw['memberState']?.toString() ?? 'active') != 'active') continue;
    activeByUserId[entry.key.toString()] = raw;
  }

  if (activeByUserId.length != members.length) return false;

  final currentByUserId = {for (final member in members) member.userId: member};
  for (final entry in activeByUserId.entries) {
    final current = currentByUserId[entry.key];
    final raw = entry.value;
    if (current == null ||
        (raw['role']?.toString() ?? 'member') != current.role ||
        (raw['memberState']?.toString() ?? 'active') != current.memberState) {
      return false;
    }
  }
  return true;
}
