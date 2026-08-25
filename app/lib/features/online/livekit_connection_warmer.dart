import 'package:one_one_app/one_one.dart';

/// Warms up everything that is safe to prepare *before* a user actually
/// accepts a nudge and goes online — without ever calling `Room.connect()`.
///
/// Doing this ahead of the accept removes several sources of latency from the
/// critical path:
///  * the LiveKit token backend round-trip (cached until accept),
///  * the Flutter [Room] object + noise-filter/audio-route construction,
///  * DNS + TLS to the LiveKit server (`Room.prepareConnection`),
///  * the WebRTC native library load (touched once at app start).
///
/// None of the warm-up work joins a room, so it costs zero participant
/// minutes.
class LiveKitConnectionWarmer {
  LiveKitConnectionWarmer._();

  static final LiveKitConnectionWarmer instance = LiveKitConnectionWarmer._();

  bool _webRtcInitialized = false;
  Future<void>? _webRtcInitFuture;

  final Map<String, PreparedLiveKitToken> _tokens = {};

  Room? _warmRoom;
  bool? _warmRoomSpeakerOn;

  /// Touch-loads the WebRTC native library once. Idempotent: the first call
  /// wins and subsequent callers await the same in-flight future.
  Future<void> ensureWebRtcInitialized() {
    if (_webRtcInitialized) return Future<void>.value();
    return _webRtcInitFuture ??= _initializeWebRtc();
  }

  Future<void> _initializeWebRtc() async {
    try {
      await LiveKitClient.initialize();
    } catch (_) {
      // Non-fatal. The SDK falls back to default initialization on first use.
    } finally {
      _webRtcInitialized = true;
      _webRtcInitFuture = null;
    }
  }

  /// Returns a usable prefetched token for [groupId], consuming it from the
  /// cache (tokens are single-use). Returns null when nothing was prefetched
  /// or the token has expired.
  PreparedLiveKitToken? takeToken(String groupId) {
    final prepared = _tokens[groupId];
    if (prepared == null) return null;
    if (!prepared.isUsableAt(_nowSeconds())) {
      _tokens.remove(groupId);
      return null;
    }
    _tokens.remove(groupId);
    return prepared;
  }

  /// Prefetches a LiveKit token for [group] and warms DNS/TLS plus a reusable
  /// [Room] object. Call this from the sender (when a nudge is sent) and from
  /// the receiver (when the FCM nudge arrives) so the later accept is fast.
  Future<void> prefetch({
    required OnlineRepository repository,
    required IdentitySession identity,
    required GroupSummary group,
    required bool speakerOn,
  }) async {
    await ensureWebRtcInitialized();

    final PreparedLiveKitToken prepared;
    try {
      prepared = await repository.prepareToken(
        groupId: group.groupId,
        deviceId: identity.deviceId,
      );
    } catch (_) {
      // Best-effort. A failed prefetch must never surface to the user; the
      // real go-online path fetches a token synchronously if needed.
      return;
    }

    _tokens[group.groupId] = prepared;

    // Warm DNS + TLS to the LiveKit server without joining a room.
    final room = _buildWarmRoom(speakerOn: speakerOn);
    _warmRoom = room;
    _warmRoomSpeakerOn = speakerOn;
    try {
      await room.prepareConnection(
        prepared.response.serverUrl,
        prepared.response.token,
      );
    } catch (_) {
      // `prepareConnection` is best-effort and already swallows most errors.
    }
  }

  /// Returns a pre-created [Room] with the requested speaker route if one was
  /// warmed, otherwise null. Ownership transfers to the caller, which must
  /// attach its listener and connect. The cached warm room is consumed.
  Room? takeWarmRoom({required bool speakerOn}) {
    final room = _warmRoom;
    if (room == null) return null;

    _warmRoom = null;
    final matchesSpeaker = _warmRoomSpeakerOn == speakerOn;
    _warmRoomSpeakerOn = null;

    if (!matchesSpeaker) {
      // Wrong audio route for this attempt — discard and let the caller build.
      unawaited(room.dispose());
      return null;
    }
    return room;
  }

  Room _buildWarmRoom({required bool speakerOn}) {
    final noiseFilter = LiveKitNoiseFilter();
    return Room(
      roomOptions: RoomOptions(
        adaptiveStream: false,
        dynacast: false,
        defaultAudioOutputOptions: AudioOutputOptions(speakerOn: speakerOn),
        defaultAudioCaptureOptions: AudioCaptureOptions(processor: noiseFilter),
      ),
    );
  }

  int _nowSeconds() =>
      DateTime.now().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;
}
