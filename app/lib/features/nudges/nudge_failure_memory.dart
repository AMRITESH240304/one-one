/// Severity of the last nudge send in a group: whether it failed for every
/// recipient, or just some of them.
enum NudgeErrorSeverity { partial, full }

/// A single group's most recent nudge delivery failure, ready to render
/// directly in the error bar.
class NudgeErrorState {
  const NudgeErrorState({
    required this.severity,
    required this.message,
    required this.at,
  });

  final NudgeErrorSeverity severity;
  final String message;
  final DateTime at;
}

/// In-memory (per app process) record of the most recent nudge delivery
/// failure **per group**, so the send-nudge sheet can surface a reason after
/// the user dismisses the sheet and reopens it — scoped so a failure in one
/// group is never shown while viewing a different group.
///
/// The entry for a group expires after [timeout] or is cleared as soon as a
/// nudge in that group succeeds (or the user dismisses the error).
class NudgeFailureMemory {
  NudgeFailureMemory._();

  static final NudgeFailureMemory instance = NudgeFailureMemory._();

  /// How long a failure reason stays on the sheet when the user returns.
  static const Duration timeout = Duration(minutes: 15);

  final Map<String, NudgeErrorState> _byGroupId = {};

  /// The active failure for [groupId], or null if there isn't one (either
  /// none was recorded, it expired, or it was cleared by a later success).
  NudgeErrorState? forGroup(String groupId) {
    final entry = _byGroupId[groupId];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) > timeout) {
      _byGroupId.remove(groupId);
      return null;
    }
    return entry;
  }

  void record(String groupId, NudgeErrorSeverity severity, String message) {
    if (groupId.isEmpty) return;
    _byGroupId[groupId] = NudgeErrorState(
      severity: severity,
      message: message,
      at: DateTime.now(),
    );
  }

  /// Clears the failure for [groupId] — call this on a fully-successful send
  /// or when the user dismisses the error for that group.
  void clearGroup(String groupId) {
    _byGroupId.remove(groupId);
  }

  void clearAll() {
    _byGroupId.clear();
  }
}
