import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/features/online/peer_reconnect_coordinator.dart';

void main() {
  test('suppresses lost connection when the same peer rejoins inside the window', () {
    fakeAsync((async) {
      final lost = <String>[];
      final back = <String>[];
      final coordinator = PeerReconnectCoordinator(
        window: const Duration(seconds: 15),
        onLostConnection: lost.add,
        onBackLive: back.add,
      );

      coordinator.peerLeft('friend');
      async.elapse(const Duration(seconds: 5));
      coordinator.peerJoined('friend');
      async.elapse(const Duration(seconds: 20));

      expect(lost, isEmpty);
      expect(back, ['friend']);
    });
  });

  test('shows lost connection if the peer does not rejoin in time', () {
    fakeAsync((async) {
      final lost = <String>[];
      final back = <String>[];
      final coordinator = PeerReconnectCoordinator(
        window: const Duration(seconds: 15),
        onLostConnection: lost.add,
        onBackLive: back.add,
      );

      coordinator.peerLeft('friend');
      async.elapse(const Duration(seconds: 15));

      expect(lost, ['friend']);
      expect(back, isEmpty);
    });
  });

  test('first join without a prior leave does not show back live', () {
    fakeAsync((async) {
      final back = <String>[];
      final coordinator = PeerReconnectCoordinator(
        window: const Duration(seconds: 15),
        onLostConnection: (_) {},
        onBackLive: back.add,
      );

      coordinator.peerJoined('friend');
      expect(back, isEmpty);
    });
  });
}
