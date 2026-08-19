class OnlineSession {
  const OnlineSession({
    required this.groupId,
    required this.userId,
    required this.deviceId,
    required this.serviceSessionId,
    required this.livekitSessionId,
    required this.livekitServerUrl,
    required this.livekitToken,
    required this.livekitRoomName,
    required this.participantIdentity,
    required this.startedAt,
  });

  final String groupId;
  final String userId;
  final String deviceId;
  final String serviceSessionId;
  final String livekitSessionId;
  final String livekitServerUrl;
  final String livekitToken;
  final String livekitRoomName;
  final String participantIdentity;
  final int startedAt;

  /// Fields needed to clear RTDB presence after a process kill.
  Map<String, String> toPresenceHandle() {
    return {
      'groupId': groupId,
      'userId': userId,
      'deviceId': deviceId,
      'serviceSessionId': serviceSessionId,
      'livekitSessionId': livekitSessionId,
    };
  }

  static OnlineSession? fromPresenceHandle(Map<dynamic, dynamic>? data) {
    if (data == null) return null;
    final groupId = data['groupId']?.toString() ?? '';
    final userId = data['userId']?.toString() ?? '';
    final deviceId = data['deviceId']?.toString() ?? '';
    final serviceSessionId = data['serviceSessionId']?.toString() ?? '';
    final livekitSessionId = data['livekitSessionId']?.toString() ?? '';
    if (groupId.isEmpty ||
        userId.isEmpty ||
        serviceSessionId.isEmpty ||
        livekitSessionId.isEmpty) {
      return null;
    }
    return OnlineSession(
      groupId: groupId,
      userId: userId,
      deviceId: deviceId,
      serviceSessionId: serviceSessionId,
      livekitSessionId: livekitSessionId,
      livekitServerUrl: '',
      livekitToken: '',
      livekitRoomName: '',
      participantIdentity: '',
      startedAt: 0,
    );
  }
}
