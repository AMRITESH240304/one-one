import 'package:firebase_database/firebase_database.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:uuid/uuid.dart';

import '../../../core/firebase/app_database.dart';
import '../../../core/network/api_client.dart';
import '../../groups/models/group_summary.dart';
import '../../identity/models/identity_session.dart';
import '../models/livekit_token_response.dart';
import '../models/member_availability.dart';
import '../models/online_session.dart';
import '../models/prepared_livekit_token.dart';

class OnlineRepository {
  OnlineRepository({ApiClient? apiClient, FirebaseDatabase? database})
    : _apiClient = apiClient ?? ApiClient(),
      _database = database ?? AppDatabase.instance();

  final ApiClient _apiClient;
  final FirebaseDatabase _database;

  Future<OnlineSession> goOnline({
    required IdentitySession identity,
    required GroupSummary group,
    String connectionMode = MemberAvailability.walkieTalkieMode,
    PreparedLiveKitToken? preparedToken,
  }) async {
    await _requestOnlinePermissions();

    final now = _nowSeconds();
    final String serviceSessionId;
    final String livekitSessionId;
    final LiveKitTokenResponse token;

    if (preparedToken != null && preparedToken.isUsableAt(now)) {
      serviceSessionId = preparedToken.serviceSessionId;
      livekitSessionId = preparedToken.livekitSessionId;
      token = preparedToken.response;
    } else {
      serviceSessionId = const Uuid().v4();
      livekitSessionId = const Uuid().v4();
      token = await _requestLiveKitToken(
        groupId: group.groupId,
        deviceId: identity.deviceId,
        serviceSessionId: serviceSessionId,
        livekitSessionId: livekitSessionId,
      );
    }

    final session = OnlineSession(
      groupId: group.groupId,
      userId: identity.userId,
      deviceId: identity.deviceId,
      serviceSessionId: serviceSessionId,
      livekitSessionId: livekitSessionId,
      livekitServerUrl: token.serverUrl,
      livekitToken: token.token,
      livekitRoomName: token.roomName,
      participantIdentity: token.participantIdentity,
      startedAt: now,
    );

    await _database.ref().update({
      'appServiceSessions/$serviceSessionId': {
        'groupId': group.groupId,
        'userId': identity.userId,
        'deviceId': identity.deviceId,
        'serviceState': 'starting',
        'startReason': 'user_online',
        'stopReason': null,
        'startedAt': now,
        'stoppedAt': null,
        'lastHeartbeatAt': now,
      },
      'livekitSessions/$livekitSessionId': {
        'serviceSessionId': serviceSessionId,
        'livekitRoomId': group.groupId,
        'groupId': group.groupId,
        'userId': identity.userId,
        'deviceId': identity.deviceId,
        'participantIdentity': token.participantIdentity,
        'participantName': token.participantName,
        'connectionState': 'connecting',
        'connectedAt': null,
        'disconnectedAt': null,
        'lastStateChangedAt': now,
      },
      'memberAvailability/${group.groupId}/${identity.userId}': {
        'activeDeviceId': identity.deviceId,
        'activeServiceSessionId': serviceSessionId,
        'activeLivekitSessionId': livekitSessionId,
        'desiredState': 'online',
        'effectiveState': 'connecting',
        'serviceState': 'starting',
        'livekitConnectionState': 'connecting',
        'canReceiveLiveAudio': false,
        'connectionMode': connectionMode,
        'lastHeartbeatAt': now,
        'staleAfterAt': now + 30,
        'updatedAt': now,
      },
    });
    await _scheduleAwayOnDisconnect(session);

    return session;
  }

