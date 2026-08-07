import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:livekit_client/livekit_client.dart';

import '../../../app/accent_theme.dart';
import '../../../app/startup_performance.dart';
import '../../../core/firebase/app_database.dart';
import '../../../core/firebase/crashlytics_service.dart';
import '../../../core/firebase/firebase_analytics_service.dart';
import '../../../core/network/api_client.dart';
import '../../chat/data/chat_message_repository.dart';
import '../../chat/models/group_chat_message.dart';
import '../../chat/ui/chat_bubble_bar.dart';
import '../../chat/ui/chat_bubble_feed.dart';
import '../../groups/data/group_repository.dart';
import '../../groups/data/invite_link_bridge.dart';
import '../../groups/group_service_readiness.dart';
import '../../groups/models/group_invite_result.dart';
import '../../groups/models/group_member_summary.dart';
import '../../groups/models/group_summary.dart';
import '../../groups/ui/group_management_screen.dart';
import '../../online/data/online_repository.dart';
import '../../online/livekit_status.dart';
import '../../online/models/member_availability.dart';
import '../../online/models/online_session.dart';
import '../../online/presence_config.dart';
import '../../online/voice_pip_bridge.dart';
import '../../nudges/data/android_voice_nudge_bridge.dart';
import '../../nudges/data/nudge_repository.dart';
import '../../nudges/ui/nudge_screen.dart';
import '../../talk/data/talk_repository.dart';
import '../../talk/models/talk_session.dart';
import '../../talk/talk_feedback.dart';
import '../data/identity_home_bootstrap.dart';
import '../data/identity_repository.dart';
import '../models/identity_session.dart';
import 'group_action_screen.dart';
import 'no_groups_screen.dart';
import 'profile_avatar.dart';
import 'settings_screen.dart';

class IdentityHomeScreen extends StatefulWidget {
  const IdentityHomeScreen({
    super.key,
    required this.initialSession,
    required this.identityRepository,
    this.initialGroupId,
    this.initialBootstrap,
  });

  final IdentitySession initialSession;
  final IdentityRepository identityRepository;
  final String? initialGroupId;
  final IdentityHomeBootstrap? initialBootstrap;

  @override
  State<IdentityHomeScreen> createState() => _IdentityHomeScreenState();
}

