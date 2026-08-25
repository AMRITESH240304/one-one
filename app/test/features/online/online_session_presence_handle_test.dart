import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  test('round-trips presence handles used after a process kill', () {
    const session = OnlineSession(
      groupId: 'g1',
      userId: 'u1',
      deviceId: 'd1',
      serviceSessionId: 's1',
      livekitSessionId: 'lk1',
      livekitServerUrl: 'wss://example',
      livekitToken: 'token',
      livekitRoomName: 'room',
      participantIdentity: 'g1:u1:lk1',
      startedAt: 100,
    );

    final restored = OnlineSession.fromPresenceHandle(session.toPresenceHandle());
    expect(restored?.groupId, 'g1');
    expect(restored?.userId, 'u1');
    expect(restored?.serviceSessionId, 's1');
    expect(restored?.livekitSessionId, 'lk1');
  });

  test('rejects incomplete presence handles', () {
    expect(
      OnlineSession.fromPresenceHandle({'groupId': 'g1', 'userId': 'u1'}),
      isNull,
    );
  });
}