  Future<void> markLive(OnlineSession session) async {
    final now = _nowSeconds();
    await _database.ref().update({
      'appServiceSessions/${session.serviceSessionId}/serviceState': 'running',
      'appServiceSessions/${session.serviceSessionId}/lastHeartbeatAt': now,
      'livekitSessions/${session.livekitSessionId}/connectionState':
          'connected',
      'livekitSessions/${session.livekitSessionId}/connectedAt': now,
      'livekitSessions/${session.livekitSessionId}/lastStateChangedAt': now,
      'memberAvailability/${session.groupId}/${session.userId}/effectiveState':
          'live',
      'memberAvailability/${session.groupId}/${session.userId}/serviceState':
          'running',
      'memberAvailability/${session.groupId}/${session.userId}/livekitConnectionState':
          'connected',
      'memberAvailability/${session.groupId}/${session.userId}/canReceiveLiveAudio':
          true,
      'memberAvailability/${session.groupId}/${session.userId}/lastHeartbeatAt':
          now,
      'memberAvailability/${session.groupId}/${session.userId}/staleAfterAt':
          now + 30,
      'memberAvailability/${session.groupId}/${session.userId}/updatedAt': now,
    });
  }

  Future<void> heartbeat(
    OnlineSession session, {
    bool isTalking = false,
  }) async {
    final now = _nowSeconds();
    await _database.ref().update({
      'appServiceSessions/${session.serviceSessionId}/lastHeartbeatAt': now,
      'memberAvailability/${session.groupId}/${session.userId}/desiredState':
          'online',
      'memberAvailability/${session.groupId}/${session.userId}/effectiveState':
          isTalking ? 'talking' : 'live',
      'memberAvailability/${session.groupId}/${session.userId}/serviceState':
          'running',
      'memberAvailability/${session.groupId}/${session.userId}/livekitConnectionState':
          'connected',
      'memberAvailability/${session.groupId}/${session.userId}/canReceiveLiveAudio':
          true,
      'memberAvailability/${session.groupId}/${session.userId}/lastHeartbeatAt':
          now,
      'memberAvailability/${session.groupId}/${session.userId}/staleAfterAt':
          now + 30,
      'memberAvailability/${session.groupId}/${session.userId}/updatedAt': now,
    });
  }

  /// Switches a member's own connection between walkie-talkie (push-to-talk)
  /// and call (always-on mic). This is a per-user setting, not a group-wide
  /// mode: it only ever writes the caller's own availability entry.
  Future<void> setConnectionMode(
    OnlineSession session, {
    required String connectionMode,
  }) async {
    await _database.ref().update({
      'memberAvailability/${session.groupId}/${session.userId}/connectionMode':
          connectionMode,
      'memberAvailability/${session.groupId}/${session.userId}/updatedAt':
          _nowSeconds(),
    });
  }

  Future<void> goAway(
    OnlineSession session, {
    String reason = 'user_away',
  }) async {
    final now = _nowSeconds();
    final availabilityRef = _database.ref(
      'memberAvailability/${session.groupId}/${session.userId}',
    );
    final serviceRef = _database.ref(
      'appServiceSessions/${session.serviceSessionId}',
    );
    final liveKitRef = _database.ref(
      'livekitSessions/${session.livekitSessionId}',
    );
    await Future.wait([
      availabilityRef.onDisconnect().cancel(),
      serviceRef.onDisconnect().cancel(),
      liveKitRef.onDisconnect().cancel(),
    ]);

    await _database.ref().update({
      'appServiceSessions/${session.serviceSessionId}/serviceState': 'stopped',
      'appServiceSessions/${session.serviceSessionId}/stopReason': reason,
      'appServiceSessions/${session.serviceSessionId}/stoppedAt': now,
      'appServiceSessions/${session.serviceSessionId}/lastHeartbeatAt': now,
      'livekitSessions/${session.livekitSessionId}/connectionState':
          'disconnected',
      'livekitSessions/${session.livekitSessionId}/disconnectedAt': now,
      'livekitSessions/${session.livekitSessionId}/lastStateChangedAt': now,
      'memberAvailability/${session.groupId}/${session.userId}': {
        'activeDeviceId': null,
        'activeServiceSessionId': null,
        'activeLivekitSessionId': null,
        'desiredState': 'away',
        'effectiveState': 'away',
        'serviceState': 'stopped',
        'livekitConnectionState': 'disconnected',
        'canReceiveLiveAudio': false,
        'connectionMode': MemberAvailability.walkieTalkieMode,
        'lastHeartbeatAt': now,
        'staleAfterAt': now,
        'updatedAt': now,
      },
    });
  }

