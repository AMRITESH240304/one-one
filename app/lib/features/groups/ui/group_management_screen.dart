import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../../../core/firebase/app_database.dart';
import '../../identity/ui/profile_avatar.dart';
import '../data/group_repository.dart';
import '../models/group_member_summary.dart';
import '../models/group_summary.dart';

enum GroupManagementOutcome { membershipEnded, groupDeleted }

class GroupManagementScreen extends StatefulWidget {
  const GroupManagementScreen({
    super.key,
    required this.group,
    required this.currentUserId,
    required this.onInvite,
  });

  final GroupSummary group;
  final String currentUserId;
  final Future<void> Function() onInvite;

  @override
  State<GroupManagementScreen> createState() => _GroupManagementScreenState();
}

class _GroupManagementScreenState extends State<GroupManagementScreen> {
  final GroupRepository _repository = GroupRepository();
  StreamSubscription<DatabaseEvent>? _membersSubscription;
  List<GroupMemberSummary> _members = const [];
  bool _loading = true;
  bool _busy = false;

  bool get _isOwner => widget.group.ownerUserId == widget.currentUserId;

  @override
  void initState() {
    super.initState();
    _membersSubscription = AppDatabase.instance()
        .ref('groupMembers/${widget.group.groupId}')
        .onValue
        .listen((_) => unawaited(_loadMembers()));
  }

  @override
  void dispose() {
    unawaited(_membersSubscription?.cancel());
    super.dispose();
  }

  Future<void> _loadMembers() async {
    try {
      final members = await _repository.loadGroupMembers(widget.group.groupId);
      if (!mounted) return;
      if (members.every((member) => member.userId != widget.currentUserId) &&
          !_busy) {
        Navigator.of(context).pop(GroupManagementOutcome.membershipEnded);
        return;
      }
      setState(() {
        _members = members;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<bool> _confirm({
    required String title,
    String? message,
    required String action,
  }) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: message == null ? null : Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xffb3261e),
                  foregroundColor: Colors.white,
                ),
                child: Text(action),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _remove(GroupMemberSummary member) async {
    final confirmed = await _confirm(
      title: 'Remove ${member.displayName} from this group?',
      action: 'Remove',
    );
    if (!confirmed || !mounted) return;
    final succeeded = await _run(
      () => _repository.removeMember(widget.group.groupId, member.userId),
    );
    // Don't rely solely on the RTDB listener — force a fresh member list so
    // the removed row disappears even if the realtime event is delayed.
    if (succeeded && mounted) await _loadMembers();
  }

  Future<void> _invite() async {
    await _run(widget.onInvite);
  }

  Future<void> _leave() async {
    final confirmed = await _confirm(
      title: 'Leave this group?',
      action: 'Leave',
    );
    if (!confirmed || !mounted) return;
    final succeeded = await _run(() => _repository.leaveGroup(widget.group.groupId));
    if (succeeded && mounted) {
      Navigator.of(context).pop(GroupManagementOutcome.membershipEnded);
    }
  }

  Future<void> _delete() async {
    final confirmed = await _confirm(
      title: 'Delete this group permanently?',
      message: 'This action cannot be undone.',
      action: 'Delete',
    );
    if (!confirmed || !mounted) return;
    final succeeded = await _run(() => _repository.deleteGroup(widget.group.groupId));
    if (succeeded && mounted) {
      Navigator.of(context).pop(GroupManagementOutcome.groupDeleted);
    }
  }

  Future<bool> _run(Future<void> Function() action) async {
    if (_busy) return false;
    setState(() => _busy = true);
    try {
      await action();
      return true;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xff101010),
      appBar: AppBar(
        title: const Text('Group Management'),
        backgroundColor: const Color(0xff101010),
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: [
            Text(
              widget.group.name,
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _isOwner ? 'You own this group.' : 'You are a member.',
              style: const TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 28),
            const _SectionTitle('Group members'),
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xff1b1b1b),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(28),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : Column(
                      children: [
                        for (var index = 0; index < _members.length; index++) ...[
                          _MemberRow(
                            member: _members[index],
                            isCurrentUser:
                                _members[index].userId == widget.currentUserId,
                            onRemove:
                                _isOwner &&
                                    _members[index].role != 'owner' &&
                                    !_busy
                                ? () => _remove(_members[index])
                                : null,
                          ),
                          if (index != _members.length - 1)
                            const Divider(height: 1, indent: 68),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 28),
            const _SectionTitle('Actions'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _invite,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Invite Members'),
            ),
            const SizedBox(height: 12),
            if (_isOwner)
              OutlinedButton.icon(
                onPressed: _busy ? null : _delete,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  foregroundColor: const Color(0xffff8a80),
                  side: const BorderSide(color: Color(0x66ff8a80)),
                ),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Delete Group'),
              )
            else
              OutlinedButton.icon(
                onPressed: _busy ? null : _leave,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  foregroundColor: const Color(0xffff8a80),
                  side: const BorderSide(color: Color(0x66ff8a80)),
                ),
                icon: const Icon(Icons.logout),
                label: const Text('Leave Group'),
              ),
            if (_isOwner) ...[
              const SizedBox(height: 12),
              const Text(
                'Owners cannot leave. Delete the group instead. Ownership transfer can be added later.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    required this.member,
    required this.isCurrentUser,
    required this.onRemove,
  });

  final GroupMemberSummary member;
  final bool isCurrentUser;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minVerticalPadding: 10,
      leading: ProfileAvatar(
        profilePhotoUrl: member.profilePhotoUrl,
        profilePhotoBase64: member.profilePhotoBase64,
        radius: 22,
        backgroundColor: const Color(0xff2b2b2b),
      ),
      title: Text(
        '${member.displayName}${isCurrentUser ? ' (you)' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white),
      ),
      subtitle: member.role == 'owner'
          ? const Text('Owner', style: TextStyle(color: Colors.white54))
          : null,
      trailing: onRemove == null
          ? null
          : IconButton(
              tooltip: 'Remove ${member.displayName}',
              onPressed: onRemove,
              icon: const Icon(Icons.person_remove_outlined),
              color: const Color(0xffff8a80),
            ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        color: Colors.white54,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}
