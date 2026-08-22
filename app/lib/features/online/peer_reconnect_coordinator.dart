import 'dart:async';

import 'presence_config.dart';

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

  void peerLeft(String userId) {
    if (userId.isEmpty) return;
    _pendingLoss[userId]?.cancel();
    _pendingLoss[userId] = Timer(window, () {
      _pendingLoss.remove(userId);
      onLostConnection(userId);
    });
  }

  bool peerJoined(String userId) {
    if (userId.isEmpty) return false;
    final pending = _pendingLoss.remove(userId);
    if (pending == null) return false;
    pending.cancel();
    onBackLive(userId);
    return true;
  }

  void clear() {
    for (final timer in _pendingLoss.values) {
      timer.cancel();
    }
    _pendingLoss.clear();
  }
}