class _IdentityHomeScreenState extends State<IdentityHomeScreen>
    with WidgetsBindingObserver {
  final GroupRepository _groupRepository = GroupRepository();
  final OnlineRepository _onlineRepository = OnlineRepository();
  final TalkRepository _talkRepository = TalkRepository();
  final AndroidVoiceNudgeBridge _nudgeActionBridge = AndroidVoiceNudgeBridge();
  final NudgeRepository _nudgeRepository = NudgeRepository();
  final ChatMessageRepository _chatMessageRepository = ChatMessageRepository();
  final InviteLinkBridge _inviteLinkBridge = InviteLinkBridge();
  final VoicePipBridge _voicePipBridge = VoicePipBridge();

  late IdentitySession _session;
  List<GroupSummary> _groups = const [];
  List<GroupMemberSummary> _members = const [];
  Map<String, List<GroupMemberSummary>> _membersByGroupId = const {};
  Map<String, MemberAvailability> _availability = const {};
  Set<String> _speakingUserIds = const {};
  List<GroupChatMessage> _chatMessages = const [];
  StreamSubscription<DatabaseEvent>? _chatMessagesSubscription;
  GroupSummary? _selectedGroup;
  StreamSubscription<DatabaseEvent>? _availabilitySubscription;
  Timer? _availabilityExpiryTimer;
  StreamSubscription<DatabaseEvent>? _membersSubscription;
  StreamSubscription<DatabaseEvent>? _userGroupsSubscription;
  Set<String>? _pendingUserGroupIds;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  StreamSubscription<void>? _nudgeActionSubscription;
  StreamSubscription<void>? _registrationRenewalSubscription;
  StreamSubscription<void>? _inviteLinkSubscription;
  StreamSubscription<VoicePipAction>? _voicePipActionSubscription;

  OnlineSession? _onlineSession;
  TalkSession? _talkSession;
  Room? _room;
  EventsListener<RoomEvent>? _roomListener;
  Timer? _heartbeatTimer;

  // Automatic-offline-on-disconnect (with grace period) bookkeeping. See
  // _evaluatePeerPresenceForAutoOffline for the state machine.
  bool _peerWasLiveWithMe = false;
  Timer? _peerDisconnectGraceTimer;

  // Inactivity timeout: if nobody speaks for the configured duration while
  // the room is active, the session auto-closes to prevent runaway costs.
  DateTime? _lastVoiceActivityAt;
  Timer? _inactivityTimer;

  // Daily usage tracker: prevents runaway sessions (e.g. phone left on in a
  // crowd). Accumulates online seconds and caps at 120 min / user / day.
  int _todayOnlineSeconds = 0;
  String? _todayUsageDateKey;
  Timer? _usagePersistTimer; // Flushes accumulated seconds to RTDB every 30 s.

  int _carouselIndex = 0;

  bool _loadingGroups = true;
  bool _busy = false;
  bool _talkBusy = false;
  bool _talkPressed = false;
  // Per-user connection style for the *local* user's own connection — never
  // a group-wide mode. Defaults to walkie-talkie; see _toggleConnectionMode
  // and the startInCallMode logic in _goOnline for how it changes.
  String _connectionMode = MemberAvailability.walkieTalkieMode;
  bool _connectionModeBusy = false;
  // Caps continuous call mode at PresenceConfig.callModeTimeout; cancelled
  // whenever the local user leaves call mode (manual toggle, go-away, etc.).
  Timer? _callModeTimeoutTimer;
  String _state = 'away';
  String? _message;
  ConnectionQuality _localConnectionQuality = ConnectionQuality.unknown;
  Map<String, ConnectionQuality> _remoteConnectionQualityByUserId = const {};
  List<ConnectivityResult> _connectivity = const [];
  bool _registrationRefreshInFlight = false;
  DateTime? _lastRegistrationRefreshAt;
  NudgeNotificationAction? _deferredNudgeAction;
  bool _nudgeActionInFlight = false;
  bool _inviteJoinInFlight = false;
  bool _connectionCleanupInFlight = false;
  bool _hasAvailabilitySnapshot = false;
  String? _lastPeerLossUserId;
  DateTime? _lastPeerLossAt;
  bool _inPictureInPicture = false;
  String? _preferredGroupId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _session =
        widget.identityRepository.currentSession ?? widget.initialSession;
    _preferredGroupId = widget.initialGroupId;
    widget.identityRepository.sessionListenable.addListener(
      _onIdentitySessionChanged,
    );
    AccentThemeController.setAccentKey(_session.settings.accentColorKey);
    unawaited(
      AnalyticsService.logScreenView(
        screenName: 'identity_home',
        screenClass: 'IdentityHomeScreen',
      ),
    );
    _nudgeActionSubscription = AndroidVoiceNudgeBridge.actionSignals.listen((
      _,
    ) {
      unawaited(_takePendingNudgeAction());
    });
    _registrationRenewalSubscription = AndroidVoiceNudgeBridge
        .registrationSignals
        .listen((_) {
          unawaited(_refreshDeviceRegistration(force: true));
        });
    _inviteLinkSubscription = InviteLinkBridge.linkSignals.listen((_) {
      unawaited(_takePendingInviteLink());
    });
    _voicePipBridge.isInPictureInPicture.addListener(_onPipModeChanged);
    _voicePipActionSubscription = _voicePipBridge.actions.listen(
      (action) => unawaited(_handlePipAction(action)),
    );
    unawaited(_startConnectivityMonitoring());
    final bootstrap = widget.initialBootstrap;
    if (bootstrap != null) {
      _applyBootstrap(bootstrap);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        logStartupMilestone('Home visible');
        logStartupMilestone('Home data interactive');
        unawaited(_takePendingNudgeAction());
        unawaited(_takePendingInviteLink());
      });
    } else {
      unawaited(_loadGroups());
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => logStartupMilestone('Home visible'),
      );
    }
  }

  void _applyBootstrap(IdentityHomeBootstrap bootstrap) {
    _groups = bootstrap.groups;
    _selectedGroup = bootstrap.selectedGroup;
    _members = bootstrap.members;
    _membersByGroupId = bootstrap.membersByGroupId;
    _carouselIndex = bootstrap.carouselIndex;
    _loadingGroups = false;
    _message = bootstrap.loadError;

    _userGroupsSubscription = _groupRepository
        .userGroupsRef(_session.userId)
        .onValue
        .listen((event) => unawaited(_handleUserGroupsChanged(event)));

    final selected = _selectedGroup;
    if (selected != null) {
      _listenToMembers(selected.groupId);
      _listenToAvailability(selected.groupId);
      _listenToChatMessages(selected.groupId);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.identityRepository.sessionListenable.removeListener(
      _onIdentitySessionChanged,
    );
    _availabilitySubscription?.cancel();
    _availabilityExpiryTimer?.cancel();
    _membersSubscription?.cancel();
    _chatMessagesSubscription?.cancel();
    _userGroupsSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _nudgeActionSubscription?.cancel();
    _registrationRenewalSubscription?.cancel();
    _inviteLinkSubscription?.cancel();
    _voicePipActionSubscription?.cancel();
    _voicePipBridge.isInPictureInPicture.removeListener(_onPipModeChanged);
    unawaited(_voicePipBridge.setSessionState(active: false, isTalking: false));
    unawaited(_voicePipBridge.dispose());
    _heartbeatTimer?.cancel();
    _peerDisconnectGraceTimer?.cancel();
    _inactivityTimer?.cancel();
    _callModeTimeoutTimer?.cancel();
    _usagePersistTimer?.cancel();
    // Persist final usage before disposal.
    if (_todayOnlineSeconds > 0 && _onlineSession != null) {
      unawaited(_persistDailyUsage(_onlineSession!.groupId));
    }
    final activeTalk = _talkSession;
    if (activeTalk != null) {
      unawaited(_talkRepository.stopTalk(activeTalk, reason: 'screen_closed'));
    }
    unawaited(_disconnectLiveKit());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshDeviceRegistration());
      unawaited(_takePendingNudgeAction());
      unawaited(_takePendingInviteLink());
    }
  }

  void _onPipModeChanged() {
    if (!mounted) return;
    setState(() {
      _inPictureInPicture = _voicePipBridge.isInPictureInPicture.value;
    });
  }

  Future<void> _handlePipAction(VoicePipAction action) async {
    if (_onlineSession == null) return;
    switch (action) {
      case VoicePipAction.toggleMicrophone:
        // Call mode's mic is always on by design — the PiP quick-action is
        // only meaningful for the walkie-talkie push-to-talk lock.
        if (_isCallMode) return;
        if (_talkSession == null) {
          await _startTalking();
        } else {
          await _stopTalking(reason: 'pip_toggle');
        }
        return;
    }
  }

  void _syncPipSessionState() {
    unawaited(
      _voicePipBridge.setSessionState(
        active: _onlineSession != null,
        isTalking: _talkSession != null || _isCallMode,
      ),
    );
  }

  Future<void> _refreshDeviceRegistration({bool force = false}) async {
    final lastRefresh = _lastRegistrationRefreshAt;
    if (_registrationRefreshInFlight ||
        (!force &&
            lastRefresh != null &&
            DateTime.now().difference(lastRefresh) <
                const Duration(seconds: 30))) {
      return;
    }
    _registrationRefreshInFlight = true;
    try {
      await widget.identityRepository.ensureIdentity();
      _lastRegistrationRefreshAt = DateTime.now();
    } catch (error, stack) {
      debugPrint(
        '[OneOneFCM][DART-E5] Resume-time device registration refresh failed: $error',
      );
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'device_registration_refresh_failed',
        ),
      );
    } finally {
      _registrationRefreshInFlight = false;
    }
  }

  void _onIdentitySessionChanged() {
    final next = widget.identityRepository.currentSession;
    if (!mounted || next == null || next.userId != _session.userId) return;
    final audioRouteChanged =
        next.settings.audioOutputPreference !=
        _session.settings.audioOutputPreference;
    setState(() => _session = next);
    AccentThemeController.setAccentKey(next.settings.accentColorKey);
    if (audioRouteChanged) unawaited(_applyPreferredAudioRoute());
  }

  Future<void> _startConnectivityMonitoring() async {
    final connectivity = Connectivity();
    try {
      final current = await connectivity.checkConnectivity();
      _handleConnectivityChanged(current);
    } catch (_) {
      // LiveKit connection quality remains the primary signal.
    }
    _connectivitySubscription = connectivity.onConnectivityChanged.listen((
      results,
    ) {
      _handleConnectivityChanged(results);
    });
  }

  void _handleConnectivityChanged(List<ConnectivityResult> results) {
    if (!mounted) return;
    setState(() => _connectivity = results);
    if (results.contains(ConnectivityResult.none) && _isOnline) {
      unawaited(
        _handleConnectionLoss('You were marked Away due to network loss.'),
      );
    }
  }

  Future<void> _loadGroups() async {
    final stopwatch = Stopwatch()..start();
    setState(() => _loadingGroups = true);
    try {
      final groups = await _groupRepository.loadGroupsForUser(_session.userId);
      logStartupMilestone('groups loaded', stopwatch);
      if (!mounted) return;
      _userGroupsSubscription ??= _groupRepository
          .userGroupsRef(_session.userId)
          .onValue
          .listen((event) => unawaited(_handleUserGroupsChanged(event)));

      if (groups.isEmpty && (ModalRoute.of(context)?.isCurrent ?? true)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          unawaited(_replaceWithNoGroups());
        });
        return;
      }

      final selected = IdentityHomeBootstrap.resolveSelectedGroup(
        groups,
        preferredGroupId: _preferredGroupId,
        currentGroup: _selectedGroup,
      );
      final selectedMembers = selected == null
          ? const <GroupMemberSummary>[]
          : await _groupRepository.loadGroupMembers(selected.groupId);
      final membersByGroupId = selected == null
          ? const <String, List<GroupMemberSummary>>{}
          : <String, List<GroupMemberSummary>>{
              selected.groupId: selectedMembers,
            };
      logStartupMilestone('selected group members loaded', stopwatch);

      if (!mounted) return;
      setState(() {
        _groups = groups;
        _selectedGroup = selected;
        _membersByGroupId = membersByGroupId;
        _members = selected == null
            ? const []
            : membersByGroupId[selected.groupId] ?? const [];
        if (selected == null) {
          _availability = const {};
          _chatMessages = const [];
        }
      });
      if (selected != null) {
        unawaited(
          _precacheGroupMemberPhotos(
            membersByGroupId[selected.groupId] ?? const [],
          ),
        );
      }
      _syncCarouselToSelectedGroup();

      if (selected != null) {
        _listenToMembers(selected.groupId);
        _listenToAvailability(selected.groupId);
        _listenToChatMessages(selected.groupId);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = LiveKitStatus.sanitizeError(error));
    } finally {
      if (mounted && _loadingGroups) {
        setState(() => _loadingGroups = false);
        logStartupMilestone('Home data interactive', stopwatch);
        unawaited(_takePendingNudgeAction());
        unawaited(_takePendingInviteLink());
        final pendingGroupIds = _pendingUserGroupIds;
        _pendingUserGroupIds = null;
        if (pendingGroupIds != null) {
          unawaited(_handleIndexedGroupsChanged(pendingGroupIds));
        }
      }
    }
  }

  Future<void> _handleUserGroupsChanged(DatabaseEvent event) async {
    if (!mounted) return;
    final value = event.snapshot.value;
    final indexedGroupIds = value is Map<Object?, Object?>
        ? value.keys.map((key) => key.toString()).toSet()
        : <String>{};
    if (_loadingGroups) {
      _pendingUserGroupIds = indexedGroupIds;
      return;
    }
    await _handleIndexedGroupsChanged(indexedGroupIds);
  }

  Future<void> _handleIndexedGroupsChanged(Set<String> indexedGroupIds) async {
    if (!mounted) return;
    final loadedGroupIds = _groups.map((group) => group.groupId).toSet();
    if (indexedGroupIds.length == loadedGroupIds.length &&
        indexedGroupIds.containsAll(loadedGroupIds)) {
      return;
    }

    final activeGroupId = _onlineSession?.groupId;
    if (activeGroupId != null && !indexedGroupIds.contains(activeGroupId)) {
      await _endRevokedVoiceSession(activeGroupId);
    }
    if (!mounted) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    if (!mounted) return;
    await _loadGroups();
    if (mounted && indexedGroupIds.isNotEmpty) {
      setState(() => _message = 'Your group membership changed.');
    }
  }

  Future<void> _endRevokedVoiceSession(String groupId) async {
    if (_onlineSession?.groupId != groupId) return;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _peerDisconnectGraceTimer?.cancel();
    _peerDisconnectGraceTimer = null;
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _callModeTimeoutTimer?.cancel();
    _callModeTimeoutTimer = null;
    _usagePersistTimer?.cancel();
    _usagePersistTimer = null;
    await _disconnectLiveKit();
    if (!mounted) return;
    setState(() {
      _onlineSession = null;
      _talkSession = null;
      _talkPressed = false;
      _speakingUserIds = const {};
      _state = 'away';
      _connectionMode = MemberAvailability.walkieTalkieMode;
    });
    _syncPipSessionState();
  }

  Future<void> _takePendingInviteLink() async {
    if (_inviteJoinInFlight || _loadingGroups) return;
    final inviteCode = await _inviteLinkBridge.peekPendingInviteCode();
    if (inviteCode == null || !mounted) return;
    _inviteJoinInFlight = true;
    try {
      final groupId = await _groupRepository.joinInvite(inviteCode);
      await _inviteLinkBridge.clearPendingInviteCode(inviteCode);
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      if (!mounted) return;
      _preferredGroupId = groupId;
      debugPrint(
        '[OneOneInvite] Joined link while Home was active groupSuffix='
        '${groupId.length <= 6 ? groupId : groupId.substring(groupId.length - 6)}',
      );
      await _loadGroups();
      if (mounted) {
        setState(() => _message = 'Group joined from invite link.');
      }
    } catch (error, stack) {
      debugPrint(
        '[OneOneInvite] Active invite failed ${error.runtimeType}: $error',
      );
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'invite_join_failed',
        ),
      );
      if (error is ApiException &&
          const {
            'invite_not_found',
            'invite_unavailable',
            'group_full',
            'group_not_active',
          }.contains(error.code)) {
        await _inviteLinkBridge.clearPendingInviteCode(inviteCode);
      }
      if (mounted) {
        setState(() {
          _message = error is ApiException
              ? error.message
              : 'Couldn’t open this invite. Check your connection.';
        });
      }
    } finally {
      _inviteJoinInFlight = false;
    }
  }

  Future<void> _takePendingNudgeAction() async {
    if (_nudgeActionInFlight) return;
    NudgeNotificationAction? action;
    try {
      action =
          _deferredNudgeAction ??
          await _nudgeActionBridge.takePendingNudgeAction();
      if (action == null || !mounted) return;
      if (_loadingGroups) {
        _deferredNudgeAction = action;
        return;
      }
      _deferredNudgeAction = null;
      _nudgeActionInFlight = true;
      await _processNudgeAction(action);
    } catch (error) {
      if (action != null) _deferredNudgeAction = action;
      if (mounted) {
        setState(() => _message = 'Couldn’t process the nudge action.');
      }
    } finally {
      _nudgeActionInFlight = false;
    }
  }

  Future<void> _processNudgeAction(NudgeNotificationAction action) async {
    final index = _groups.indexWhere(
      (group) => group.groupId == action.groupId,
    );
    if (index < 0) {
      setState(() => _message = 'That nudge group is no longer available.');
      return;
    }

    await _onGroupCarouselChanged(index);
    if (!mounted) return;
    if (!_isViewingActiveGroup) {
      if (_isOnline) {
        await _switchVoiceGroup();
      } else {
        await _goOnline();
      }
    }
    if (!mounted) return;
    if (!_isOnline) {
      throw StateError('Could not enter the nudge group.');
    }
    if (action.action != 'accept') return;
    await _nudgeRepository.respond(
      groupId: action.groupId,
      eventId: action.eventId,
      action: 'accept',
    );
    debugPrint(
      '[OneOneFCM][DART-07] Accepted nudge and entered group '
      'eventSuffix=${action.eventId.length <= 6 ? action.eventId : action.eventId.substring(action.eventId.length - 6)}',
    );
  }

  Future<void> _replaceWithNoGroups() async {
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => NoGroupsScreen(
          session: _session,
          identityRepository: widget.identityRepository,
        ),
      ),
    );
  }

  Future<void> _loadMembers(String groupId) async {
    final members = await _groupRepository.loadGroupMembers(groupId);
    if (!mounted || _selectedGroup?.groupId != groupId) return;
    setState(() {
      _members = members;
      _membersByGroupId = {..._membersByGroupId, groupId: members};
    });
  }

  Future<void> _precacheGroupMemberPhotos(
    Iterable<GroupMemberSummary> members,
  ) async {
    final urls = members
        .map((member) => member.profilePhotoUrl?.trim())
        .whereType<String>()
        .where((url) => url.isNotEmpty)
        .toSet();

    await Future.wait(
      urls.map((url) async {
        try {
          await precacheImage(
            CachedNetworkImageProvider(url),
            context,
            onError: (error, stackTrace) {},
          );
        } catch (_) {
          // A broken member photo falls back to initials in ProfileImage.
        }
      }),
    );
  }

  void _listenToMembers(String groupId) {
    unawaited(_membersSubscription?.cancel());
    _membersSubscription = AppDatabase.instance()
        .ref('groupMembers/$groupId')
        .onValue
        .listen((event) {
          if (groupMembershipMatchesSnapshot(
            members: _members,
            snapshotValue: event.snapshot.value,
          )) {
            return;
          }
          unawaited(_loadMembers(groupId));
        });
  }

  void _listenToAvailability(String groupId) {
    unawaited(_availabilitySubscription?.cancel());
    _hasAvailabilitySnapshot = false;
    _availabilitySubscription = AppDatabase.instance()
        .ref('memberAvailability/$groupId')
        .onValue
        .listen((event) {
          final value = event.snapshot.value;
          final next = <String, MemberAvailability>{};

          if (value is Map<Object?, Object?>) {
            for (final entry in value.entries) {
              final raw = entry.value;
              if (raw is Map<Object?, Object?>) {
                next[entry.key.toString()] = MemberAvailability.fromJson(raw);
              }
            }
          }

          if (!mounted || _selectedGroup?.groupId != groupId) return;
          if (_hasAvailabilitySnapshot) {
            final lostPeerIds = _availability.entries
                .where(
                  (entry) =>
                      entry.key != _session.userId &&
                      entry.value.isLive &&
                      !(next[entry.key]?.isLive ?? false),
                )
                .map((entry) => entry.key)
                .toList(growable: false);
            if (lostPeerIds.isNotEmpty) {
              _showPeerLostConnection(lostPeerIds.first);
            }
          }
          setState(() => _availability = next);
          _hasAvailabilitySnapshot = true;
          _scheduleAvailabilityExpiryRefresh();
          if (_onlineSession?.groupId == groupId) {
            _evaluatePeerPresenceForAutoOffline(next);
          }
        });
  }

  /// Live-syncs the last [ChatMessageRepository.visibleLimit] chat bubbles
  /// for a group. Uses an RTDB `limitToLast` query rather than client-side
  /// trimming, so "never more than 6 visible" holds even under a burst of
  /// sends across multiple devices.
  void _listenToChatMessages(String groupId) {
    unawaited(_chatMessagesSubscription?.cancel());
    _chatMessagesSubscription = _chatMessageRepository
        .groupMessagesRef(groupId)
        .orderByChild('createdAt')
        .limitToLast(ChatMessageRepository.visibleLimit)
        .onValue
        .listen((event) {
          if (!mounted || _selectedGroup?.groupId != groupId) return;
          final value = event.snapshot.value;
          final messages = <GroupChatMessage>[];
          if (value is Map<Object?, Object?>) {
            for (final entry in value.entries) {
              final parsed = GroupChatMessage.tryParse(
                entry.key.toString(),
                entry.value,
              );
              if (parsed != null) messages.add(parsed);
            }
          }
          messages.sort((a, b) => a.createdAt.compareTo(b.createdAt));
          setState(() => _chatMessages = messages);
        });
  }

  void _dismissExpiredChatMessage(String messageId) {
    if (!mounted) return;
    setState(() {
      _chatMessages = _chatMessages
          .where((message) => message.messageId != messageId)
          .toList(growable: false);
    });
  }

  Future<void> _sendChatMessage(String text) async {
    final group = _selectedGroup;
    if (group == null) return;
    if (_session.settings.hapticsEnabled) {
      unawaited(HapticFeedback.selectionClick());
    }
    await _chatMessageRepository.sendMessage(
      groupId: group.groupId,
      senderUserId: _session.userId,
      senderDisplayName: _session.user.displayName,
      text: text,
    );
  }

  void _showPeerLostConnection(String userId) {
    final now = DateTime.now();
    if (_lastPeerLossUserId == userId &&
        _lastPeerLossAt != null &&
        now.difference(_lastPeerLossAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastPeerLossUserId = userId;
    _lastPeerLossAt = now;
    final name = _membersByGroupId.values
        .expand((members) => members)
        .where((member) => member.userId == userId)
        .map((member) => member.displayName.trim())
        .firstOrNull;
    _showPresenceSnackbar(
      '${name == null || name.isEmpty ? 'A participant' : name} lost connection.',
    );
  }

  /// Implements "automatic offline handling with a grace period": while
  /// this device is online, watch for the group dropping to exactly one
  /// online member. If nobody else is in (or rejoining) the room for
  /// [PresenceConfig.disconnectGracePeriod], this device is taken offline.
  ///
  /// The countdown only runs while we remain alone uninterrupted. Any other
  /// member rejoining — including still-connecting — cancels/resets it; a
  /// later drop back to one member starts a fresh minute.
  void _evaluatePeerPresenceForAutoOffline(
    Map<String, MemberAvailability> availability,
  ) {
    if (!_isOnline) {
      _peerWasLiveWithMe = false;
      _peerDisconnectGraceTimer?.cancel();
      _peerDisconnectGraceTimer = null;
      return;
    }

    final anyPeerInSession = _anyOtherMemberInVoiceSession(availability);

    if (anyPeerInSession) {
      _peerWasLiveWithMe = true;
      if (_peerDisconnectGraceTimer != null) {
        _peerDisconnectGraceTimer?.cancel();
        _peerDisconnectGraceTimer = null;
        if (mounted) setState(() => _message = 'Your friend reconnected.');
      }
      return;
    }

    // Never had a peer live with us yet (e.g. we just connected and theirs
    // hasn't propagated) — nothing to react to.
    if (!_peerWasLiveWithMe) return;
    if (_peerDisconnectGraceTimer != null) return;

    _peerDisconnectGraceTimer = Timer(PresenceConfig.disconnectGracePeriod, () {
      _peerDisconnectGraceTimer = null;
      if (!mounted || !_isOnline) return;
      // Re-check at fire time: a rejoin may have landed after the last
      // evaluation (or while this callback was already queued).
      if (_anyOtherMemberInVoiceSession(_availability)) return;
      unawaited(_goAway(reason: 'peer_left'));
      _showPresenceSnackbar(
        'The other participant has gone offline. You are now offline.',
      );
    });
  }

  bool _anyOtherMemberInVoiceSession(
    Map<String, MemberAvailability> availability,
  ) {
    return availability.entries.any(
      (entry) => entry.key != _session.userId && entry.value.isInVoiceSession,
    );
  }

  /// Marks the last time voice activity was detected (local or remote) and
  /// reschedules the inactivity timeout check. Called from talk start/stop
  /// and remote-speaker callbacks so the room stays open as long as anyone
  /// is actually talking.
  void _recordVoiceActivity() {
    if (!_isOnline) return;
    _lastVoiceActivityAt = DateTime.now();
    _scheduleInactivityCheck();
  }

  /// Starts or resets a timer that auto-closes the room if nobody speaks for
  /// [PresenceConfig.inactivityTimeout]. Prevents runaway sessions when a
  /// phone is left unattended with an open mic.
  void _scheduleInactivityCheck() {
    _inactivityTimer?.cancel();
    if (!_isOnline) return;
    _inactivityTimer = Timer(PresenceConfig.inactivityTimeout, () {
      if (!mounted || !_isOnline) return;
      final lastActivity = _lastVoiceActivityAt;
      if (lastActivity != null &&
          DateTime.now().difference(lastActivity) <
              PresenceConfig.inactivityTimeout) {
        // Activity happened since we scheduled — reschedule instead.
        _scheduleInactivityCheck();
        return;
      }
      unawaited(_goAway(reason: 'inactivity'));
      _showPresenceSnackbar(
        'Room closed due to inactivity. Send a nudge to go online again.',
      );
    });
  }

  /// Returns today's UTC date key (e.g. "2026-07-23") used to partition
  /// daily usage records in RTDB.
  String get _todayDateKey {
    final now = DateTime.now().toUtc();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  /// Loads the accumulated online seconds for this user in the selected
  /// group for today from RTDB. Called once when going online.
  Future<int> _loadDailyUsage(String groupId) async {
    try {
      final snapshot = await AppDatabase.instance()
          .ref('dailyUsage/$groupId/${_session.userId}/$_todayDateKey')
          .get();
      if (snapshot.exists && snapshot.value is Map<Object?, Object?>) {
        final data = snapshot.value! as Map<Object?, Object?>;
        return (data['onlineSeconds'] as num?)?.toInt() ?? 0;
      }
    } catch (_) {
      // Non-fatal — if we can't read usage, assume 0.
    }
    return 0;
  }

  /// Persists the accumulated online seconds to RTDB for today.
  Future<void> _persistDailyUsage(String groupId) async {
    try {
      await AppDatabase.instance()
          .ref('dailyUsage/$groupId/${_session.userId}/$_todayDateKey')
          .update({
            'onlineSeconds': _todayOnlineSeconds,
            'updatedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          });
    } catch (_) {
      // Best-effort — usage tracking is not critical for the session itself.
    }
  }

  /// Starts a periodic timer that increments the daily usage counter and
  /// persists it to RTDB every 30 seconds while the user is online.
  void _startUsageTracking() {
    _usagePersistTimer?.cancel();
    // Persist immediately when going online.
    final groupId = _onlineSession?.groupId;
    if (groupId != null) {
      unawaited(_persistDailyUsage(groupId));
    }
    _usagePersistTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!_isOnline) {
        _usagePersistTimer?.cancel();
        _usagePersistTimer = null;
        return;
      }
      _todayOnlineSeconds += 30;
      final groupId = _onlineSession?.groupId;
      if (groupId != null) {
        unawaited(_persistDailyUsage(groupId));
      }
      // If cap is exceeded mid-session, force offline.
      if (_todayOnlineSeconds >= PresenceConfig.dailyUsageCap.inSeconds) {
        unawaited(_goAway(reason: 'daily_usage_cap'));
        _showPresenceSnackbar(
          'Daily usage limit reached (${PresenceConfig.dailyUsageCap.inMinutes} min). '
          'You can go online again tomorrow.',
        );
      }
    });
  }

  /// Themed Snackbar for presence transitions the user didn't directly
  /// trigger (auto-offline, blocked "go online alone" attempts) — kept
  /// visually consistent with the app's dark glass surfaces rather than
  /// the default Material Snackbar look.
  void _showPresenceSnackbar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xff1e1e1e),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14.r),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          margin: EdgeInsets.fromLTRB(16.w, 0, 16.w, 16.h),
          duration: const Duration(seconds: 4),
          content: Row(
            children: [
              Icon(
                Icons.info_outline_rounded,
                color: Colors.white70,
                size: 18.sp,
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: Colors.white, fontSize: 13.sp),
                ),
              ),
            ],
          ),
        ),
      );
  }

  void _scheduleAvailabilityExpiryRefresh() {
    _availabilityExpiryTimer?.cancel();
    final now =
        DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;
    final futureExpiries = _availability.values
        .map((item) => item.staleAfterAt)
        .whereType<int>()
        .where((expiry) => expiry > now);
    if (futureExpiries.isEmpty) {
      // Everyone already stale (or no heartbeats) — still re-evaluate so a
      // lone-member grace timer can start without waiting for another RTDB
      // write.
      if (_onlineSession != null) {
        _evaluatePeerPresenceForAutoOffline(_availability);
      }
      return;
    }

    final nextExpiry = futureExpiries.reduce((a, b) => a < b ? a : b);
    _availabilityExpiryTimer = Timer(
      Duration(seconds: nextExpiry - now + 1),
      () {
        if (!mounted) return;
        setState(() {});
        if (_onlineSession != null) {
          _evaluatePeerPresenceForAutoOffline(_availability);
        }
        _scheduleAvailabilityExpiryRefresh();
      },
    );
  }

  Future<void> _selectGroup(String groupId) async {
    final group = _groups.firstWhere((item) => item.groupId == groupId);
    final cachedMembers = _membersByGroupId[groupId];
    setState(() {
      _selectedGroup = group;
      _members = cachedMembers ?? const [];
      _availability = const {};
      _chatMessages = const [];
    });
    if (cachedMembers == null) {
      await _loadMembers(group.groupId);
    }
    _listenToMembers(group.groupId);
    _listenToAvailability(group.groupId);
    _listenToChatMessages(group.groupId);
  }

  Future<void> _onGroupCarouselChanged(int index) async {
    if (index < 0 || index >= _groups.length) return;
    final group = _groups[index];
    setState(() => _carouselIndex = index);

    if (group.groupId == _selectedGroup?.groupId) return;

    await _selectGroup(group.groupId);
  }

  void _syncCarouselToSelectedGroup() {
    final selected = _selectedGroup;
    if (selected == null || _groups.isEmpty) return;
    final index = _groups.indexWhere(
      (group) => group.groupId == selected.groupId,
    );
    if (index < 0) return;

    _carouselIndex = index;
  }

  void _openCreateGroup() {
    _openGroupAction(GroupActionMode.createGroup);
  }

  void _openJoinGroup() {
    _openGroupAction(GroupActionMode.joinByPin);
  }

  void _openGroupAction(GroupActionMode mode) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 260),
        pageBuilder: (context, animation, secondaryAnimation) {
          return GroupActionScreen(
            mode: mode,
            session: _session,
            identityRepository: widget.identityRepository,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final offset =
              Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              );
          return SlideTransition(position: offset, child: child);
        },
      ),
    );
  }

  Future<void> _createInvite() async {
    final group = _selectedGroup;
    if (group == null) return;
    await _createInviteForGroup(group);
  }

  Future<void> _createInviteForGroup(GroupSummary group) async {
    await _runBusy(() async {
      final invite = await _groupRepository.createInvite(group.groupId);
      if (!mounted) return;
      setState(() => _message = 'Invite created');
      await _showShareInviteSheet(invite);
    });
  }

  Future<void> _showShareInviteSheet(GroupInviteResult invite) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xff141414),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24.r)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(24.w, 20.h, 24.w, 24.h),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Invite friends',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18.sp,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 8.h),
                Text(
                  'Share this link. Your friend will open One One and join this group automatically.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 14.sp),
                ),
                SizedBox(height: 20.h),
                Material(
                  color: const Color(0xff1f1f1f),
                  borderRadius: BorderRadius.circular(18.r),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18.r),
                    onTap: () async {
                      try {
                        await InviteLinkBridge().shareInviteLink(
                          invite.inviteUrl,
                        );
                      } catch (_) {
                        await Clipboard.setData(
                          ClipboardData(text: invite.inviteUrl),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invite link copied')),
                        );
                      }
                    },
                    child: Container(
                      width: double.infinity,
                      padding: EdgeInsets.symmetric(
                        horizontal: 20.w,
                        vertical: 18.h,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18.r),
                        border: Border.all(
                          color: const Color.fromRGBO(255, 255, 255, 0.12),
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.ios_share_rounded,
                                color: Colors.white,
                                size: 22.sp,
                              ),
                              SizedBox(width: 10.w),
                              Text(
                                'Share invite link',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 16.sp,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 8.h),
                          Text(
                            invite.inviteUrl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 11.sp,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 14.h),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: invite.inviteCode),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Fallback PIN copied')),
                    );
                  },
                  icon: Icon(Icons.copy_rounded, size: 17.sp),
                  label: Text('Copy PIN ${invite.inviteCode}'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _togglePresence() {
    if (_busy) return;
    if (!_serviceReady) {
      setState(() => _message = 'Invite a friend to enable voice service.');
      return;
    }
    if (_isViewingActiveGroup) {
      unawaited(_goAway());
      return;
    }
    if (_isOnline) {
      unawaited(_switchVoiceGroup());
      return;
    }
    // If someone else is already online in this group, let the user join
    // directly — no nudge required since the room is already active.
    if (_anyPeerOnline) {
      unawaited(_goOnline());
      return;
    }
    // Nobody is online yet — the room doesn't exist. Prompt the user to
    // send a nudge so at least two people go online together.
    _showPresenceSnackbar(
      'Send a nudge to go online together — or tap when someone else is already live.',
    );
  }

  /// True when at least one other group member is actively online.
  bool get _anyPeerOnline {
    return _availability.entries.any(
      (entry) => entry.key != _session.userId && entry.value.isLive,
    );
  }

  Future<void> _goOnline() async {
    final group = _selectedGroup;
    if (group == null) {
      setState(() => _message = 'Create or join a group first.');
      return;
    }
    if (_isOnline) {
      if (!_isViewingActiveGroup) await _switchVoiceGroup();
      return;
    }
    if (!_serviceReady) {
      setState(() => _message = 'Invite a friend to enable voice service.');
      return;
    }

    setState(() {
      _busy = true;
      _state = 'connecting';
      _message = null;
    });

    // Check daily usage cap before allowing the session to start.
    final dateKey = _todayDateKey;
    if (_todayUsageDateKey != dateKey) {
      _todayUsageDateKey = dateKey;
      _todayOnlineSeconds = 0;
    }
    final loadedSeconds = await _loadDailyUsage(group.groupId);
    if (loadedSeconds > _todayOnlineSeconds) {
      _todayOnlineSeconds = loadedSeconds;
    }
    if (_todayOnlineSeconds >= PresenceConfig.dailyUsageCap.inSeconds) {
      if (!mounted) return;
      unawaited(
        AnalyticsService.logDailyUsageCapReached(groupId: group.groupId),
      );
      setState(() {
        _busy = false;
        _state = 'away';
        _message =
            'Daily usage limit reached (${PresenceConfig.dailyUsageCap.inMinutes} min). '
            'You can go online again tomorrow.';
      });
      return;
    }

    // If peers are already connected to each other in call mode, join
    // directly into call mode with them rather than defaulting to
    // walkie-talkie — this is only ever the starting point, though: the
    // user can still tap the call-mode button to switch back at any time.
    final startInCallMode = _availability.entries.any(
      (entry) =>
          entry.key != _session.userId &&
          entry.value.isLive &&
          entry.value.isCallMode,
    );
    final startingConnectionMode = startInCallMode
        ? MemberAvailability.callMode
        : MemberAvailability.walkieTalkieMode;

    OnlineSession? createdSession;
    try {
      createdSession = await _onlineRepository.goOnline(
        identity: _session,
        group: group,
        connectionMode: startingConnectionMode,
      );
      await _connectLiveKit(createdSession);
      if (startInCallMode) {
        await _setMicrophoneEnabled(true);
      }
      await _onlineRepository.markLive(createdSession);
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        final activeSession = _onlineSession;
        if (activeSession != null) {
          unawaited(
            _onlineRepository.heartbeat(
              activeSession,
              isTalking: _talkSession != null,
            ),
          );
        }
      });

      if (!mounted) return;
      setState(() {
        _onlineSession = createdSession;
        _connectionMode = startingConnectionMode;
        _state = 'live';
        _message = LiveKitStatus.live;
      });
      _syncPipSessionState();
      if (startInCallMode) {
        _scheduleCallModeTimeout();
      } else {
        _cancelCallModeTimeout();
      }
      _scheduleInactivityCheck();
      _startUsageTracking();
      unawaited(
        AnalyticsService.logGoOnline(
          groupId: group.groupId,
          connectionMode: startingConnectionMode,
          joinedCallMode: startInCallMode,
        ),
      );
      unawaited(
        CrashlyticsService.log(
          'go_online group=${group.groupId} mode=$startingConnectionMode',
        ),
      );
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'livekit_go_online_failed',
          feature: 'presence',
        ),
      );
      await _disconnectLiveKit();
      if (createdSession != null) {
        try {
          await _onlineRepository.goAway(createdSession);
        } catch (_) {
          // Best-effort cleanup after a failed connect.
        }
      }
      if (!mounted) return;
      setState(() {
        _state = 'away';
        _message = LiveKitStatus.sanitizeError(error);
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _switchVoiceGroup() async {
    final previousSession = _onlineSession;
    final nextGroup = _selectedGroup;
    if (previousSession == null || nextGroup == null) return;
    if (previousSession.groupId == nextGroup.groupId) return;

    final previousName = _groups
        .where((group) => group.groupId == previousSession.groupId)
        .map((group) => group.name)
        .firstOrNull;
    await _goAway();
    if (!mounted || _onlineSession != null) return;
    await _goOnline();
    if (!mounted || _onlineSession?.groupId != nextGroup.groupId) return;
    _showPresenceSnackbar(
      'You joined ${nextGroup.name}. '
      'Connection with ${previousName ?? 'the previous group'} has ended.',
    );
  }

  Future<void> _goAway({String reason = 'user_away'}) async {
    final session = _onlineSession;
    if (session == null) {
      setState(() => _state = 'away');
      _syncPipSessionState();
      return;
    }

    await _runBusy(() async {
      final activeTalk = _talkSession;
      if (activeTalk != null) {
        await _talkRepository.stopTalk(activeTalk, reason: 'going_away');
      }
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      _peerDisconnectGraceTimer?.cancel();
      _peerDisconnectGraceTimer = null;
      _inactivityTimer?.cancel();
      _inactivityTimer = null;
      _lastVoiceActivityAt = null;
      _callModeTimeoutTimer?.cancel();
      _callModeTimeoutTimer = null;
      _usagePersistTimer?.cancel();
      _usagePersistTimer = null;
      // Persist final usage when going away.
      final groupId = session.groupId;
      if (_todayOnlineSeconds > 0) {
        unawaited(_persistDailyUsage(groupId));
      }
      _peerWasLiveWithMe = false;
      await _disconnectLiveKit();
      await _onlineRepository.goAway(session, reason: reason);
      unawaited(
        AnalyticsService.logGoAway(groupId: session.groupId, reason: reason),
      );
      unawaited(CrashlyticsService.log('go_away reason=$reason'));
      if (_shouldNotifyGoneOffline(reason)) {
        unawaited(
          _onlineRepository.notifyGoneOffline(session: session, reason: reason),
        );
      }
      if (!mounted) return;
      setState(() {
        _onlineSession = null;
        _talkSession = null;
        _speakingUserIds = const {};
        _state = 'away';
        _connectionMode = MemberAvailability.walkieTalkieMode;
        _message = LiveKitStatus.away;
      });
      _syncPipSessionState();
    });
  }

  /// True for leaves the user did not explicitly request — peer left after a
  /// nudge/elsewhere leave, inactivity, or daily cap. Manual toggle and group
  /// switches stay silent.
  bool _shouldNotifyGoneOffline(String reason) {
    return reason == 'peer_left' ||
        reason == 'inactivity' ||
        reason == 'daily_usage_cap' ||
        reason == 'network_loss';
  }

  Future<void> _startTalking() async {
    final session = _onlineSession;
    if (session == null ||
        !_isViewingActiveGroup ||
        _talkSession != null ||
        _talkBusy) {
      return;
    }

    _talkPressed = true;
    setState(() {
      _talkBusy = true;
      _message = null;
    });

    TalkSession? startedTalk;
    try {
      startedTalk = await _talkRepository.startTalk(session);
      if (!_talkPressed) {
        await _talkRepository.stopTalk(startedTalk, reason: 'released_early');
        await _setMicrophoneEnabled(false);
        if (!mounted) return;
        setState(() {
          _talkSession = null;
          _state = 'live';
        });
        return;
      }

      await _setMicrophoneEnabled(true);
      unawaited(
        TalkFeedback.talkStarted(
          hapticsEnabled: _session.settings.hapticsEnabled,
        ),
      );
      if (!mounted) return;

      if (!_talkPressed) {
        await _setMicrophoneEnabled(false);
        await _talkRepository.stopTalk(startedTalk, reason: 'released_early');
        setState(() {
          _talkSession = null;
          _state = 'live';
        });
        return;
      }

      setState(() {
        _talkSession = startedTalk;
        _state = 'talking';
        _message = LiveKitStatus.talking;
      });
      _syncPipSessionState();
      _recordVoiceActivity();
      unawaited(AnalyticsService.logTalkStart(groupId: session.groupId));
    } catch (error, stack) {
      unawaited(
        CrashlyticsService.recordError(
          error,
          stack,
          reason: 'talk_start_mic_failed',
          feature: 'talk',
        ),
      );
      if (startedTalk != null) {
        await _talkRepository.stopTalk(startedTalk, reason: 'mic_failed');
      }
      if (!mounted) return;
      setState(() {
        _talkSession = null;
        _state = _onlineSession == null ? 'away' : 'live';
        _message = LiveKitStatus.sanitizeError(error);
      });
      _syncPipSessionState();
    } finally {
      if (mounted) {
        setState(() => _talkBusy = false);
      }
    }
  }

  Future<void> _stopTalking({String reason = 'released'}) async {
    _talkPressed = false;
    final talkSession = _talkSession;
    if (talkSession == null) return;

    setState(() {
      _talkSession = null;
      _state = 'live';
      _message = LiveKitStatus.live;
    });
    _syncPipSessionState();

    _recordVoiceActivity();

    Object? stopError;
    try {
      await _setMicrophoneEnabled(false);
    } catch (error) {
      stopError = error;
    }

    try {
      unawaited(
        TalkFeedback.talkStopped(
          hapticsEnabled: _session.settings.hapticsEnabled,
        ),
      );
      await _talkRepository.stopTalk(talkSession, reason: reason);
      unawaited(
        AnalyticsService.logTalkStop(
          groupId: talkSession.groupId,
          reason: reason,
        ),
      );
    } catch (error) {
      stopError ??= error;
    }

    if (stopError != null) {
      if (!mounted) return;
      setState(() => _message = 'Couldn’t stop talking. Try again.');
    }
  }

  /// Toggles the local user's own connection between walkie-talkie
  /// (push-to-talk) and call (always-on mic). Purely per-user: it never
  /// touches anyone else's connection or availability.
  Future<void> _toggleConnectionMode() async {
    final session = _onlineSession;
    if (session == null ||
        _connectionModeBusy ||
        !_isViewingActiveGroup ||
        _busy) {
      return;
    }

    final switchingToCallMode = !_isCallMode;
    final nextMode = switchingToCallMode
        ? MemberAvailability.callMode
        : MemberAvailability.walkieTalkieMode;

    setState(() => _connectionModeBusy = true);
    try {
      // Switching modes mid-press shouldn't leave a dangling talk lock.
      final activeTalk = _talkSession;
      if (activeTalk != null) {
        await _stopTalking(reason: 'connection_mode_changed');
      }

      await _setMicrophoneEnabled(switchingToCallMode);
      await _onlineRepository.setConnectionMode(
        session,
        connectionMode: nextMode,
      );

      if (!mounted) return;
      setState(() => _connectionMode = nextMode);
      if (switchingToCallMode) {
        _scheduleCallModeTimeout();
      } else {
        _cancelCallModeTimeout();
      }
      _syncPipSessionState();
      unawaited(
        AnalyticsService.logConnectionModeChanged(
          groupId: session.groupId,
          mode: nextMode,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Couldn\u2019t switch connection mode.');
    } finally {
      if (mounted) setState(() => _connectionModeBusy = false);
    }
  }

  /// Starts (or restarts) the continuous call-mode cap. Fires
  /// [_exitCallModeDueToTimeout] after [PresenceConfig.callModeTimeout].
  void _scheduleCallModeTimeout() {
    _callModeTimeoutTimer?.cancel();
    _callModeTimeoutTimer = Timer(PresenceConfig.callModeTimeout, () {
      _callModeTimeoutTimer = null;
      unawaited(_exitCallModeDueToTimeout());
    });
  }

  void _cancelCallModeTimeout() {
    _callModeTimeoutTimer?.cancel();
    _callModeTimeoutTimer = null;
  }

  /// Auto-switches the local user back to walkie-talkie after the continuous
  /// call-mode cap. Keeps them connected to the group — only their mode and
  /// mic change. Other participants are not notified.
  Future<void> _exitCallModeDueToTimeout() async {
    final session = _onlineSession;
    if (session == null || !_isCallMode || _connectionModeBusy) return;

    setState(() => _connectionModeBusy = true);
    try {
      await _setMicrophoneEnabled(false);
      await _onlineRepository.setConnectionMode(
        session,
        connectionMode: MemberAvailability.walkieTalkieMode,
      );
      if (!mounted) return;
      setState(() => _connectionMode = MemberAvailability.walkieTalkieMode);
      _cancelCallModeTimeout();
      _syncPipSessionState();
      _showCallModeTimeoutSnackbar();
    } catch (_) {
      // Best-effort; leave local state as-is if the write fails so the user
      // can still toggle manually.
      if (!mounted) return;
      setState(() => _message = 'Couldn\u2019t leave call mode automatically.');
    } finally {
      if (mounted) setState(() => _connectionModeBusy = false);
    }
  }

  void _showCallModeTimeoutSnackbar() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: const Color(0xff1e1e1e),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14.r),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
          ),
          margin: EdgeInsets.fromLTRB(16.w, 0, 16.w, 16.h),
          duration: const Duration(seconds: 8),
          content: Row(
            children: [
              Icon(
                Icons.timer_off_outlined,
                color: Colors.white70,
                size: 18.sp,
              ),
              SizedBox(width: 10.w),
              Expanded(
                child: Text(
                  'Switched back to walkie-talkie after '
                  '${PresenceConfig.callModeTimeout.inMinutes} min in call mode.',
                  style: TextStyle(color: Colors.white, fontSize: 13.sp),
                ),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'Call mode',
            textColor: const Color(0xfffff1a8),
            onPressed: () {
              if (!_isCallMode) unawaited(_toggleConnectionMode());
            },
          ),
        ),
      );
  }

  Future<void> _connectLiveKit(OnlineSession session) async {
    await _disconnectLiveKit();
    final speakerOn = _session.settings.audioOutputPreference != 'earpiece';
    final room = Room(
      roomOptions: RoomOptions(
        adaptiveStream: false,
        dynacast: false,
        defaultAudioOutputOptions: AudioOutputOptions(speakerOn: speakerOn),
      ),
    );

    _room = room;
    _attachRoomListener(room);

    setState(() {
      _state = 'connecting';
      _message = LiveKitStatus.connecting;
    });

    await room
        .connect(
          session.livekitServerUrl,
          session.livekitToken,
          connectOptions: const ConnectOptions(autoSubscribe: true),
        )
        .timeout(const Duration(seconds: 20));

    try {
      await room.setSpeakerOn(speakerOn);
    } catch (_) {
      // Non-fatal. LiveKit can still use the platform default route.
    }

    final localParticipant = room.localParticipant;
    if (localParticipant == null) {
      throw StateError('LiveKit connected without a local participant.');
    }

    await localParticipant
        .setMicrophoneEnabled(false)
        .timeout(const Duration(seconds: 8));
  }

  Future<void> _applyPreferredAudioRoute() async {
    final room = _room;
    if (room == null) return;
    final preference =
        widget
            .identityRepository
            .currentSession
            ?.settings
            .audioOutputPreference ??
        _session.settings.audioOutputPreference;
    try {
      await room.setSpeakerOn(preference != 'earpiece');
    } catch (_) {
      // Route changes are best effort on devices without a separate earpiece.
    }
  }

  bool get _liveHapticsEnabled {
    return widget.identityRepository.currentSession?.settings.hapticsEnabled ??
        _session.settings.hapticsEnabled;
  }

  Future<void> _handleRemoteSpeakerStarted() async {
    await TalkFeedback.remoteSpeakerStarted(
      hapticsEnabled: _liveHapticsEnabled,
    );
    // Some audio-feedback implementations briefly alter the platform audio
    // session. Reassert the user's route after the tone completes.
    await _applyPreferredAudioRoute();
  }

  String? _participantUserIdFromIdentity(String identity) {
    final parts = identity.split(':');
    if (parts.length < 3) return null;
    return parts[1];
  }

  ConnectionQuality _mergeConnectionQuality(
    ConnectionQuality? existing,
    ConnectionQuality incoming,
  ) {
    if (existing == null) return incoming;

    const order = [
      ConnectionQuality.lost,
      ConnectionQuality.poor,
      ConnectionQuality.unknown,
      ConnectionQuality.good,
      ConnectionQuality.excellent,
    ];

    final existingIndex = order.indexOf(existing);
    final incomingIndex = order.indexOf(incoming);
    return existingIndex <= incomingIndex ? existing : incoming;
  }

  void _syncConnectionQualities(Room room) {
    if (!mounted) return;

    final remotes = <String, ConnectionQuality>{};
    for (final participant in room.remoteParticipants.values) {
      final userId = _participantUserIdFromIdentity(participant.identity);
      if (userId == null) continue;
      remotes[userId] = _mergeConnectionQuality(
        remotes[userId],
        participant.connectionQuality,
      );
    }

    setState(() {
      _localConnectionQuality =
          room.localParticipant?.connectionQuality ?? ConnectionQuality.unknown;
      _remoteConnectionQualityByUserId = remotes;
    });
  }

  void _updateParticipantConnectionQuality(
    Participant participant,
    ConnectionQuality quality,
  ) {
    if (!mounted) return;

    if (participant is LocalParticipant) {
      setState(() => _localConnectionQuality = quality);
      return;
    }

    final userId = _participantUserIdFromIdentity(participant.identity);
    if (userId == null) return;

    setState(() {
      _remoteConnectionQualityByUserId = {
        ..._remoteConnectionQualityByUserId,
        userId: _mergeConnectionQuality(
          _remoteConnectionQualityByUserId[userId],
          quality,
        ),
      };
    });
  }

  void _clearConnectionQualities() {
    _localConnectionQuality = ConnectionQuality.unknown;
    _remoteConnectionQualityByUserId = const {};
    if (mounted) setState(() {});
  }

  void _attachRoomListener(Room room) {
    _roomListener = room.createListener()
      ..on<RoomConnectedEvent>((_) {
        _syncConnectionQualities(room);
        _setMessage(LiveKitStatus.connected);
      })
      ..on<RoomReconnectingEvent>((_) {
        _setStateAndMessage('reconnecting', LiveKitStatus.reconnecting);
      })
      ..on<RoomReconnectedEvent>((_) {
        _syncConnectionQualities(room);
        _setStateAndMessage('live', LiveKitStatus.connected);
      })
      ..on<RoomDisconnectedEvent>((event) {
        unawaited(
          _handleConnectionLoss(
            LiveKitStatus.fromDisconnectReason(event.reason),
          ),
        );
      })
      ..on<ParticipantConnectedEvent>((event) {
        _updateParticipantConnectionQuality(
          event.participant,
          event.participant.connectionQuality,
        );
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        final userId = _participantUserIdFromIdentity(
          event.participant.identity,
        );
        if (userId != null) _showPeerLostConnection(userId);
      })
      ..on<ParticipantConnectionQualityUpdatedEvent>((event) {
        _updateParticipantConnectionQuality(
          event.participant,
          event.connectionQuality,
        );
      })
      ..on<TrackSubscribedEvent>((_) {
        // Subscription is an implementation detail — keep UI status clean.
      })
      ..on<ActiveSpeakersChangedEvent>((event) {
        final previousRemoteSpeakers = _speakingUserIds.where(
          (id) => id != _session.userId,
        );
        final speaking = <String>{};
        for (final speaker in event.speakers) {
          final userId =
              LiveKitStatus.userIdFromIdentity(speaker.identity) ??
              _participantUserIdFromIdentity(speaker.identity);
          if (userId != null) speaking.add(userId);
        }
        if (!mounted) return;
        final newlySpeakingRemote = speaking
            .where((id) => id != _session.userId)
            .any((id) => !previousRemoteSpeakers.contains(id));
        final hasRemoteSpeaker = speaking.any((id) => id != _session.userId);
        if (hasRemoteSpeaker || speaking.contains(_session.userId)) {
          _recordVoiceActivity();
        }
        if (newlySpeakingRemote && _talkSession != null) {
          unawaited(_handleRemoteSpeakerStarted());
        } else if (speaking.any((id) => id != _session.userId)) {
          // Never let active-speaker auto-routing override the stored choice.
          unawaited(_applyPreferredAudioRoute());
        }
        setState(() {
          _speakingUserIds = speaking;
          final remoteSpeaking = speaking.any((id) => id != _session.userId);
          if (remoteSpeaking && _talkSession == null) {
            _message = LiveKitStatus.receivingVoice;
          }
        });
      });
  }

  Future<void> _handleConnectionLoss(String message) async {
    final session = _onlineSession;
    if (session == null || _connectionCleanupInFlight) return;
    _connectionCleanupInFlight = true;

    final talkSession = _talkSession;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _peerDisconnectGraceTimer?.cancel();
    _peerDisconnectGraceTimer = null;
    _inactivityTimer?.cancel();
    _inactivityTimer = null;
    _callModeTimeoutTimer?.cancel();
    _callModeTimeoutTimer = null;
    _usagePersistTimer?.cancel();
    _usagePersistTimer = null;
    if (mounted) {
      setState(() {
        _onlineSession = null;
        _talkSession = null;
        _talkPressed = false;
        _speakingUserIds = const {};
        _state = 'away';
        _connectionMode = MemberAvailability.walkieTalkieMode;
        _message = message;
      });
      _syncPipSessionState();
    }

    try {
      if (talkSession != null) {
        await _talkRepository.stopTalk(talkSession, reason: 'connection_lost');
      }
    } catch (_) {
      // Presence cleanup still has to continue.
    }
    await _disconnectLiveKit();
    try {
      await _onlineRepository
          .goAway(session, reason: 'network_loss')
          .timeout(const Duration(seconds: 3));
      unawaited(
        _onlineRepository.notifyGoneOffline(
          session: session,
          reason: 'network_loss',
        ),
      );
    } catch (_) {
      // Firebase onDisconnect was registered before going live and is the
      // server-side fallback when the device cannot write during an outage.
    } finally {
      _connectionCleanupInFlight = false;
    }
    if (mounted) _showPresenceSnackbar(message);
  }

  Future<void> _disconnectLiveKit() async {
    final room = _room;
    _room = null;
    _roomListener?.dispose();
    _roomListener = null;
    _speakingUserIds = const {};
    _clearConnectionQualities();

    try {
      final localParticipant = room?.localParticipant;
      if (localParticipant != null) {
        await localParticipant.setMicrophoneEnabled(false);
      }
    } catch (_) {
      // Ignore cleanup failures.
    }

    await room?.disconnect();
  }

  Future<void> _setMicrophoneEnabled(bool enabled) async {
    final participant = _room?.localParticipant;
    if (participant == null) {
      throw StateError('LiveKit is not connected yet.');
    }

    await participant
        .setMicrophoneEnabled(enabled)
        .timeout(const Duration(seconds: 8));
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });

    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = LiveKitStatus.sanitizeError(error));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _setMessage(String message) {
    if (!mounted) return;
    setState(() => _message = message);
  }

  void _setStateAndMessage(String state, String message) {
    if (!mounted) return;
    setState(() {
      _state = state;
      _message = message;
    });
  }

  Future<bool> _openGroupManagement() async {
    final group = _selectedGroup;
    if (group == null) return false;
    final outcome = await Navigator.of(context).push<GroupManagementOutcome>(
      MaterialPageRoute<GroupManagementOutcome>(
        builder: (_) => GroupManagementScreen(
          group: group,
          currentUserId: _session.userId,
          initialMembers: _members,
          onInvite: () => _createInviteForGroup(group),
        ),
      ),
    );
    if (outcome == null || !mounted) return false;

    await _endRevokedVoiceSession(group.groupId);
    if (!mounted) return true;
    await _loadGroups();
    if (mounted && _groups.isNotEmpty) {
      setState(() {
        _message = outcome == GroupManagementOutcome.groupDeleted
            ? '${group.name} was deleted.'
            : 'You left ${group.name}.';
      });
    }
    return true;
  }

  void _openSettings() {
    final group = _selectedGroup;
    unawaited(
      SettingsScreen.open(
        context,
        session: _session,
        identityRepository: widget.identityRepository,
        groupName: group?.name,
        onManageGroup: group == null ? null : _openGroupManagement,
      ),
    );
  }

  void _openNudges() {
    final group = _selectedGroup;
    if (group == null) return;
    if (_session.settings.hapticsEnabled) {
      unawaited(HapticFeedback.selectionClick());
    }
    unawaited(
      showNudgeBottomSheet(
        context,
        group: group,
        currentUserId: _session.userId,
        members: _displayMembers,
        accent: accentColorForKey(_session.settings.accentColorKey),
        hapticsEnabled: _session.settings.hapticsEnabled,
      ),
    );
  }

  void _openSetupWarnings() {
    final warnings = _setupWarnings();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              Text('Setup', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              if (warnings.isEmpty)
                const _SetupLine(
                  ok: true,
                  text: 'Ready for foreground and closed-app voice',
                )
              else
                for (final warning in warnings)
                  _SetupLine(ok: false, text: warning),
            ],
          ),
        );
      },
    );
  }

  List<String> _setupWarnings() {
    final warnings = <String>[];
    if (_groups.isEmpty) {
      warnings.add('Create or join a group.');
    }
    if (!_session.device.micPermissionGranted && _onlineSession == null) {
      warnings.add('Microphone permission has not been confirmed.');
    }
    if (!_session.device.notificationPermissionGranted) {
      warnings.add(
        'Notification permission is required for closed-app nudges.',
      );
    }
    if (_session.device.fcmToken == null) {
      warnings.add(
        'Push registration is not ready. Reopen the app while online.',
      );
    }
    if (!_session.device.batteryOptimizationIgnored) {
      warnings.add('Battery optimization may interrupt background mode.');
    }
    return warnings;
  }

  bool get _isOnline => _onlineSession != null;
  bool get _isViewingActiveGroup =>
      _onlineSession?.groupId == _selectedGroup?.groupId;
  bool get _isCallMode => _connectionMode == MemberAvailability.callMode;

  bool get _serviceReady =>
      groupHasServicePeer(members: _members, currentUserId: _session.userId);

  List<GroupMemberSummary> get _friends {
    return _members
        .where((member) => member.userId != _session.userId)
        .toList(growable: false);
  }

  List<GroupMemberSummary> get _displayMembers {
    return _displayMembersFrom(_members);
  }

  GroupMemberSummary get _pictureInPictureMember {
    final activeUserId = _speakingUserIds.firstOrNull ?? _session.userId;
    final activeMembers = _displayMembersFrom(
      _membersByGroupId[_onlineSession?.groupId] ?? const [],
    );
    for (final member in activeMembers) {
      if (member.userId == activeUserId) return member;
    }
    return GroupMemberSummary(
      userId: _session.userId,
      displayName: _session.user.displayName,
      role: 'member',
      memberState: 'active',
      profilePhotoUrl: _session.user.profilePhotoUrl,
      profilePhotoBase64: _session.user.profilePhotoBase64,
    );
  }

  List<GroupMemberSummary> _displayMembersFrom(
    List<GroupMemberSummary> members,
  ) {
    return members
        .map((member) {
          if (member.userId != _session.userId) return member;
          return GroupMemberSummary(
            userId: member.userId,
            displayName: _session.user.displayName,
            role: member.role,
            memberState: member.memberState,
            profilePhotoUrl: _session.user.profilePhotoUrl,
            profilePhotoBase64: _session.user.profilePhotoBase64,
          );
        })
        .toList(growable: false);
  }

  ConnectionQuality get _effectiveLocalConnectionQuality {
    if (_connectivity.contains(ConnectivityResult.none)) {
      return ConnectionQuality.lost;
    }
    if (_localConnectionQuality != ConnectionQuality.unknown) {
      return _localConnectionQuality;
    }
    return _connectivity.isEmpty
        ? ConnectionQuality.unknown
        : ConnectionQuality.good;
  }

  List<_CarouselItem> get _carouselItems {
    final selfIsLive = _isOnline && (_state == 'live' || _state == 'talking');
    final selfAvailability = _isOnline
        ? MemberAvailability(
            desiredState: 'online',
            effectiveState: _state,
            canReceiveLiveAudio: selfIsLive,
          )
        : MemberAvailability.away;

    return [
      for (final group in _groups)
        _CarouselItem.group(
          group: group,
          displayName: _session.user.displayName,
          profilePhotoUrl: _session.user.profilePhotoUrl,
          profilePhotoBase64: _session.user.profilePhotoBase64,
          avatarAsset: _session.user.avatarAsset,
          availability: group.groupId == _onlineSession?.groupId
              ? selfAvailability
              : MemberAvailability.away,
          members: _displayMembersFrom(
            _membersByGroupId[group.groupId] ?? const [],
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final accent = accentColorForKey(_session.settings.accentColorKey);
    // Android reports PiP exit before the window has finished expanding.
    // Keep the compact constraint-safe view during those intermediate frames.
    if (_inPictureInPicture || MediaQuery.sizeOf(context).height < 480) {
      final member = _pictureInPictureMember;
      return _VoicePictureInPictureView(
        member: member,
        speaking:
            _speakingUserIds.contains(member.userId) ||
            (_talkSession != null && member.userId == _session.userId),
        talking: _talkSession != null,
        accent: accent,
      );
    }
    final warnings = _setupWarnings();
    final items = _carouselItems;
    final focusedGroup = _selectedGroup;
    final activeGroup = _groups
        .where((group) => group.groupId == _onlineSession?.groupId)
        .firstOrNull;
    final viewingActiveGroup = _isViewingActiveGroup;
    // Local session is the source of truth — remote availability can lag after goAway.
    final live = _isOnline && (_state == 'live' || _state == 'talking');
    final inviteAction = _busy || focusedGroup == null
        ? null
        : () => unawaited(_createInvite());

    // Tri-state for the focused group's control cluster: whether nobody, some,
    // or everybody (self included) is currently online. Drives whether the
    // main button becomes a nudge trigger, whether the nudge bell shows, and
    // whether the call-mode controls render at all.
    final friends = _friends;
    final anyFriendOnline = friends.any(
      (friend) =>
          (_availability[friend.userId] ?? MemberAvailability.away).isLive,
    );
    final allFriendsOnline =
        friends.isNotEmpty &&
        friends.every(
          (friend) =>
              (_availability[friend.userId] ?? MemberAvailability.away).isLive,
        );
    final groupAllOffline = !live && !anyFriendOnline;
    final groupAllOnline = live && allFriendsOnline;
    final groupMixed = !groupAllOffline && !groupAllOnline;
    final anyMemberOnline = live || anyFriendOnline;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _HomeBackdrop(
            members: _displayMembers,
            fallbackPhotoUrl: _session.user.profilePhotoUrl,
            fallbackPhotoBase64: _session.user.profilePhotoBase64,
            fallbackAvatarAsset: _session.user.avatarAsset,
            accent: accent,
          ),
          SafeArea(
            child: RefreshIndicator(
              onRefresh: _loadGroups,
              color: Colors.black,
              backgroundColor: Colors.white,
              child: CustomScrollView(
                // The layout below has no intrinsic scroll content (it's a
                // fixed column with a Spacer), so force scrollability purely
                // to make the pull-to-refresh drag gesture available.
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Column(
                      children: [
                        _TopChrome(
                          onSettings: _openSettings,
                          onSetup: _openSetupWarnings,
                          hasSetupWarnings: warnings.isNotEmpty,
                          busy: _busy,
                          online: live,
                          enabled: _serviceReady,
                          onTogglePresence: _togglePresence,
                          showNetworkStrength: _isOnline,
                          localConnectionQuality:
                              _effectiveLocalConnectionQuality,
                        ),
                        SizedBox(height: 8.h),
                        _FriendsStrip(
                          groupName: focusedGroup?.name,
                          friends: _friends,
                          availability: _availability,
                          speakingUserIds: _speakingUserIds,
                          connectionQualityByUserId:
                              _remoteConnectionQualityByUserId,
                          onInvite: inviteAction,
                          allOffline: groupAllOffline,
                          showNudge: groupMixed,
                          onNudge: _busy ? null : _openNudges,
                        ),
                        if (_message != null) ...[
                          SizedBox(height: 10.h),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 24.w),
                            child: Text(
                              _message!,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12.sp,
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (_chatMessages.isNotEmpty)
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16.w),
                            child: ChatBubbleFeed(
                              messages: _chatMessages,
                              currentUserId: _session.userId,
                              accent: accent,
                              onExpire: _dismissExpiredChatMessage,
                            ),
                          ),
                        SizedBox(
                          height: 200.h,
                          child: _ExperienceCarousel(
                            items: items,
                            index: _carouselIndex,
                            connectedGroupId: _onlineSession?.groupId,
                            talkEnabled:
                                viewingActiveGroup && !_busy && !_isCallMode,
                            talkActive:
                                _talkSession != null ||
                                (_isCallMode &&
                                    _speakingUserIds.contains(_session.userId)),
                            talkBusy: _talkBusy,
                            accent: accent,
                            nudgeGroupId: groupAllOffline
                                ? focusedGroup?.groupId
                                : null,
                            onNudge: _busy ? null : _openNudges,
                            onSelected: (index) {
                              unawaited(_onGroupCarouselChanged(index));
                            },
                            onTalkStart: _startTalking,
                            onTalkStop: () => _stopTalking(),
                            onJoinVoiceGroup: _togglePresence,
                            onCreateGroup: _openCreateGroup,
                            onJoinGroup: _openJoinGroup,
                          ),
                        ),
                        if (items.length > 1) ...[
                          SizedBox(height: 8.h),
                          _CarouselDotIndicator(
                            count: items.length,
                            index: _carouselIndex.clamp(0, items.length - 1),
                          ),
                        ],
                        SizedBox(height: 18.h),
                        Text(
                          viewingActiveGroup
                              ? (_isCallMode
                                    ? 'In a call — mic always on'
                                    : 'Tap to Talk')
                              : _isOnline
                              ? 'connected to ${activeGroup?.name ?? 'another group'} • tap this group to join'
                              : !_serviceReady
                              ? 'invite a friend to enable voice service'
                              : 'send a nudge to go online together',
                          style: TextStyle(
                            color: const Color.fromRGBO(255, 255, 255, 0.55),
                            fontSize: 13.sp,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        AnimatedSize(
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutCubic,
                          alignment: Alignment.topCenter,
                          child: anyMemberOnline
                              ? Padding(
                                  key: const ValueKey('call-mode-controls'),
                                  padding: EdgeInsets.only(top: 16.h),
                                  child: _CallModeControls(
                                    active: _isCallMode,
                                    enabled:
                                        viewingActiveGroup &&
                                        !_connectionModeBusy,
                                    accent: accent,
                                    onToggle: _toggleConnectionMode,
                                  ),
                                )
                              : const SizedBox.shrink(
                                  key: ValueKey('call-mode-controls-hidden'),
                                ),
                        ),
                        if (focusedGroup != null) ...[
                          SizedBox(height: 20.h),
                          ChatBubbleBar(
                            accent: accent,
                            onSend: _sendChatMessage,
                          ),
                        ],
                        SizedBox(height: 28.h),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VoicePictureInPictureView extends StatelessWidget {
  const _VoicePictureInPictureView({
    required this.member,
    required this.speaking,
    required this.talking,
    required this.accent,
  });

  final GroupMemberSummary member;
  final bool speaking;
  final bool talking;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xff101010),
      child: ClipRect(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final shortestSide = constraints.biggest.shortestSide;
            final avatarRadius = (shortestSide * 0.32).clamp(20.0, 68.0);
            return Semantics(
              label:
                  '${member.displayName}, ${speaking ? 'speaking' : 'listening'}, '
                  '${talking ? 'microphone on' : 'microphone muted'}',
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: speaking ? const Color(0xff7CFF6B) : accent,
                          width: speaking ? 3 : 1,
                        ),
                      ),
                      child: ProfileAvatar(
                        profilePhotoUrl: member.profilePhotoUrl,
                        profilePhotoBase64: member.profilePhotoBase64,
                        avatarAsset: member.avatarAsset,
                        radius: avatarRadius,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: talking
                            ? const Color(0xff28A745)
                            : const Color(0xdd202020),
                      ),
                      child: Icon(
                        talking ? Icons.mic_rounded : Icons.mic_off_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                  Positioned(
                    left: 8,
                    right: 52,
                    bottom: 10,
                    child: Text(
                      member.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        shadows: [Shadow(blurRadius: 6, color: Colors.black)],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HomeBackdrop extends StatelessWidget {
  const _HomeBackdrop({
    required this.members,
    required this.fallbackPhotoUrl,
    required this.fallbackPhotoBase64,
    required this.fallbackAvatarAsset,
    required this.accent,
  });

  final List<GroupMemberSummary> members;
  final String? fallbackPhotoUrl;
  final String? fallbackPhotoBase64;
  final String? fallbackAvatarAsset;
  final Color accent;

  bool _memberHasPhoto(GroupMemberSummary member) {
    return (member.profilePhotoUrl?.trim().isNotEmpty ?? false) ||
        (member.profilePhotoBase64?.trim().isNotEmpty ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final hasMemberPhotos = members.any(_memberHasPhoto);
    final hasFallbackPhoto =
        (fallbackPhotoUrl?.trim().isNotEmpty ?? false) ||
        (fallbackPhotoBase64?.trim().isNotEmpty ?? false);
    final showCollage = members.isNotEmpty ? true : hasFallbackPhoto;

    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        if (showCollage)
          Opacity(
            opacity: hasMemberPhotos || hasFallbackPhoto ? 0.35 : 0.2,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 40, sigmaY: 40),
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: 400,
                  height: 800,
                  child: _BackdropMemberCollage(
                    members: members,
                    fallbackPhotoUrl: fallbackPhotoUrl,
                    fallbackPhotoBase64: fallbackPhotoBase64,
                    fallbackAvatarAsset: fallbackAvatarAsset,
                  ),
                ),
              ),
            ),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.3),
                Colors.black.withValues(alpha: 0.55),
                Colors.black.withValues(alpha: 0.88),
                Color.lerp(Colors.black, accent, 0.14)!,
              ],
              stops: const [0, 0.35, 0.72, 1],
            ),
          ),
        ),
      ],
    );
  }
}

/// Full-bleed member photo grid for the blurred home backdrop.
class _BackdropMemberCollage extends StatelessWidget {
  const _BackdropMemberCollage({
    required this.members,
    required this.fallbackPhotoUrl,
    required this.fallbackPhotoBase64,
    required this.fallbackAvatarAsset,
  });

  static const int _maxTiles = 9;

  final List<GroupMemberSummary> members;
  final String? fallbackPhotoUrl;
  final String? fallbackPhotoBase64;
  final String? fallbackAvatarAsset;

  int _columnsFor(int count) {
    if (count <= 1) return 1;
    if (count <= 4) return 2;
    return 3;
  }

  Widget _tile(GroupMemberSummary member) {
    final initial = member.displayName.trim().isEmpty
        ? '?'
        : member.displayName.trim().substring(0, 1).toUpperCase();
    return ProfileImage(
      profilePhotoUrl: member.profilePhotoUrl,
      profilePhotoBase64: member.profilePhotoBase64,
      avatarAsset: member.avatarAsset,
      backgroundColor: const Color(0xff1a1a1a),
      fallback: Text(
        initial,
        style: const TextStyle(
          color: Colors.white54,
          fontSize: 48,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return ProfileImage(
        profilePhotoUrl: fallbackPhotoUrl,
        profilePhotoBase64: fallbackPhotoBase64,
        avatarAsset: fallbackAvatarAsset,
        backgroundColor: const Color(0xff1a1a1a),
        fallback: const Icon(
          Icons.person_outline,
          color: Colors.white38,
          size: 120,
        ),
      );
    }

    final tiles = members.take(_maxTiles).toList(growable: false);
    final columns = _columnsFor(tiles.length);
    final rows = (tiles.length / columns).ceil();

    return Column(
      children: List.generate(rows, (row) {
        return Expanded(
          child: Row(
            children: List.generate(columns, (column) {
              final index = row * columns + column;
              if (index >= tiles.length) {
                return const Expanded(
                  child: ColoredBox(color: Color(0xff141414)),
                );
              }
              return Expanded(child: _tile(tiles[index]));
            }),
          ),
        );
      }),
    );
  }
}

class _TopChrome extends StatelessWidget {
  const _TopChrome({
    required this.onSettings,
    required this.onSetup,
    required this.hasSetupWarnings,
    required this.busy,
    required this.online,
    required this.enabled,
    required this.onTogglePresence,
    required this.showNetworkStrength,
    required this.localConnectionQuality,
  });

  final VoidCallback onSettings;
  final VoidCallback onSetup;
  final bool hasSetupWarnings;
  final bool busy;
  final bool online;
  final bool enabled;
  final VoidCallback onTogglePresence;
  final bool showNetworkStrength;
  final ConnectionQuality localConnectionQuality;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(12.w, 4.h, 12.w, 0),
      child: SizedBox(
        height: 52.h,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: Image.asset(
                'assets/logo.png',
                height: 44.h,
                fit: BoxFit.contain,
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      _GlassIconButton(
                        tooltip: hasSetupWarnings
                            ? 'Settings / Setup'
                            : 'Settings',
                        icon: Icons.settings_outlined,
                        onPressed: onSettings,
                        onLongPress: onSetup,
                      ),
                      if (hasSetupWarnings)
                        Positioned(
                          top: -2,
                          right: -2,
                          child: GestureDetector(
                            onTap: onSetup,
                            child: Container(
                              width: 14.w,
                              height: 14.w,
                              decoration: const BoxDecoration(
                                color: Color(0xffff5a5f),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  if (showNetworkStrength) ...[
                    SizedBox(width: 6.w),
                    _NetworkStrengthIndicator(
                      quality: localConnectionQuality,
                      tooltip: 'Your network',
                    ),
                  ],
                ],
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              // No text label under the toggle by design - its state (and a
              // description for accessibility) is conveyed by the switch
              // itself plus its Tooltip/Semantics.
              child: _StatusToggle(
                busy: busy,
                online: online,
                enabled: enabled,
                onToggle: onTogglePresence,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusToggle extends StatelessWidget {
  const _StatusToggle({
    required this.busy,
    required this.online,
    required this.enabled,
    required this.onToggle,
  });

  final bool busy;
  final bool online;
  final bool enabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: busy || !enabled ? 0.55 : 1,
      child: Tooltip(
        message: !enabled
            ? 'Available after another member joins'
            : online
            ? 'Tap to go away'
            : 'Go online when someone is already live, or send a nudge to go together',
        child: SizedBox(
          width: 72.w,
          height: 48,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: busy || !enabled ? null : onToggle,
              borderRadius: BorderRadius.circular(24),
              child: Center(
                child: Container(
                  width: double.infinity,
                  height: 30.h,
                  padding: EdgeInsets.all(2.w),
                  decoration: BoxDecoration(
                    color: const Color.fromRGBO(255, 255, 255, 0.12),
                    borderRadius: BorderRadius.circular(18.r),
                    border: Border.all(
                      color: const Color.fromRGBO(255, 255, 255, 0.22),
                    ),
                  ),
                  child: Stack(
                    children: [
                      AnimatedAlign(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        alignment: online
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          width: 34.w,
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color: online
                                ? const Color(0xff7CFF6B)
                                : Colors.white,
                            borderRadius: BorderRadius.circular(14.r),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Center(
                              child: Text(
                                '🌙',
                                style: TextStyle(fontSize: 11.sp),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Center(
                              child: busy
                                  ? Text('…', style: TextStyle(fontSize: 11.sp))
                                  : online
                                  ? Text(
                                      '🟢',
                                      style: TextStyle(fontSize: 11.sp),
                                    )
                                  : const SizedBox.shrink(),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.onLongPress,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(22.r),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: onPressed == null
                ? const Color.fromRGBO(255, 255, 255, 0.06)
                : const Color.fromRGBO(0, 0, 0, 0.35),
            border: Border.all(
              color: const Color.fromRGBO(255, 255, 255, 0.18),
            ),
          ),
          child: Icon(
            icon,
            color: onPressed == null ? Colors.white38 : Colors.white,
            size: 22.sp,
          ),
        ),
      ),
    );
  }
}

class _FriendsStrip extends StatelessWidget {
  const _FriendsStrip({
    required this.groupName,
    required this.friends,
    required this.availability,
    required this.speakingUserIds,
    required this.connectionQualityByUserId,
    required this.onInvite,
    required this.allOffline,
    required this.showNudge,
    required this.onNudge,
  });

  final String? groupName;
  final List<GroupMemberSummary> friends;
  final Map<String, MemberAvailability> availability;
  final Set<String> speakingUserIds;
  final Map<String, ConnectionQuality> connectionQualityByUserId;
  final VoidCallback? onInvite;

  /// Whether every member of this group (including the local user) is
  /// currently offline. Dims member avatars when true.
  final bool allOffline;

  /// Whether to show the nudge bell trailing the avatar row — only in the
  /// "mixed" state (some online, some offline).
  final bool showNudge;
  final VoidCallback? onNudge;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (groupName != null)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 20.w),
            child: Text(
              groupName!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 14.sp,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
          ),
        SizedBox(height: 10.h),
        SizedBox(
          height: 104.h,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(horizontal: 16.w),
            children: [
              for (final friend in friends) ...[
                _FriendChip(
                  name: friend.displayName,
                  profilePhotoUrl: friend.profilePhotoUrl,
                  profilePhotoBase64: friend.profilePhotoBase64,
                  avatarAsset: friend.avatarAsset,
                  availability:
                      availability[friend.userId] ?? MemberAvailability.away,
                  isSpeaking:
                      speakingUserIds.contains(friend.userId) ||
                      (availability[friend.userId]?.isTalking ?? false),
                  dimmed: allOffline,
                  connectionQuality:
                      connectionQualityByUserId[friend.userId] ??
                      ConnectionQuality.unknown,
                ),
                SizedBox(width: 12.w),
              ],
              _AddFriendChip(onTap: onInvite),
              if (showNudge) ...[
                SizedBox(width: 12.w),
                _NudgeBellChip(onTap: onNudge),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _NudgeBellChip extends StatelessWidget {
  const _NudgeBellChip({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Column(
          children: [
            Container(
              width: 52.w,
              height: 52.w,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xff2a2a2a),
                border: Border.all(color: const Color(0xffffb347), width: 1.5),
              ),
              child: Icon(
                Icons.notifications_active_rounded,
                color: const Color(0xffffb347),
                size: 22.sp,
              ),
            ),
            SizedBox(height: 4.h),
            Text(
              'nudge',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 10.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FriendChip extends StatelessWidget {
  const _FriendChip({
    required this.name,
    required this.profilePhotoUrl,
    required this.profilePhotoBase64,
    required this.avatarAsset,
    required this.availability,
    required this.isSpeaking,
    required this.dimmed,
    required this.connectionQuality,
  });

  final String name;
  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final String? avatarAsset;
  final MemberAvailability availability;
  final bool isSpeaking;

  /// True when the whole group is offline — greys out the avatar so the
  /// main button's nudge-trigger state reads clearly.
  final bool dimmed;
  final ConnectionQuality connectionQuality;

  @override
  Widget build(BuildContext context) {
    final live = availability.isLive;
    final degradedNetwork =
        connectionQuality == ConnectionQuality.poor ||
        connectionQuality == ConnectionQuality.lost;
    final shortName = name.trim().split(RegExp(r'\s+')).first;
    final initial = name.trim().isEmpty
        ? '?'
        : name.trim().substring(0, 1).toUpperCase();
    final ringColor = isSpeaking
        ? const Color(0xff7CFF6B)
        : live
        ? const Color(0xff7CFF6B)
        : Colors.white24;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 220),
      // Greys out the avatar row when the whole group is offline, so the
      // nudge-trigger state of the main button reads clearly at a glance.
      opacity: dimmed ? 0.4 : 1,
      child: Column(
        children: [
          Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (isSpeaking)
                const _TalkingPulseRing(color: Color(0xff7CFF6B), size: 60),
              Container(
                width: 52.w,
                height: 52.w,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xff2a2a2a),
                  border: Border.all(
                    color: ringColor,
                    width: isSpeaking ? 2.5 : 2,
                  ),
                ),
                child: ClipOval(
                  child: ProfileAvatar(
                    profilePhotoUrl: profilePhotoUrl,
                    profilePhotoBase64: profilePhotoBase64,
                    avatarAsset: avatarAsset,
                    radius: 26.w,
                    backgroundColor: const Color(0xff2a2a2a),
                    fallback: Text(
                      initial,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18.sp,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: -4,
                bottom: -2,
                child: Text(
                  live ? '🟢' : '🌙',
                  style: TextStyle(fontSize: 14.sp),
                ),
              ),
            ],
          ),
          SizedBox(height: 4.h),
          SizedBox(
            width: 72.w,
            child: Text(
              isSpeaking ? '🗣️ talking' : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isSpeaking ? const Color(0xff7CFF6B) : Colors.white70,
                fontSize: 10.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (degradedNetwork && !isSpeaking) ...[
            SizedBox(height: 2.h),
            SizedBox(
              width: 72.w,
              child: Text(
                "${shortName.isEmpty ? 'Their' : shortName}'s network is low",
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: const Color(0xffffb347),
                  fontSize: 8.sp,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TalkingPulseRing extends StatefulWidget {
  const _TalkingPulseRing({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  State<_TalkingPulseRing> createState() => _TalkingPulseRingState();
}

class _TalkingPulseRingState extends State<_TalkingPulseRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        final scale = 1 + (0.18 * t);
        final opacity = (1 - t).clamp(0.0, 1.0);
        return Transform.scale(
          scale: scale,
          child: Container(
            width: widget.size.w,
            height: widget.size.w,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: widget.color.withValues(alpha: 0.55 * opacity),
                width: 2,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _NetworkStrengthIndicator extends StatelessWidget {
  const _NetworkStrengthIndicator({
    required this.quality,
    required this.tooltip,
  });

  final ConnectionQuality quality;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final activeBars = switch (quality) {
      ConnectionQuality.excellent => 4,
      ConnectionQuality.good => 3,
      ConnectionQuality.poor => 1,
      ConnectionQuality.lost => 0,
      ConnectionQuality.unknown => 0,
    };
    final color = switch (quality) {
      ConnectionQuality.excellent => const Color(0xff7CFF6B),
      ConnectionQuality.good => Colors.white,
      ConnectionQuality.poor => const Color(0xffffb347),
      ConnectionQuality.lost => const Color(0xffff5a5f),
      ConnectionQuality.unknown => Colors.white38,
    };

    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 26.w,
        height: 30.w,
        child: Center(
          child: quality == ConnectionQuality.lost
              ? Icon(Icons.signal_cellular_off, color: color, size: 18.sp)
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    for (var bar = 0; bar < 4; bar++)
                      Container(
                        width: 3.w,
                        height: (6 + bar * 3).h,
                        margin: EdgeInsets.only(right: bar == 3 ? 0 : 1.5.w),
                        decoration: BoxDecoration(
                          color: bar < activeBars ? color : Colors.white24,
                          borderRadius: BorderRadius.circular(1.r),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class _AddFriendChip extends StatelessWidget {
  const _AddFriendChip({required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: Column(
          children: [
            Container(
              width: 52.w,
              height: 52.w,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white54, width: 1.5),
              ),
              child: Icon(Icons.add, color: Colors.white, size: 24.sp),
            ),
            SizedBox(height: 4.h),
            Text(
              'invite',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 10.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Call / walkie-talkie mode toggle. Only rendered by the parent once at
/// least one member of the group is online — see the `AnimatedSize` wrapper
/// in `_HomeScreenState.build`.
class _CallModeControls extends StatelessWidget {
  const _CallModeControls({
    required this.active,
    required this.enabled,
    required this.accent,
    required this.onToggle,
  });

  // Conversation mode: whether the local user is currently in call mode
  // (always-on mic) rather than the default walkie-talkie (push-to-talk).
  // This reflects only the local user's own connection.
  final bool active;
  final bool enabled;
  final Color accent;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: GestureDetector(
        onTap: enabled ? onToggle : null,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 10.h),
          decoration: BoxDecoration(
            color: const Color(0xd91a1a1a),
            borderRadius: BorderRadius.circular(24.r),
            border: Border.all(color: active ? accent : Colors.white12),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                active
                    ? Icons.settings_voice_rounded
                    : Icons.record_voice_over_rounded,
                size: 18.sp,
                color: active ? accent : Colors.white70,
              ),
              SizedBox(width: 8.w),
              Text(
                active
                    ? 'In a call — tap for walkie-talkie'
                    : 'Tap for call mode',
                style: TextStyle(
                  color: active ? accent : Colors.white70,
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Page-indicator dots shown below the group carousel when the user has
/// more than one group, so position/count is obvious at a glance.
class _CarouselDotIndicator extends StatelessWidget {
  const _CarouselDotIndicator({required this.count, required this.index});

  final int count;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (var i = 0; i < count; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            margin: EdgeInsets.symmetric(horizontal: 3.w),
            width: i == index ? 16.w : 6.w,
            height: 6.w,
            decoration: BoxDecoration(
              color: i == index
                  ? Colors.white
                  : const Color.fromRGBO(255, 255, 255, 0.35),
              borderRadius: BorderRadius.circular(3.r),
            ),
          ),
      ],
    );
  }
}

class _ExperienceCarousel extends StatefulWidget {
  const _ExperienceCarousel({
    required this.items,
    required this.index,
    required this.connectedGroupId,
    required this.talkEnabled,
    required this.talkActive,
    required this.talkBusy,
    required this.accent,
    required this.nudgeGroupId,
    required this.onNudge,
    required this.onSelected,
    required this.onTalkStart,
    required this.onTalkStop,
    required this.onJoinVoiceGroup,
    required this.onCreateGroup,
    required this.onJoinGroup,
  });

  final List<_CarouselItem> items;
  final int index;
  final String? connectedGroupId;
  final bool talkEnabled;
  final bool talkActive;
  final bool talkBusy;
  final Color accent;

  /// Group id of the focused card when the whole group (self included) is
  /// offline — the main circle becomes a nudge trigger for that card instead
  /// of the normal join/talk control. Null when no card should show that
  /// state (mixed or all-online).
  final String? nudgeGroupId;
  final VoidCallback? onNudge;
  final ValueChanged<int> onSelected;
  final Future<void> Function() onTalkStart;
  final Future<void> Function() onTalkStop;
  final VoidCallback onJoinVoiceGroup;
  final VoidCallback onCreateGroup;
  final VoidCallback onJoinGroup;

  @override
  State<_ExperienceCarousel> createState() => _ExperienceCarouselState();
}

class _ExperienceCarouselState extends State<_ExperienceCarousel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _settleController = AnimationController(
    vsync: this,
  );
  late double _position = widget.index.toDouble();
  Animation<double>? _settleAnimation;
  double _itemSpacing = 64;
  int? _selectionAfterSettle;

  @override
  void initState() {
    super.initState();
    _settleController.addListener(_onSettleTick);
    _settleController.addStatusListener(_onSettleStatus);
  }

  @override
  void didUpdateWidget(covariant _ExperienceCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.items.isEmpty) {
      _settleController.stop();
      _position = 0;
      return;
    }

    final lastIndex = widget.items.length - 1;
    _position = _position.clamp(0, lastIndex).toDouble();
    if (widget.index != oldWidget.index &&
        widget.index != _position.round() &&
        !_settleController.isAnimating) {
      _animateTo(widget.index, notifySelection: false);
    }
  }

  @override
  void dispose() {
    _settleController
      ..removeListener(_onSettleTick)
      ..removeStatusListener(_onSettleStatus)
      ..dispose();
    super.dispose();
  }

  void _onSettleTick() {
    final animation = _settleAnimation;
    if (animation == null || !mounted) return;
    setState(() => _position = animation.value);
  }

  void _onSettleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    final selection = _selectionAfterSettle;
    _selectionAfterSettle = null;
    if (selection == null || selection == widget.index) return;
    unawaited(HapticFeedback.selectionClick());
    widget.onSelected(selection);
  }

  void _animateTo(int target, {required bool notifySelection}) {
    if (widget.items.isEmpty) return;
    final resolvedTarget = target.clamp(0, widget.items.length - 1);
    final distance = (_position - resolvedTarget).abs();

    _settleController.stop();
    _selectionAfterSettle = notifySelection ? resolvedTarget : null;
    _settleController.duration = Duration(
      milliseconds: (220 + distance * 45).clamp(220, 420).round(),
    );
    _settleAnimation =
        Tween<double>(begin: _position, end: resolvedTarget.toDouble()).animate(
          CurvedAnimation(
            parent: _settleController,
            curve: Curves.easeOutCubic,
          ),
        );
    _settleController.forward(from: 0);
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _selectionAfterSettle = null;
    _settleController.stop();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (widget.items.length < 2) return;
    final next = _position - details.delta.dx / _itemSpacing;
    setState(() {
      _position = next.clamp(0, widget.items.length - 1).toDouble();
    });
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (widget.items.isEmpty) return;
    final projected = _position - details.velocity.pixelsPerSecond.dx / 1000;
    _animateTo(projected.round(), notifySelection: true);
  }

  void _onHorizontalDragCancel() {
    if (widget.items.isEmpty) return;
    _animateTo(_position.round(), notifySelection: true);
  }

  Widget _buildGroupCircle(int itemIndex, double spacing) {
    final item = widget.items[itemIndex];
    final delta = itemIndex - _position;
    final distance = delta.abs();
    final visualFocus = _position.round().clamp(0, widget.items.length - 1);
    final visuallySelected = itemIndex == visualFocus;
    final actuallySelected = itemIndex == widget.index;
    final scale = (1 / (1 + distance * 0.46)).clamp(0.4, 1.0);
    final opacity = (1 - distance * 0.18).clamp(0.28, 1.0);
    final rotationY = (delta * -0.26).clamp(-0.62, 0.62);

    Widget circle = _MainAvatarCircle(
      item: item,
      selected: visuallySelected,
      connected: item.group.groupId == widget.connectedGroupId,
      talkEnabled: widget.talkEnabled && actuallySelected && distance < 0.45,
      joinEnabled:
          actuallySelected &&
          distance < 0.45 &&
          widget.connectedGroupId != null &&
          item.group.groupId != widget.connectedGroupId,
      talkActive: widget.talkActive && actuallySelected,
      talkBusy: widget.talkBusy,
      accent: widget.accent,
      nudgeMode:
          actuallySelected &&
          distance < 0.45 &&
          widget.nudgeGroupId != null &&
          item.group.groupId == widget.nudgeGroupId,
      onNudge: widget.onNudge,
      onTalkStart: widget.onTalkStart,
      onTalkStop: widget.onTalkStop,
      onJoin: widget.onJoinVoiceGroup,
    );

    if (!actuallySelected) {
      circle = Semantics(
        button: true,
        label: 'Select ${item.group.name} group',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _animateTo(itemIndex, notifySelection: true),
          child: circle,
        ),
      );
    }

    return Positioned.fill(
      child: Center(
        child: Transform.translate(
          offset: Offset(delta * spacing, distance * 7.h),
          child: Opacity(
            opacity: opacity,
            child: Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0014)
                ..rotateY(rotationY),
              child: Transform.scale(scale: scale, child: circle),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return Row(
        children: [
          SizedBox(width: 16.w),
          _DashedAddCircle(
            onTap: widget.onJoinGroup,
            compact: true,
            label: '+ join\ngroup',
          ),
          const Spacer(),
          _DashedAddCircle(
            onTap: widget.onCreateGroup,
            compact: true,
            label: '+ create\nnew group',
          ),
          SizedBox(width: 16.w),
        ],
      );
    }

    return Row(
      children: [
        SizedBox(width: 12.w),
        _DashedAddCircle(
          onTap: widget.onJoinGroup,
          compact: true,
          label: '+ join\ngroup',
        ),
        SizedBox(width: 8.w),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final spacing = (constraints.maxWidth * 0.34).clamp(52.w, 70.w);
              _itemSpacing = spacing;
              final paintOrder =
                  List<int>.generate(
                    widget.items.length,
                    (itemIndex) => itemIndex,
                  )..sort((a, b) {
                    final aDistance = (a - _position).abs();
                    final bDistance = (b - _position).abs();
                    return bDistance.compareTo(aDistance);
                  });

              return ClipRect(
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [
                            Colors.transparent,
                            Color(0x40FFFFFF),
                            Colors.white,
                            Colors.white,
                            Color(0x40FFFFFF),
                            Colors.transparent,
                          ],
                          stops: [0, 0.08, 0.22, 0.78, 0.92, 1],
                        ).createShader(bounds),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: _onHorizontalDragStart,
                          onHorizontalDragUpdate: _onHorizontalDragUpdate,
                          onHorizontalDragEnd: _onHorizontalDragEnd,
                          onHorizontalDragCancel: _onHorizontalDragCancel,
                          child: Stack(
                            clipBehavior: Clip.hardEdge,
                            children: [
                              for (final itemIndex in paintOrder)
                                _buildGroupCircle(itemIndex, spacing),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: 52.w,
                      child: const _CarouselEdgeVeil(leftEdge: true),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: 52.w,
                      child: const _CarouselEdgeVeil(leftEdge: false),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        SizedBox(width: 8.w),
        _DashedAddCircle(
          onTap: widget.onCreateGroup,
          compact: true,
          label: '+ create\nnew group',
        ),
        SizedBox(width: 12.w),
      ],
    );
  }
}

class _CarouselEdgeVeil extends StatelessWidget {
  const _CarouselEdgeVeil({required this.leftEdge});

  final bool leftEdge;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => LinearGradient(
          begin: leftEdge ? Alignment.centerLeft : Alignment.centerRight,
          end: leftEdge ? Alignment.centerRight : Alignment.centerLeft,
          colors: const [Colors.white, Color(0x99FFFFFF), Colors.transparent],
          stops: const [0, 0.35, 1],
        ).createShader(bounds),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
      ),
    );
  }
}

class _MainAvatarCircle extends StatelessWidget {
  const _MainAvatarCircle({
    required this.item,
    required this.selected,
    required this.connected,
    required this.talkEnabled,
    required this.joinEnabled,
    required this.talkActive,
    required this.talkBusy,
    required this.accent,
    required this.nudgeMode,
    required this.onNudge,
    required this.onTalkStart,
    required this.onTalkStop,
    required this.onJoin,
  });

  final _CarouselItem item;
  final bool selected;
  final bool connected;
  final bool talkEnabled;
  final bool joinEnabled;
  final bool talkActive;
  final bool talkBusy;
  final Color accent;

  /// True when the whole group is offline and this is the focused card —
  /// the circle becomes a nudge trigger instead of join/talk, with member
  /// photos dimmed and a subtle sleeping "Z" animation.
  final bool nudgeMode;
  final VoidCallback? onNudge;
  final Future<void> Function() onTalkStart;
  final Future<void> Function() onTalkStop;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final size = 110.w;

    Widget circle = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: connected
              ? const Color(0xff28A745)
              : nudgeMode
              ? Colors.white38
              : Colors.white,
          width: connected ? 4 : (selected ? 2.5 : 2),
        ),
      ),
      child: ClipOval(
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedOpacity(
              duration: const Duration(milliseconds: 220),
              opacity: nudgeMode ? 0.4 : 1,
              child: _MemberPhotoCollage(
                members: item.members,
                fallbackPhotoUrl: item.profilePhotoUrl,
                fallbackPhotoBase64: item.profilePhotoBase64,
                fallbackAvatarAsset: item.avatarAsset,
                tileSize: size,
              ),
            ),
            if (nudgeMode)
              Positioned(
                right: size * 0.08,
                top: size * 0.06,
                child: _SleepZAnimation(size: size * 0.3),
              ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(bottom: size * 0.08),
                child: Icon(
                  nudgeMode ? Icons.notifications_active_rounded : Icons.mic,
                  color: talkActive
                      ? const Color(0xffffd54f)
                      : nudgeMode
                      ? const Color(0xffffb347)
                      : Colors.white,
                  size: talkActive ? size * 0.22 : size * 0.18,
                ),
              ),
            ),
          ],
        ),
      ),
    );

    if (talkEnabled || joinEnabled || nudgeMode) {
      circle = Semantics(
        button: true,
        label: joinEnabled
            ? 'Join ${item.group.name}'
            : nudgeMode
            ? 'Nudge ${item.group.name}'
            : talkActive
            ? 'Stop talking'
            : 'Tap to Talk',
        child: GestureDetector(
          onTap: talkBusy
              ? null
              : () {
                  if (nudgeMode) {
                    onNudge?.call();
                    return;
                  }
                  if (joinEnabled) {
                    onJoin();
                    return;
                  }
                  if (talkActive) {
                    unawaited(onTalkStop());
                  } else {
                    unawaited(onTalkStart());
                  }
                },
          child: circle,
        ),
      );
    }

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: talkBusy ? 0.65 : 1,
      child: circle,
    );
  }
}

/// Subtle looping "Z"s drifting up and fading, indicating the group is
/// asleep (fully offline) and the main button is now a nudge trigger.
class _SleepZAnimation extends StatefulWidget {
  const _SleepZAnimation({required this.size});

  final double size;

  @override
  State<_SleepZAnimation> createState() => _SleepZAnimationState();
}

class _SleepZAnimationState extends State<_SleepZAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Stack(
              clipBehavior: Clip.none,
              children: [for (var i = 0; i < 2; i++) _buildZ(i)],
            );
          },
        ),
      ),
    );
  }

  Widget _buildZ(int i) {
    // Two "Z"s staggered half a cycle apart, each drifting up-and-right
    // while fading out, then looping.
    final t = ((_controller.value + i * 0.5) % 1.0);
    final opacity = t < 0.15
        ? t / 0.15
        : t > 0.75
        ? (1 - t) / 0.25
        : 1.0;
    return Positioned(
      right: -t * widget.size * 0.4,
      top: widget.size * 0.5 - t * widget.size * 0.9,
      child: Opacity(
        opacity: opacity.clamp(0.0, 1.0),
        child: Text(
          'z',
          style: TextStyle(
            color: Colors.white70,
            fontSize: (widget.size * (0.35 + i * 0.15)),
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// Tiles up to [_maxTiles] group members' photos inside the connect circle
/// so it's obvious at a glance which group/members you're about to connect
/// with. Falls back to a single self-avatar when member data isn't loaded
/// yet (e.g. for a group that isn't focused in the carousel).
class _MemberPhotoCollage extends StatelessWidget {
  const _MemberPhotoCollage({
    required this.members,
    required this.fallbackPhotoUrl,
    required this.fallbackPhotoBase64,
    required this.fallbackAvatarAsset,
    required this.tileSize,
  });

  static const int _maxTiles = 4;

  final List<GroupMemberSummary> members;
  final String? fallbackPhotoUrl;
  final String? fallbackPhotoBase64;
  final String? fallbackAvatarAsset;
  final double tileSize;

  @override
  Widget build(BuildContext context) {
    if (members.isEmpty) {
      return ProfileImage(
        profilePhotoUrl: fallbackPhotoUrl,
        profilePhotoBase64: fallbackPhotoBase64,
        avatarAsset: fallbackAvatarAsset,
        backgroundColor: const Color(0xff2a2a2a),
        fadeInDuration: Duration.zero,
        fallback: Icon(
          Icons.person_outline,
          color: Colors.white70,
          size: tileSize * 0.4,
        ),
      );
    }

    final tiles = members.take(_maxTiles).toList(growable: false);
    final overflow = members.length - tiles.length;

    Widget tile(GroupMemberSummary member) {
      final initial = member.displayName.trim().isEmpty
          ? '?'
          : member.displayName.trim().substring(0, 1).toUpperCase();
      return ProfileImage(
        profilePhotoUrl: member.profilePhotoUrl,
        profilePhotoBase64: member.profilePhotoBase64,
        avatarAsset: member.avatarAsset,
        backgroundColor: const Color(0xff2a2a2a),
        fadeInDuration: Duration.zero,
        fallback: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: tileSize * 0.16,
            fontWeight: FontWeight.w700,
          ),
        ),
      );
    }

    Widget grid;
    switch (tiles.length) {
      case 1:
        grid = tile(tiles[0]);
      case 2:
        grid = Row(
          children: [
            Expanded(child: tile(tiles[0])),
            _CollageDivider(vertical: true, length: tileSize),
            Expanded(child: tile(tiles[1])),
          ],
        );
      case 3:
        grid = Column(
          children: [
            Expanded(child: tile(tiles[0])),
            _CollageDivider(vertical: false, length: tileSize),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tile(tiles[1])),
                  _CollageDivider(vertical: true, length: tileSize / 2),
                  Expanded(child: tile(tiles[2])),
                ],
              ),
            ),
          ],
        );
      default:
        grid = Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tile(tiles[0])),
                  _CollageDivider(vertical: true, length: tileSize / 2),
                  Expanded(child: tile(tiles[1])),
                ],
              ),
            ),
            _CollageDivider(vertical: false, length: tileSize),
            Expanded(
              child: Row(
                children: [
                  Expanded(child: tile(tiles[2])),
                  _CollageDivider(vertical: true, length: tileSize / 2),
                  Expanded(child: tile(tiles[3])),
                ],
              ),
            ),
          ],
        );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        grid,
        if (overflow > 0)
          Positioned(
            right: tileSize * 0.06,
            bottom: tileSize * 0.06,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: tileSize * 0.05,
                vertical: tileSize * 0.02,
              ),
              decoration: BoxDecoration(
                color: const Color.fromRGBO(0, 0, 0, 0.7),
                borderRadius: BorderRadius.circular(tileSize * 0.08),
              ),
              child: Text(
                '+$overflow',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: tileSize * 0.09,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _CollageDivider extends StatelessWidget {
  const _CollageDivider({required this.vertical, required this.length});

  final bool vertical;
  final double length;

  @override
  Widget build(BuildContext context) {
    const color = Color.fromRGBO(0, 0, 0, 0.55);
    return vertical
        ? SizedBox(
            width: length * 0.014,
            height: length,
            child: const ColoredBox(color: color),
          )
        : SizedBox(
            width: length,
            height: length * 0.014,
            child: const ColoredBox(color: color),
          );
  }
}

class _DashedAddCircle extends StatelessWidget {
  const _DashedAddCircle({
    required this.onTap,
    required this.compact,
    required this.label,
  });

  final VoidCallback? onTap;
  final bool compact;
  final String label;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 72.w : 110.w;
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.45 : 1,
        child: CustomPaint(
          painter: _DashedCirclePainter(
            color: const Color.fromRGBO(255, 255, 255, 0.7),
          ),
          child: SizedBox(
            width: size,
            height: size,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(10.w),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: compact ? 9.sp : 12.sp,
                    fontWeight: FontWeight.w600,
                    height: 1.15,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedCirclePainter extends CustomPainter {
  const _DashedCirclePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    final radius = size.shortestSide / 2;
    const dashCount = 28;
    const dashSweep = 0.12;
    const gapSweep = (6.28318530718 / dashCount) - dashSweep;
    var start = 0.0;

    for (var i = 0; i < dashCount; i++) {
      canvas.drawArc(
        Rect.fromCircle(center: size.center(Offset.zero), radius: radius),
        start,
        dashSweep,
        false,
        paint,
      );
      start += dashSweep + gapSweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DashedCirclePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

class _CarouselItem {
  const _CarouselItem({
    required this.group,
    required this.displayName,
    required this.availability,
    this.profilePhotoUrl,
    this.profilePhotoBase64,
    this.avatarAsset,
    this.members = const [],
  });

  factory _CarouselItem.group({
    required GroupSummary group,
    required String displayName,
    required String? profilePhotoUrl,
    required String? profilePhotoBase64,
    required String? avatarAsset,
    required MemberAvailability availability,
    List<GroupMemberSummary> members = const [],
  }) {
    return _CarouselItem(
      group: group,
      displayName: displayName,
      profilePhotoUrl: profilePhotoUrl,
      profilePhotoBase64: profilePhotoBase64,
      avatarAsset: avatarAsset,
      availability: availability,
      members: members,
    );
  }

  final GroupSummary group;
  final String displayName;
  final MemberAvailability availability;
  final String? profilePhotoUrl;
  final String? profilePhotoBase64;
  final String? avatarAsset;

  /// Group members loaded for this group (only populated for the
  /// currently-selected/focused group). Used to render a photo collage on
  /// the connect circle so it's obvious at a glance who you're joining.
  final List<GroupMemberSummary> members;
}

class _SetupLine extends StatelessWidget {
  const _SetupLine({required this.ok, required this.text});

  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.error_outline,
            color: ok ? colors.primary : colors.error,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
