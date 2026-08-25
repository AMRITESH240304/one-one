import 'package:one_one_app/one_one.dart';

/// Prefetched home-screen payload so the splash can stay up until the first
/// paint of [IdentityHomeScreen] is ready.
class IdentityHomeBootstrap {
  const IdentityHomeBootstrap({
    required this.groups,
    required this.selectedGroup,
    required this.members,
    required this.membersByGroupId,
    required this.carouselIndex,
    this.loadError,
  });

  final List<GroupSummary> groups;
  final GroupSummary? selectedGroup;
  final List<GroupMemberSummary> members;
  final Map<String, List<GroupMemberSummary>> membersByGroupId;
  final int carouselIndex;
  final String? loadError;

  bool get hasGroups => groups.isNotEmpty;

  static GroupSummary? resolveSelectedGroup(
    List<GroupSummary> groups, {
    String? preferredGroupId,
    GroupSummary? currentGroup,
  }) {
    if (groups.isEmpty) return null;

    if (preferredGroupId != null) {
      for (final group in groups) {
        if (group.groupId == preferredGroupId) return group;
      }
    }

    if (currentGroup == null) return groups.first;

    for (final group in groups) {
      if (group.groupId == currentGroup.groupId) return group;
    }

    return groups.first;
  }

  static Future<IdentityHomeBootstrap> fromGroups({
    required GroupRepository groupRepository,
    required List<GroupSummary> groups,
    String? preferredGroupId,
  }) async {
    if (groups.isEmpty) {
      return IdentityHomeBootstrap(
        groups: const [],
        selectedGroup: null,
        members: const [],
        membersByGroupId: {},
        carouselIndex: 0,
      );
    }

    try {
      final selected = resolveSelectedGroup(
        groups,
        preferredGroupId: preferredGroupId,
      );
      final selectedMembers = selected == null
          ? const <GroupMemberSummary>[]
          : await groupRepository.loadGroupMembers(selected.groupId);
      final membersByGroupId = selected == null
          ? <String, List<GroupMemberSummary>>{}
          : <String, List<GroupMemberSummary>>{
              selected.groupId: selectedMembers,
            };
      final carouselIndex = selected == null
          ? 0
          : groups.indexWhere((group) => group.groupId == selected.groupId);

      return IdentityHomeBootstrap(
        groups: groups,
        selectedGroup: selected,
        members: selectedMembers,
        membersByGroupId: membersByGroupId,
        carouselIndex: carouselIndex < 0 ? 0 : carouselIndex,
      );
    } catch (error) {
      final fallback = resolveSelectedGroup(
        groups,
        preferredGroupId: preferredGroupId,
      );
      return IdentityHomeBootstrap(
        groups: groups,
        selectedGroup: fallback,
        members: const [],
        membersByGroupId: {},
        carouselIndex: 0,
        loadError: LiveKitStatus.sanitizeError(error),
      );
    }
  }

  factory IdentityHomeBootstrap.failure(Object error) {
    return IdentityHomeBootstrap(
      groups: const [],
      selectedGroup: null,
      members: const [],
      membersByGroupId: {},
      carouselIndex: 0,
      loadError: LiveKitStatus.sanitizeError(error),
    );
  }

}
