import 'package:livekit_client/livekit_client.dart';

import 'log_level.dart';
import 'log_manager.dart';

/// Adds structured device logs to an existing LiveKit room listener.
EventsListener<RoomEvent> attachLiveKitLifecycleLogs(
  EventsListener<RoomEvent> listener, {
  String? userId,
  String? groupId,
}) {
  const tag = 'LiveKitManager';
  void write(LogLevel level, String message) {
    LogManager.log(level, tag, message, userId: userId, groupId: groupId);
  }

  return listener
    ..on<RoomConnectedEvent>((event) {
      write(
        LogLevel.info,
        'Room connected name=${event.room.name}',
      );
    })
    ..on<RoomReconnectingEvent>((_) {
      write(LogLevel.warn, 'Room reconnecting');
    })
    ..on<RoomReconnectedEvent>((_) {
      write(LogLevel.info, 'Room reconnected');
    })
    ..on<RoomDisconnectedEvent>((event) {
      write(
        LogLevel.warn,
        'Room disconnected reason=${event.reason?.name ?? 'unknown'}',
      );
    })
    ..on<ParticipantConnectedEvent>((event) {
      write(
        LogLevel.info,
        'Participant joined identity=${event.participant.identity} '
        'sid=${event.participant.sid}',
      );
    })
    ..on<ParticipantDisconnectedEvent>((event) {
      write(
        LogLevel.info,
        'Participant left identity=${event.participant.identity} '
        'sid=${event.participant.sid}',
      );
    })
    ..on<TrackPublishedEvent>((event) {
      write(
        LogLevel.info,
        'Track published kind=${event.publication.kind.name} '
        'sid=${event.publication.sid} '
        'participant=${event.participant.identity}',
      );
    })
    ..on<LocalTrackPublishedEvent>((event) {
      write(
        LogLevel.info,
        'Local track published kind=${event.publication.kind.name} '
        'sid=${event.publication.sid}',
      );
    })
    ..on<TrackSubscribedEvent>((event) {
      write(
        LogLevel.info,
        'Track subscribed kind=${event.publication.kind.name} '
        'sid=${event.publication.sid} '
        'participant=${event.participant.identity}',
      );
    })
    ..on<TrackSubscriptionExceptionEvent>((event) {
      write(
        LogLevel.error,
        'Track failed sid=${event.sid} '
        'reason=${event.reason.name}',
      );
    });
}

