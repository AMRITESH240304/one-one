import 'package:firebase_database/firebase_database.dart';

import '../../../core/firebase/app_database.dart';
import '../../../core/network/api_client.dart';
import '../models/group_invite_result.dart';
import '../models/group_member_summary.dart';
import '../models/group_summary.dart';

class GroupRepository {
  GroupRepository({ApiClient? apiClient, FirebaseDatabase? database})
    : _apiClient = apiClient ?? ApiClient(),
      _database = database ?? AppDatabase.instance();

  final ApiClient _apiClient;
  final FirebaseDatabase _database;

  Future<GroupSummary> createGroup(String name) async {
    final response = await _apiClient.postJson('/v1/groups', {'name': name});
    final groupId = response['groupId'].toString();
    final snapshot = await _database.ref('groups/$groupId').get();

    if (snapshot.value is Map<Object?, Object?>) {
      return GroupSummary.fromJson(
        groupId,
        snapshot.value! as Map<Object?, Object?>,
      );
    }

    return GroupSummary(
      groupId: groupId,
      name: name,
      ownerUserId: '',
      livekitRoomName: response['livekitRoomName'].toString(),
      groupState: 'active',
    );
  }

  Future<GroupInviteResult> createInvite(String groupId) async {
    final response = await _apiClient.postJson('/v1/groups/$groupId/invites', {
      'maxUses': 3,
      'expiresInHours': 72,
    });
    return GroupInviteResult.fromJson(response);
  }

  Future<String> joinInvite(String inviteCode) async {
    final response = await _apiClient.postJson('/v1/invites/join', {
      'inviteCode': inviteCode,
    });
    return response['groupId'].toString();
  }

  DatabaseReference userGroupsRef(String userId) {
    return _database.ref('userGroups/$userId');
  }

  Future<List<GroupSummary>> loadGroupsForUser(String _) async {
    final response = await _apiClient.getJson('/v1/groups');
    final rawGroups = response['groups'];
    if (rawGroups is! List) return const [];

    return rawGroups.whereType<Map>().map((raw) {
      final groupId = raw['groupId']?.toString() ?? '';
      return GroupSummary.fromJson(groupId, raw.cast<Object?, Object?>());
    }).where((group) => group.groupId.isNotEmpty).toList();
  }

  Future<List<GroupMemberSummary>> loadGroupMembers(String groupId) async {
    final response = await _apiClient.getJson(
      '/v1/groups/${Uri.encodeComponent(groupId)}/members',
    );
    final rawMembers = response['members'];
    if (rawMembers is! List) return const [];

    return rawMembers.whereType<Map>().map((raw) {
      return GroupMemberSummary(
        userId: raw['userId']?.toString() ?? '',
        displayName: raw['displayName']?.toString() ?? 'Member',
        role: raw['role']?.toString() ?? 'member',
        memberState: raw['memberState']?.toString() ?? 'active',
        profilePhotoUrl: raw['profilePhotoUrl']?.toString(),
        profilePhotoBase64: raw['profilePhotoBase64']?.toString(),
      );
    }).where((member) => member.userId.isNotEmpty).toList();
  }

  Future<int> countActiveMembers(String groupId) async {
    final snapshot = await _database.ref('groupMembers/$groupId').get();

    if (snapshot.value is! Map<Object?, Object?>) {
      return 0;
    }

    var count = 0;
    for (final entry in (snapshot.value! as Map<Object?, Object?>).entries) {
      final raw = entry.value;
      if (raw is! Map<Object?, Object?>) continue;
      if ((raw['memberState']?.toString() ?? 'active') == 'active') {
        count++;
      }
    }

    return count;
  }

  Future<void> removeMember(String groupId, String memberUserId) async {
    await _apiClient.deleteJson(
      '/v1/groups/${Uri.encodeComponent(groupId)}/members/'
      '${Uri.encodeComponent(memberUserId)}',
    );
  }

  Future<void> leaveGroup(String groupId) async {
    await _apiClient.postJson(
      '/v1/groups/${Uri.encodeComponent(groupId)}/leave',
      const {},
    );
  }

  Future<void> deleteGroup(String groupId) async {
    await _apiClient.deleteJson(
      '/v1/groups/${Uri.encodeComponent(groupId)}',
    );
  }
}
