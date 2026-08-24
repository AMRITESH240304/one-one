import 'package:one_one_app/one_one.dart';

enum GroupManagementOutcome { membershipEnded, groupDeleted }

class GroupManagementScreen extends StatefulWidget {
  const GroupManagementScreen({
    super.key,
    required this.group,
    required this.currentUserId,
    required this.initialMembers,
    required this.onInvite,
  });

  final GroupSummary group;
  final String currentUserId;
  final List<GroupMemberSummary> initialMembers;
  final Future<void> Function() onInvite;

  @override
  State<GroupManagementScreen> createState() => _GroupManagementScreenState();
}

class _GroupManagementScreenState extends State<GroupManagementScreen> {
  final GroupRepository _repository = GroupRepository();
  StreamSubscription<DatabaseEvent>? _membersSubscription;
  late List<GroupMemberSummary> _members;
  bool _busy = false;
  String? _removingUserId;

  bool get _isOwner => widget.group.ownerUserId == widget.currentUserId;

  @override
  void initState() {
    super.initState();
    // Home already loaded these — don't hit the members API again on open.
    _members = List<GroupMemberSummary>.unmodifiable(
      widget.initialMembers
          .where((member) => member.memberState == 'active')
          .toList(growable: false),
    );
    _membersSubscription = AppDatabase.instance()
        .ref('groupMembers/${widget.group.groupId}')
        .onValue
        .listen(_onMembersSnapshot);
  }

  @override
  void dispose() {
    unawaited(_membersSubscription?.cancel());
    super.dispose();
  }

  /// Sync local rows from RTDB without an API round-trip — drop anyone who
  /// is no longer active, and leave if we ourselves were removed.
  void _onMembersSnapshot(DatabaseEvent event) {
    if (!mounted || _busy) return;

    final activeIds = _activeMemberIds(event.snapshot.value);
    if (!activeIds.contains(widget.currentUserId)) {
      Navigator.of(context).pop(GroupManagementOutcome.membershipEnded);
      return;
    }

    final next = _members
        .where((member) => activeIds.contains(member.userId))
        .toList(growable: false);
    if (next.length == _members.length &&
        next.every(
          (member) => _members.any((m) => m.userId == member.userId),
        )) {
      return;
    }
    setState(() => _members = next);
  }

  Set<String> _activeMemberIds(Object? snapshotValue) {
    if (snapshotValue is! Map<Object?, Object?>) return {};
    final ids = <String>{};
    for (final entry in snapshotValue.entries) {
      final raw = entry.value;
      if (raw is! Map<Object?, Object?>) continue;
      if ((raw['memberState']?.toString() ?? 'active') != 'active') continue;
      ids.add(entry.key.toString());
    }
    return ids;
  }

  Future<bool> _confirm({
    required String title,
    String? message,
    required String action,
  }) async {
    return await showDialog<bool>(
          context: context,
          barrierColor: Colors.black87,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: const Color(0xff1b1b1b),
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            content: message == null
                ? null
                : Text(
                    message,
                    style: const TextStyle(color: Colors.white70, height: 1.4),
                  ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                style: TextButton.styleFrom(foregroundColor: Colors.white70),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xffb3261e),
                  foregroundColor: Colors.white,
                  minimumSize: const Size(96, 44),
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
      title: 'Remove ${member.displayName}?',
      message: 'They will lose access to this group immediately.',
      action: 'Remove',
    );
    if (!confirmed || !mounted) return;

    setState(() {
      _busy = true;
      _removingUserId = member.userId;
    });
    try {
      await _repository.removeMember(widget.group.groupId, member.userId);
      if (!mounted) return;
      setState(() {
        _members = _members
            .where((item) => item.userId != member.userId)
            .toList(growable: false);
      });
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _removingUserId = null;
        });
      }
    }
  }

  Future<void> _invite() async {
    await _run(widget.onInvite);
  }

  Future<void> _leave() async {
    final confirmed = await _confirm(
      title: 'Leave this group?',
      message: 'You can rejoin later with a new invite.',
      action: 'Leave',
    );
    if (!confirmed || !mounted) return;
    final succeeded = await _run(
      () => _repository.leaveGroup(widget.group.groupId),
    );
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
    final succeeded = await _run(
      () => _repository.deleteGroup(widget.group.groupId),
    );
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final removing = _removingUserId != null;

    return Stack(
      children: [
        Scaffold(
          backgroundColor: const Color(0xff101010),
          appBar: AppBar(
            title: const Text('Group Management'),
            backgroundColor: const Color(0xff101010),
            foregroundColor: Colors.white,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
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
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.09),
                    ),
                  ),
                  child: _members.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.all(28),
                          child: Center(
                            child: Text(
                              'No members yet.',
                              style: TextStyle(color: Colors.white54),
                            ),
                          ),
                        )
                      : Column(
                          children: [
                            for (
                              var index = 0;
                              index < _members.length;
                              index++
                            ) ...[
                              _MemberRow(
                                key: ValueKey(_members[index].userId),
                                member: _members[index],
                                isCurrentUser:
                                    _members[index].userId ==
                                    widget.currentUserId,
                                removing:
                                    _removingUserId == _members[index].userId,
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
        ),
        if (removing)
          const Positioned.fill(
            child: ModalBarrier(dismissible: false, color: Color(0x88000000)),
          ),
        if (removing)
          const Center(
            child: SizedBox.square(
              dimension: 36,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: Colors.white,
              ),
            ),
          ),
      ],
    );
  }
}

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.member,
    required this.isCurrentUser,
    required this.removing,
    required this.onRemove,
  });

  final GroupMemberSummary member;
  final bool isCurrentUser;
  final bool removing;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minVerticalPadding: 10,
      leading: ProfileAvatar(
        profilePhotoUrl: member.profilePhotoUrl,
        profilePhotoBase64: member.profilePhotoBase64,
        avatarAsset: member.avatarAsset,
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
      trailing: removing
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : onRemove == null
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