  /// Clears leftover RTDB presence from a previous process that died mid-session.
  ///
  /// No-ops if another session (or an explicit away write) already replaced
  /// [session.serviceSessionId] as the active handle.
  Future<void> clearAbandonedSession(OnlineSession session) async {
    final snapshot = await _database
        .ref('memberAvailability/${session.groupId}/${session.userId}')
        .get();
    final value = snapshot.value;
    if (value is! Map) return;
    final activeId = value['activeServiceSessionId']?.toString();
    if (activeId != session.serviceSessionId) return;
    await goAway(session, reason: 'process_killed');
  }

  /// Asks the backend to push a "you're offline" alert to this user's devices
  /// after an involuntary leave (peer left, inactivity, usage cap, network).
  Future<void> notifyGoneOffline({
    required OnlineSession session,
    required String reason,
  }) async {
    try {
      await _apiClient.postJson(
        '/v1/groups/${session.groupId}/notifications/gone-offline',
        {
          'deviceId': session.deviceId,
          'reason': reason,
        },
      );
    } catch (_) {
      // Best-effort — RTDB presence is already away; missing the push is
      // non-fatal (foreground snackbars still cover the same cases).
    }
  }

  Future<void> _scheduleAwayOnDisconnect(OnlineSession session) async {
    final now = _nowSeconds();
    final availabilityRef = _database.ref(
      'memberAvailability/${session.groupId}/${session.userId}',
    );
    final serviceRef = _database.ref(
      'appServiceSessions/${session.serviceSessionId}',
    );
    final liveKitRef = _database.ref(
      'livekitSessions/${session.livekitSessionId}',
    );
    await Future.wait([
      serviceRef.onDisconnect().update({
        'serviceState': 'stopped',
        'stopReason': 'network_loss',
        'stoppedAt': now,
        'lastHeartbeatAt': now,
      }),
      liveKitRef.onDisconnect().update({
        'connectionState': 'disconnected',
        'disconnectedAt': now,
        'lastStateChangedAt': now,
      }),
      availabilityRef.onDisconnect().set({
        'activeDeviceId': null,
        'activeServiceSessionId': null,
        'activeLivekitSessionId': null,
        'desiredState': MemberAvailability.away.desiredState,
        'effectiveState': MemberAvailability.away.effectiveState,
        'serviceState': 'stopped',
        'livekitConnectionState': 'disconnected',
        'canReceiveLiveAudio': false,
        'connectionMode': MemberAvailability.walkieTalkieMode,
        'lastHeartbeatAt': 0,
        'staleAfterAt': 0,
        'updatedAt': now,
      }),
    ]);
  }

  Future<LiveKitTokenResponse> _requestLiveKitToken({
    required String groupId,
    required String deviceId,
    required String serviceSessionId,
    required String livekitSessionId,
  }) async {
    final response = await _apiClient.postJson('/v1/livekit/token', {
      'groupId': groupId,
      'deviceId': deviceId,
      'serviceSessionId': serviceSessionId,
      'livekitSessionId': livekitSessionId,
    });
    return LiveKitTokenResponse.fromJson(response);
  }

  /// Fetches a LiveKit token ahead of time (without touching RTDB presence)
  /// so the actual accept can skip the token round-trip. Returns the token
  /// plus the session ids it was issued under, so callers can reuse both for
  /// a fully consistent go-online record.
  Future<PreparedLiveKitToken> prepareToken({
    required String groupId,
    required String deviceId,
  }) async {
    final serviceSessionId = const Uuid().v4();
    final livekitSessionId = const Uuid().v4();
    final token = await _requestLiveKitToken(
      groupId: groupId,
      deviceId: deviceId,
      serviceSessionId: serviceSessionId,
      livekitSessionId: livekitSessionId,
    );
    return PreparedLiveKitToken(
      response: token,
      serviceSessionId: serviceSessionId,
      livekitSessionId: livekitSessionId,
    );
  }

  Future<void> _requestOnlinePermissions() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      throw StateError(
        'Microphone permission is required before going online.',
      );
    }
  }

  int _nowSeconds() {
    return DateTime.now().millisecondsSinceEpoch ~/ 1000;
  }
}
