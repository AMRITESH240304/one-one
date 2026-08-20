import 'models/media_volume_reading.dart';
import 'nudge_cooldowns.dart';

/// Per-recipient delivery signifier restored when the sheet is reopened.
class LastNudgeRecipientSignifier {
  const LastNudgeRecipientSignifier({
    required this.userId,
    required this.displayName,
    required this.failed,
    this.band,
  });

  final String userId;
  final String displayName;
  final bool failed;
  final MediaVolumeBand? band;
}

/// Lifecycle stage of the most recently sent nudge in a group.
///
/// Unlike [NudgeErrorSeverity]/[NudgeFailureMemory], which only record delivery
/// *failures*, this tracks the full pending lifecycle so the sender can re-open
/// the nudge sheet (or tap the main nudge button) and see where the last nudge
/// stands until the receiver accepts it.
enum LastNudgeStatus { sent, waiting, played, volumeLow, volumeMuted, failed }

/// A single group's most recently sent nudge, ready to render as a status line
/// in the nudge sheet.
class LastNudgeState {
  const LastNudgeState({
    required this.eventId,
    required this.status,
    required this.message,
    required this.at,
    this.kind,
    this.signifiers = const [],
  });

  final String eventId;
  final LastNudgeStatus status;
  final String message;
  final DateTime at;
  final NudgeKind? kind;
  final List<LastNudgeRecipientSignifier> signifiers;
}

/// In-memory (per app process) record of the most recently sent nudge **per
/// group**, so the sender can revisit its status after dismissing the sheet.
/// Scoped by group so a nudge in one group is never shown while viewing a
/// different group.
///
/// The entry is replaced on each new send and cleared as soon as the receiver
/// accepts (or the entry expires after [timeout], mirroring the sender-side
/// nudge expiry window).
class NudgeStatusMemory {
  NudgeStatusMemory._();

  static final NudgeStatusMemory instance = NudgeStatusMemory._();

  /// How long a pending status stays re-openable after the last send.
  static const Duration timeout = Duration(minutes: 10);

  final Map<String, LastNudgeState> _byGroupId = {};

  /// The active pending status for [groupId], or null if there isn't one.
  LastNudgeState? forGroup(String groupId) {
    final entry = _byGroupId[groupId];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) > timeout) {
      _byGroupId.remove(groupId);
      return null;
    }
    return entry;
  }

  void record(String groupId, LastNudgeState state) {
    if (groupId.isEmpty) return;
    _byGroupId[groupId] = state;
  }

  /// Clears the pending status for [groupId] — call this when the receiver
  /// accepts the nudge so it stops showing as the active pending state.
  void clear(String groupId) {
    _byGroupId.remove(groupId);
  }
}
