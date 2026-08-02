import '../online/models/member_availability.dart';
import 'models/group_member_summary.dart';

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
  if (snapshotValue.length != members.length) return false;

  final currentByUserId = {for (final member in members) member.userId: member};
  for (final entry in snapshotValue.entries) {
    final raw = entry.value;
    final current = currentByUserId[entry.key.toString()];
    if (raw is! Map<Object?, Object?> ||
        current == null ||
        (raw['role']?.toString() ?? 'member') != current.role ||
        (raw['memberState']?.toString() ?? 'active') != current.memberState) {
      return false;
    }
  }
  return true;
}
