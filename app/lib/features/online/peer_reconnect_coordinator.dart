import 'package:one_one_app/one_one.dart';

/// Debounces "lost connection" UI when a peer leaves and quickly rejoins
/// (app kill + relaunch, LiveKit identity swap, RTDB onDisconnect race).
///
/// Does not change auto-offline / [SoloParticipantGuard] timers.
class PeerReconnectCoordinator {
  PeerReconnectCoordinator({
    this.window = PresenceConfig.peerRejoinWindow,
    required this.onLostConnection,
    required this.onBackLive,
  });

  final Duration window;
  final void Function(String userId) onLostConnection;
  final void Function(String userId) onBackLive;

  final Map<String, Timer> _pendingLoss = {};
  final Set<String> _lossConfirmed = {};

  void peerLeft(String userId) {
    if (userId.isEmpty) return;
    _pendingLoss[userId]?.cancel();
    _lossConfirmed.remove(userId);
    _pendingLoss[userId] = Timer(window, () {
      _pendingLoss.remove(userId);
      _lossConfirmed.add(userId);
      onLostConnection(userId);
    });
  }

  bool peerJoined(String userId) {
    if (userId.isEmpty) return false;
    final pending = _pendingLoss.remove(userId);
    pending?.cancel();
    if (_lossConfirmed.remove(userId)) {
      onBackLive(userId);
      return true;
    }
    return pending != null;
  }

  void clear() {
    for (final timer in _pendingLoss.values) {
      timer.cancel();
    }
    _pendingLoss.clear();
    _lossConfirmed.clear();
  }
}
