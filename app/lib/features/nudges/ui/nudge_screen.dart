import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:record/record.dart';

import '../../../core/firebase/crashlytics_service.dart';
import '../../../core/network/api_client.dart';
import '../../groups/models/group_member_summary.dart';
import '../../groups/models/group_summary.dart';
import '../../identity/ui/profile_avatar.dart';
import '../data/android_voice_nudge_bridge.dart';
import '../data/nudge_repository.dart';
import '../nudge_cooldowns.dart';
import '../nudge_failure_memory.dart';
import '../nudge_status_memory.dart';

Future<void> showNudgeBottomSheet(
  BuildContext context, {
  required GroupSummary group,
  required String currentUserId,
  required List<GroupMemberSummary> members,
  required Color accent,
  bool hapticsEnabled = true,
  Set<String> onlineUserIds = const {},
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _QuickNudgeSheet(
      group: group,
      currentUserId: currentUserId,
      members: members,
      accent: accent,
      hapticsEnabled: hapticsEnabled,
      onlineUserIds: onlineUserIds,
    ),
  );
}

class _QuickNudgeSheet extends StatefulWidget {
  const _QuickNudgeSheet({
    required this.group,
    required this.currentUserId,
    required this.members,
    required this.accent,
    required this.hapticsEnabled,
    required this.onlineUserIds,
  });

  final GroupSummary group;
  final String currentUserId;
  final List<GroupMemberSummary> members;
  final Color accent;
  final bool hapticsEnabled;
  final Set<String> onlineUserIds;

  @override
  State<_QuickNudgeSheet> createState() => _QuickNudgeSheetState();
}

class _QuickNudgeSheetState extends State<_QuickNudgeSheet> {
  static const _maxVoiceDuration = Duration(seconds: 6);
  static const _autoDismissDelay = Duration(seconds: 5);

  final NudgeRepository _repository = NudgeRepository();
  final AudioRecorder _recorder = AudioRecorder();
  final Stopwatch _recordingWatch = Stopwatch();
  final NudgeCooldownTracker _cooldowns = NudgeCooldownTracker.instance;
  NudgeTarget _target = const NudgeTarget.allFriends();
  Timer? _recordingTimer;
  Timer? _cooldownTicker;
  Timer? _autoDismissTimer;
  bool _recording = false;
  bool _startingRecording = false;
  bool _finishingRecording = false;
  bool _pointerHeld = false;
  bool _sendAfterPointerEnd = true;
  bool _busy = false;
  bool _sendingVoice = false;
  Duration _elapsed = Duration.zero;
  String? _message;
  bool _messageIsError = false;
  bool _messageIsWarning = false;
  bool _messagePending = false;

  // Real-time delivery confirmation (nudge reliability checklist): once a
  // ring/voice nudge is accepted by the backend, the sheet stays open
  // awaiting the receiver's genuine playback outcome instead of closing
  // immediately — push nudges have no such confirmation and are unaffected.
  StreamSubscription<NudgeDeliveryResult>? _deliverySub;
  String? _awaitingEventId;
  Timer? _deliveryTimeoutTimer;
  final Map<String, _PendingRecipient> _expectedRecipients = {};
  final Map<String, NudgeDeliveryResult> _resultsByUserId = {};

  static const _deliveryConfirmationTimeout = Duration(seconds: 12);

  @override
  void initState() {
    super.initState();
    // Cheap periodic tick so per-type cooldown countdowns shown in this
    // short-lived sheet stay live without a dedicated stream per chip.
    _cooldownTicker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
    _deliverySub = AndroidVoiceNudgeBridge.deliveryResults.listen(
      _onDeliveryResult,
    );
    _restorePersistedFailures();
    _restoreLastNudgeStatus();
  }

  /// Re-surface the latest failure reason for anyone who didn't receive the
  /// previous nudge (until success or [NudgeFailureMemory.timeout]).
  /// B5: Schedules a 10-minute expiry alarm on the sender's device so the
  /// sender gets a local notification if the receiver doesn't accept in time.
  void _scheduleSenderExpiry(
    String eventId,
    List<_PendingRecipient> expected,
  ) {
    if (!Platform.isAndroid) return;
    final first = expected.firstOrNull;
    if (first == null) return;
    unawaited(
      AndroidVoiceNudgeBridge.shared.scheduleSenderNudgeExpiry(
        eventId: eventId,
        recipientName: first.displayName,
        recipientUserId: first.userId,
      ),
    );
  }

  void _restorePersistedFailures() {
    // Scoped to this group only — a failure from a different group must
    // never bleed into this sheet.
    final failure = NudgeFailureMemory.instance.forGroup(widget.group.groupId);
    if (failure == null) return;
    _message = failure.message;
    _messageIsError = true;
    _messageIsWarning = false;
    _messagePending = false;
  }

  /// Re-surface the most recent nudge's lifecycle status for this group so
  /// tapping the main nudge button shows where the last nudge stands (waiting
  /// for the receiver, played, low volume) instead of a blank send sheet.
  /// Runs after [_restorePersistedFailures] so the newest state wins.
  void _restoreLastNudgeStatus() {
    final last = NudgeStatusMemory.instance.forGroup(widget.group.groupId);
    if (last == null) return;
    switch (last.status) {
      case LastNudgeStatus.sent:
      case LastNudgeStatus.waiting:
        _message = last.message;
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = true;
        break;
      case LastNudgeStatus.played:
        _message = last.message;
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = false;
        break;
      case LastNudgeStatus.volumeLow:
      case LastNudgeStatus.volumeMuted:
        _message = last.message;
        _messageIsError = false;
        _messageIsWarning = true;
        _messagePending = false;
        break;
      case LastNudgeStatus.failed:
        _message = last.message;
        _messageIsError = true;
        _messageIsWarning = false;
        _messagePending = false;
        break;
    }
  }

  void _recordLastStatus(LastNudgeStatus status, String message) {
    NudgeStatusMemory.instance.record(
      widget.group.groupId,
      LastNudgeState(
        eventId: _awaitingEventId ?? '',
        status: status,
        message: message,
        at: DateTime.now(),
      ),
    );
  }

  List<GroupMemberSummary> get _friends => widget.members
      .where(
        (member) =>
            member.userId != widget.currentUserId &&
            member.memberState == 'active',
      )
      .toList(growable: false);

  bool _isOnline(String userId) => widget.onlineUserIds.contains(userId);

  /// Friends who can actually be nudged (not already in the live session).
  List<GroupMemberSummary> get _nudgeableFriends =>
      _friends.where((f) => !_isOnline(f.userId)).toList(growable: false);

  bool get _canSend =>
      _nudgeableFriends.isNotEmpty &&
      !_busy &&
      !_startingRecording &&
      !_finishingRecording &&
      !_recording &&
      _awaitingEventId == null;

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _cooldownTicker?.cancel();
    _deliveryTimeoutTimer?.cancel();
    _autoDismissTimer?.cancel();
    unawaited(_deliverySub?.cancel());
    if (_recording) unawaited(_recorder.stop());
    unawaited(_recorder.dispose());
    super.dispose();
  }

  List<_PendingRecipient> _recipientsForTarget() {
    if (_target.targetScope == 'single_friend') {
      final id = _target.targetUserId;
      if (id == null) return const [];
      final friend = _friends.where((f) => f.userId == id).firstOrNull;
      if (friend == null || _isOnline(friend.userId)) return const [];
      return [
        _PendingRecipient(userId: friend.userId, displayName: friend.displayName),
      ];
    }
    return _nudgeableFriends
        .map(
          (f) => _PendingRecipient(userId: f.userId, displayName: f.displayName),
        )
        .toList(growable: false);
  }

  void _scheduleAutoDismiss() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = Timer(_autoDismissDelay, () {
      if (mounted && _canSend && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  /// Begins waiting for the receiver's genuine playback outcome for the
  /// ring/voice nudge identified by [eventId] instead of closing the sheet.
  /// Falls back to a generic "wasn't played" message if no result arrives
  /// within [_deliveryConfirmationTimeout] (e.g. the receiver is offline).
  void _beginAwaitingDeliveryConfirmation(
    String? eventId, {
    required String waitingMessage,
    required List<_PendingRecipient> expected,
  }) {
    if (eventId == null || eventId.isEmpty) return;
    _deliveryTimeoutTimer?.cancel();
    _autoDismissTimer?.cancel();
    setState(() {
      _awaitingEventId = eventId;
      _expectedRecipients
        ..clear()
        ..addEntries(expected.map((e) => MapEntry(e.userId, e)));
      _resultsByUserId.clear();
      _message = waitingMessage;
      _messageIsError = false;
      _messageIsWarning = false;
      _messagePending = true;
    });
    _recordLastStatus(LastNudgeStatus.waiting, 'Waiting for receiver');
    _deliveryTimeoutTimer = Timer(_deliveryConfirmationTimeout, () {
      if (!mounted || _awaitingEventId != eventId) return;
      _finalizeDeliverySummary(timedOut: true);
    });
  }

  void _onDeliveryResult(NudgeDeliveryResult result) {
    if (!mounted || result.eventId != _awaitingEventId) return;

    // Match result to an expected recipient by userId first, then by name.
    String? matchedId = result.recipientUserId;
    if (matchedId == null || !_expectedRecipients.containsKey(matchedId)) {
      final name = result.recipientName?.trim().toLowerCase();
      if (name != null && name.isNotEmpty) {
        matchedId = _expectedRecipients.entries
            .where((e) => e.value.displayName.trim().toLowerCase() == name)
            .map((e) => e.key)
            .firstOrNull;
      }
    }
    // Single expected recipient fallback (unique friend target).
    matchedId ??=
        _expectedRecipients.length == 1 ? _expectedRecipients.keys.first : null;
    if (matchedId == null || matchedId.isEmpty) {
      // Still useful when the map is empty (legacy path).
      matchedId = result.recipientUserId ??
          result.recipientName ??
          'unknown_${_resultsByUserId.length}';
    }

    _resultsByUserId[matchedId] = result;

    final expectedCount = _expectedRecipients.isEmpty
        ? 1
        : _expectedRecipients.length;
    if (_resultsByUserId.length >= expectedCount) {
      _deliveryTimeoutTimer?.cancel();
      _finalizeDeliverySummary(timedOut: false);
    } else {
      // Partial progress so the sender sees results as they arrive.
      setState(() {
        _message = _buildDeliveryMessage(partial: true);
        _messageIsError = _resultsByUserId.values.any((r) => !r.played);
        _messageIsWarning = !_messageIsError &&
            _resultsByUserId.values.any((r) => r.playedButNotAudible);
        _messagePending = true;
      });
    }
  }

  void _finalizeDeliverySummary({required bool timedOut}) {
    if (!mounted) return;
    final expected = _expectedRecipients.values.toList(growable: false);
    // Synthesize timeout failures for anyone without a result.
    for (final pending in expected) {
      if (!_resultsByUserId.containsKey(pending.userId)) {
        _resultsByUserId[pending.userId] = NudgeDeliveryResult(
          eventId: _awaitingEventId ?? '',
          status: 'failed',
          reason: timedOut ? 'timeout' : 'unknown',
          recipientUserId: pending.userId,
          recipientName: pending.displayName,
        );
      }
    }

    if (_resultsByUserId.isEmpty && timedOut) {
      setState(() {
        _awaitingEventId = null;
        _message = 'Nudge wasn\u2019t played, try again.';
        _messageIsError = true;
        _messageIsWarning = false;
        _messagePending = false;
      });
      _scheduleAutoDismiss();
      return;
    }

    // Persist a group-scoped failure summary (or clear it on full success)
    // for the return-to-sheet banner. Only genuine playback failures count as
    // failures here \u2014 a muted/low-volume recipient "played" the nudge and
    // is surfaced as a warning instead of a "did not receive" error.
    final failed = <NudgeDeliveryResult>[];
    final failedNames = <String>[];
    final hasAttention = _resultsByUserId.values.any((r) => r.playedButNotAudible);
    for (final entry in _resultsByUserId.entries) {
      final result = entry.value;
      final name = result.recipientName ??
          _expectedRecipients[entry.key]?.displayName ??
          'them';
      if (!result.played) {
        failed.add(result);
        failedNames.add(name.trim().split(RegExp(r'\s+')).first);
      }
    }
    final totalRecipients = _resultsByUserId.length;
    if (failed.isEmpty) {
      NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
    } else {
      // With exactly one failed recipient, keep the specific reason-coded
      // message (more useful than a generic count) instead of collapsing it.
      final message = failed.length == 1
          ? _shortFailureWithReason(failedNames.first, failed.first.reason)
          : _persistedFailureMessage(
              failed.length,
              totalRecipients,
              failedNames,
            );
      NudgeFailureMemory.instance.record(
        widget.group.groupId,
        failed.length >= totalRecipients
            ? NudgeErrorSeverity.full
            : NudgeErrorSeverity.partial,
        message,
      );
    }

    final summaryMessage = _buildDeliveryMessage(partial: false);
    if (failed.isNotEmpty) {
      _recordLastStatus(LastNudgeStatus.failed, summaryMessage);
    } else if (hasAttention) {
      final allMuted = _resultsByUserId.values
          .where((r) => r.playedButNotAudible)
          .every((r) => r.attention == 'volume_muted');
      _recordLastStatus(
        allMuted ? LastNudgeStatus.volumeMuted : LastNudgeStatus.volumeLow,
        summaryMessage,
      );
    } else {
      _recordLastStatus(LastNudgeStatus.played, summaryMessage);
    }

    setState(() {
      _awaitingEventId = null;
      _messagePending = false;
      _message = summaryMessage;
      _messageIsError = failed.isNotEmpty;
      _messageIsWarning = failed.isEmpty && hasAttention;
    });
    _scheduleAutoDismiss();
  }

  String _buildDeliveryMessage({required bool partial}) {
    final expected = _expectedRecipients;
    final results = _resultsByUserId.values.toList(growable: false);
    if (results.isEmpty) {
      return partial ? 'Confirming delivery\u2026' : 'Nudge wasn\u2019t played, try again.';
    }

    final failed = results.where((r) => !r.played).toList(growable: false);
    final attention = results
        .where((r) => r.playedButNotAudible)
        .toList(growable: false);
    final cleanPlayed = results
        .where((r) => r.played && r.attention == null)
        .toList(growable: false);

    String nameOf(NudgeDeliveryResult r) {
      if (r.recipientName != null && r.recipientName!.trim().isNotEmpty) {
        return r.recipientName!.trim().split(RegExp(r'\s+')).first;
      }
      if (r.recipientUserId != null) {
        final pending = expected[r.recipientUserId!];
        if (pending != null) {
          return pending.displayName.trim().split(RegExp(r'\s+')).first;
        }
      }
      return 'Someone';
    }

    // 1) Genuine playback failures \u2014 the only "did not receive" cases.
    if (failed.isNotEmpty) {
      if (failed.length == 1 && (expected.length <= 1 || results.length == 1)) {
        final f = failed.first;
        return _shortFailureWithReason(nameOf(f), f.reason);
      }

      final names = failed.map(nameOf).toList(growable: false);
      final named = _joinNames(names);
      if (cleanPlayed.isEmpty && attention.isEmpty) {
        return '$named did not receive the nudge.';
      }
      return '$named did not receive the nudge \u2014 everyone else did.';
    }

    // 2) Played, but likely inaudible (muted / very low volume).
    if (attention.isNotEmpty) {
      if (attention.length == 1 && results.length == 1) {
        return _attentionMessage(nameOf(attention.first), attention.first);
      }
      final names = attention.map(nameOf).toList(growable: false);
      final named = _joinNames(names);
      return 'Nudge played, but $named may not have heard it \u2014 check '
          'their volume.';
    }

    // 3) Clean success.
    if (expected.length <= 1 && results.length == 1) {
      final name = results.first.recipientName ??
          expected.values.firstOrNull?.displayName;
      if (name == null) {
        return 'Everyone received the nudge \u2713';
      }
      return 'Nudge successfully playing on $name\u2019s device';
    }
    return 'Everyone received the nudge \u2713';
  }

  String _joinNames(List<String> names) {
    if (names.isEmpty) return 'Someone';
    if (names.length == 1) return names.first;
    if (names.length == 2) return '${names[0]} and ${names[1]}';
    return '${names.sublist(0, names.length - 1).join(', ')}, and ${names.last}';
  }

  String _shortFailureWithReason(String name, String? reason) {
    switch (reason) {
      case 'playback_error':
      case 'playback_service_start_error':
        return 'Nudge did not reach $name \u2014 error on their device.';
      case 'download_error':
        return 'Nudge did not reach $name \u2014 couldn\u2019t download the audio.';
      case 'permission_denied_foreground_service':
        return 'Nudge did not reach $name \u2014 their phone blocked the app '
            'from playing it. Ask them to reopen Duo.';
      case 'timeout':
        return 'Nudge did not reach $name \u2014 no confirmation received.';
      default:
        return 'Nudge did not reach $name.';
    }
  }

  /// Builds the non-error warning shown when a nudge played but the recipient
  /// likely didn't hear it (muted / very low volume). Low volume is surfaced
  /// as the standalone warning "Volume is too low" rather than a "did not
  /// receive" error.
  String _attentionMessage(String name, NudgeDeliveryResult r) {
    switch (r.attention) {
      case 'volume_low':
        return 'Volume is too low \u2014 the nudge may not be audible.';
      case 'volume_muted':
        return 'Their volume was muted \u2014 the nudge may not be audible.';
      default:
        return 'Nudge played on $name\u2019s device, but they may not have heard it.';
    }
  }

  /// Builds the group-scoped persisted-failure message shown when the
  /// sheet is reopened. Uses real names for a full failure (small groups),
  /// and falls back to a plain count for partial failures where we can't
  /// attribute the message to one or two people cleanly.
  String _persistedFailureMessage(
    int failedCount,
    int totalRecipients,
    List<String> failedNames,
  ) {
    if (failedCount >= totalRecipients) {
      return 'Nudge wasn\u2019t delivered to anyone in this group.';
    }
    if (failedNames.length == failedCount && failedNames.length <= 2) {
      return 'Last nudge to ${_joinNames(failedNames)} wasn\u2019t received.';
    }
    return 'Nudge wasn\u2019t delivered to $failedCount of $totalRecipients people.';
  }

  /// Remaining local cooldown for [kind]. Purely a UX affordance — the
  /// backend is the authoritative enforcer and still returns
  /// `nudge_rate_limited` if this local check is somehow bypassed.
  Duration _cooldownRemaining(NudgeKind kind) => _cooldowns.remaining(kind);

  String _cooldownLabel(Duration remaining) {
    final seconds = remaining.inMilliseconds / 1000;
    return seconds <= 1 ? 'wait 1s' : 'wait ${seconds.ceil()}s';
  }

  Future<void> _sendRing(int seconds) async {
    if (_cooldownRemaining(NudgeKind.ring) > Duration.zero) return;
    await _send(
      () => _repository.sendRing(
        groupId: widget.group.groupId,
        target: _effectiveTarget(),
        durationSeconds: seconds,
      ),
      kind: NudgeKind.ring,
      awaitsDeliveryConfirmation: true,
      waitingMessage: 'Ringing\u2026 confirming it played',
    );
  }

  Future<void> _sendPush() async {
    if (_cooldownRemaining(NudgeKind.push) > Duration.zero) return;
    await _send(
      () => _repository.sendPush(
        groupId: widget.group.groupId,
        target: _effectiveTarget(),
      ),
      kind: NudgeKind.push,
    );
  }

  /// Resolves "everyone" to only nudgeable (offline) friends when some are
  /// already live — live members are never offered as nudge targets.
  NudgeTarget _effectiveTarget() {
    if (_target.targetScope == 'single_friend') {
      final id = _target.targetUserId;
      if (id != null && _isOnline(id)) {
        // Online-only selection should be disabled in UI; fall back safely.
        return const NudgeTarget.allFriends();
      }
      return _target;
    }
    // Backend still fans out to all friends for all_friends; UI filters
    // online members from single-target picks. Prefer single friend if only
    // one nudgeable remains after filtering.
    final nudgeable = _nudgeableFriends;
    if (nudgeable.length == 1) {
      return NudgeTarget.singleFriend(nudgeable.first.userId);
    }
    return _target;
  }

  Future<void> _send(
    Future<Object?> Function() action, {
    required NudgeKind kind,
    bool awaitsDeliveryConfirmation = false,
    String waitingMessage = '',
  }) async {
    if (!_canSend) return;
    final expected = _recipientsForTarget();
    if (expected.isEmpty) {
      setState(() {
        _message = 'Everyone is already online.';
        _messageIsError = true;
        _messageIsWarning = false;
      });
      return;
    }
    // Guard single-friend target against online peer.
    if (_target.targetScope == 'single_friend' &&
        _target.targetUserId != null &&
        _isOnline(_target.targetUserId!)) {
      setState(() {
        _message = 'They\u2019re already online.';
        _messageIsError = true;
        _messageIsWarning = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _messageIsError = false;
      _messageIsWarning = false;
      _messagePending = false;
    });
    try {
      final result = await action();
      _cooldowns.record(kind);
      if (!mounted) return;
      setState(() => _busy = false);
      if (awaitsDeliveryConfirmation && result is Map) {
        final eventId = result['notificationEventId']?.toString();
        if (eventId != null && eventId.isNotEmpty) {
          // B5: Schedule sender-side 10-minute expiry alarm.
          _scheduleSenderExpiry(eventId, expected);
          _beginAwaitingDeliveryConfirmation(
            eventId,
            waitingMessage: waitingMessage,
            expected: expected,
          );
          return;
        }
      }
      // B5: Also schedule expiry for push nudges (no delivery confirmation).
      if (!awaitsDeliveryConfirmation && result is Map) {
        final eventId = result['notificationEventId']?.toString();
        if (eventId != null && eventId.isNotEmpty) {
          _scheduleSenderExpiry(eventId, expected);
        }
      }
      // Push (and unconfirmed ring/voice) has no per-recipient playback
      // confirmation, but the send response still reports aggregate
      // sent/failed device counts — use those to catch partial failures
      // instead of always reporting success when `sent > 0`.
      if (!awaitsDeliveryConfirmation && result is Map<String, dynamic>) {
        final nudgeResult = NudgeResult.fromSendResponse(
          result,
          expected.map((e) => e.userId).toList(growable: false),
        );
        if (!nudgeResult.isFullSuccess) {
          final message = nudgeResult.isFullFailure
              ? 'Nudge wasn\u2019t delivered to anyone in this group.'
              : 'Nudge wasn\u2019t delivered to ${nudgeResult.failedCount} of '
                    '${nudgeResult.totalRecipients} people.';
          NudgeFailureMemory.instance.record(
            widget.group.groupId,
            nudgeResult.isFullFailure
                ? NudgeErrorSeverity.full
                : NudgeErrorSeverity.partial,
            message,
          );
          _recordLastStatus(LastNudgeStatus.failed, message);
          setState(() {
            _message = message;
            _messageIsError = true;
            _messageIsWarning = false;
            _messagePending = false;
          });
          _scheduleAutoDismiss();
          return;
        }
      }
      // Push (and unconfirmed ring/voice) — brief success, then 5s dismiss.
      final successMessage = expected.length == 1
          ? 'Nudge sent to ${expected.first.displayName.trim().split(RegExp(r'\s+')).first} \u2713'
          : 'Everyone received the nudge \u2713';
      NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
      _recordLastStatus(LastNudgeStatus.sent, successMessage);
      setState(() {
        _message = successMessage;
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = false;
      });
      _scheduleAutoDismiss();
    } catch (error, stack) {
      final cancelled = error.toString().toLowerCase().contains('cancel');
      if (!cancelled) {
        unawaited(
          CrashlyticsService.recordError(
            error,
            stack,
            reason: 'nudge_send_failed',
          ),
        );
      }
      if (!mounted) return;
      final rateLimited = error is ApiException && error.code == 'nudge_rate_limited';
      final message = error is NudgeDeliveryException
          ? error.message
          : rateLimited
          ? error.message
          : 'Couldn\u2019t send the nudge. Check your connection.';
      // Rate limiting and user-initiated cancellation aren't delivery
      // failures — don't persist those as a group error.
      if (!cancelled && !rateLimited) {
        NudgeFailureMemory.instance.record(
          widget.group.groupId,
          NudgeErrorSeverity.full,
          message,
        );
      }
      setState(() {
        _message = message;
        _messageIsError = true;
        _messageIsWarning = false;
        _busy = false;
      });
    }
  }

  Future<void> _beginRecording() async {
    if (!_canSend || _startingRecording) return;
    if (_cooldownRemaining(NudgeKind.voice) > Duration.zero) return;
    _startingRecording = true;
    try {
      if (!await _recorder.hasPermission()) {
        if (mounted) {
          setState(() {
            _message = 'Microphone permission is required.';
            _messageIsError = true;
            _messageIsWarning = false;
          });
        }
        return;
      }
      final file = File(
        '${Directory.systemTemp.path}/one_one_voice_${DateTime.now().microsecondsSinceEpoch}.m4a',
      );
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
          numChannels: 1,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
        path: file.path,
      );
      if (!mounted) {
        await _recorder.stop();
        return;
      }
      // Second, slightly stronger pulse confirms recording actually started
      // (distinct from the immediate "press acknowledged" pulse on touch-down).
      if (widget.hapticsEnabled) unawaited(HapticFeedback.mediumImpact());
      _recordingWatch
        ..reset()
        ..start();
      _recordingTimer?.cancel();
      _recordingTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted || !_recording) return;
        final elapsed = _recordingWatch.elapsed;
        setState(() => _elapsed = elapsed);
        if (elapsed >= _maxVoiceDuration) {
          unawaited(_finishRecording(send: true));
        }
      });
      setState(() {
        _recording = true;
        _elapsed = Duration.zero;
        _message = 'Recording… release to send';
        _messageIsError = false;
        _messageIsWarning = false;
      });
      if (!_pointerHeld) {
        await _finishRecording(send: _sendAfterPointerEnd);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = _friendlyError(error);
          _messageIsError = true;
          _messageIsWarning = false;
        });
      }
    } finally {
      _startingRecording = false;
    }
  }

  Future<void> _finishRecording({required bool send}) async {
    if (!_recording || _finishingRecording) return;
    _finishingRecording = true;
    _recordingTimer?.cancel();
    _recordingWatch.stop();
    final durationMs = _recordingWatch.elapsedMilliseconds.clamp(
      0,
      _maxVoiceDuration.inMilliseconds,
    );
    if (mounted) {
      setState(() {
        _recording = false;
        _busy = send;
        _sendingVoice = send;
        _message = send ? 'Sending voice nudge…' : null;
        _messageIsError = false;
        _messageIsWarning = false;
      });
    }

    String? path;
    var sent = false;
    String? voiceEventId;
    try {
      path = await _recorder.stop();
      if (!send || path == null) return;
      if (durationMs < 250) {
        if (mounted) {
          setState(() {
            _message = 'Hold a little longer to record.';
            _messageIsError = true;
            _messageIsWarning = false;
          });
        }
        return;
      }
      final file = File(path);
      final response = await _repository.sendVoice(
        groupId: widget.group.groupId,
        target: _effectiveTarget(),
        audio: await file.readAsBytes(),
        durationMs: durationMs,
      );
      _cooldowns.record(NudgeKind.voice);
      sent = true;
      voiceEventId = response['notificationEventId']?.toString();
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = _friendlyError(error);
          _messageIsError = true;
          _messageIsWarning = false;
        });
      }
    } finally {
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {
          // The OS cache cleaner is the final fallback.
        }
      }
      _recordingWatch.reset();
      _finishingRecording = false;
      if (mounted) {
        setState(() {
          _busy = false;
          _sendingVoice = false;
          _elapsed = Duration.zero;
        });
        if (sent && voiceEventId != null && voiceEventId.isNotEmpty) {
          _beginAwaitingDeliveryConfirmation(
            voiceEventId,
            waitingMessage: 'Sent\u2026 confirming it played',
            expected: _recipientsForTarget(),
          );
        } else if (sent) {
          final expected = _recipientsForTarget();
          final successMessage = expected.length == 1
              ? 'Nudge sent to ${expected.first.displayName.trim().split(RegExp(r'\s+')).first} \u2713'
              : 'Everyone received the nudge \u2713';
          NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
          _recordLastStatus(LastNudgeStatus.sent, successMessage);
          setState(() {
            _message = successMessage;
            _messageIsError = false;
            _messageIsWarning = false;
            _messagePending = false;
          });
          _scheduleAutoDismiss();
        }
      }
    }
  }

  String _friendlyError(Object error) {
    if (error is NudgeDeliveryException) return error.message;
    if (error is ApiException && error.code == 'nudge_rate_limited') {
      return error.message;
    }
    final text = error.toString();
    if (text.contains('nudge_rate_limited')) {
      return 'Nudge limit reached. Please wait before trying again.';
    }
    if (text.contains('voice_nudge_too_large')) {
      return 'Recording was too large. Try again.';
    }
    return 'Couldn’t send the nudge. Check your connection.';
  }

  @override
  Widget build(BuildContext context) {
    final ringCooldown = _cooldownRemaining(NudgeKind.ring);
    final pushCooldown = _cooldownRemaining(NudgeKind.push);
    final voiceCooldown = _cooldownRemaining(NudgeKind.voice);
    final actionEnabled = _canSend;
    final ringEnabled = actionEnabled && ringCooldown <= Duration.zero;
    final pushEnabled = actionEnabled && pushCooldown <= Duration.zero;
    final voiceEnabled = _canSend && voiceCooldown <= Duration.zero;
    final recordingProgress =
        (_elapsed.inMilliseconds / _maxVoiceDuration.inMilliseconds).clamp(
          0.0,
          1.0,
        );
    final accent = widget.accent;

    return PopScope(
      canPop:
          !_busy &&
          !_recording &&
          !_startingRecording &&
          !_finishingRecording &&
          _awaitingEventId == null,
      child: Material(
        color: const Color(0xff141414),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28.r)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.88,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Drag handle ──
                Center(
                  child: Padding(
                    padding: EdgeInsets.only(top: 10.h, bottom: 14.h),
                    child: Container(
                      width: 38.w,
                      height: 4.h,
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                ),

                // ── Header ──
                Padding(
                  padding: EdgeInsets.fromLTRB(20.w, 0, 8.w, 0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Send a nudge',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18.sp,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            SizedBox(height: 2.h),
                            Text(
                              widget.group.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 12.sp,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: _busy || _recording || _startingRecording
                            ? null
                            : () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                        color: Colors.white38,
                        iconSize: 20.sp,
                        tooltip: 'Close',
                      ),
                    ],
                  ),
                ),

                SizedBox(height: 18.h),

                // ── Recipient picker ──
                SizedBox(
                  height: 88.h,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: EdgeInsets.symmetric(horizontal: 20.w),
                    children: [
                      _NudgeRecipient(
                        label: 'Everyone',
                        selected: _target.targetScope == 'all_friends',
                        accent: accent,
                        enabled: actionEnabled && _nudgeableFriends.isNotEmpty,
                        onTap: actionEnabled && _nudgeableFriends.isNotEmpty
                            ? () => setState(
                                () => _target = const NudgeTarget.allFriends(),
                              )
                            : null,
                        avatar: Container(
                          color: accent.withValues(alpha: 0.18),
                          child: Icon(
                            Icons.group_rounded,
                            color: accent,
                            size: 22.sp,
                          ),
                        ),
                      ),
                      for (final friend in _friends) ...[
                        SizedBox(width: 10.w),
                        Builder(
                          builder: (context) {
                            final online = _isOnline(friend.userId);
                            return _NudgeRecipient(
                              label: friend.displayName,
                              subtitle: online ? 'already online' : null,
                              selected:
                                  !online &&
                                  _target.targetUserId == friend.userId,
                              accent: accent,
                              enabled: actionEnabled && !online,
                              dimmed: online,
                              onTap: actionEnabled && !online
                                  ? () => setState(
                                      () => _target = NudgeTarget.singleFriend(
                                        friend.userId,
                                      ),
                                    )
                                  : null,
                              avatar: Opacity(
                                opacity: online ? 0.38 : 1,
                                child: ProfileAvatar(
                                  key: ValueKey(friend.userId),
                                  profilePhotoUrl: friend.profilePhotoUrl,
                                  profilePhotoBase64: friend.profilePhotoBase64,
                                  avatarAsset: friend.avatarAsset,
                                  radius: 24.r,
                                  fallback: Text(
                                    friend.displayName.trim().isEmpty
                                        ? '?'
                                        : String.fromCharCode(
                                            friend.displayName.trim().runes.first,
                                          ).toUpperCase(),
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 17.sp,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),

                SizedBox(height: 14.h),
                _SheetDivider(),

                // ── Quick ring (most subtle — listed first) ──
                Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: 20.w,
                    vertical: 13.h,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.vibration_rounded,
                        color: Colors.white38,
                        size: 17.sp,
                      ),
                      SizedBox(width: 10.w),
                      Text(
                        ringCooldown > Duration.zero
                            ? 'Quick ring · ${_cooldownLabel(ringCooldown)}'
                            : 'Quick ring',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 13.sp,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      // Chips stay visible (only their enabled state changes)
                      // so an in-flight send never hides the duration picker —
                      // a generic spinner here previously replaced it.
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final s in const [3, 5, 10]) ...[
                            if (s != 3) SizedBox(width: 6.w),
                            _RingChip(
                              seconds: s,
                              accent: accent,
                              enabled: ringEnabled,
                              onTap: () => _sendRing(s),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),

                _SheetDivider(),

                // ── Push notification (medium urgency — second) ──
                InkWell(
                  onTap: pushEnabled ? _sendPush : null,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: 20.w,
                      vertical: 14.h,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.notifications_none_rounded,
                          color: pushEnabled ? Colors.white70 : Colors.white24,
                          size: 20.sp,
                        ),
                        SizedBox(width: 12.w),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Push notification',
                                style: TextStyle(
                                  color: pushEnabled
                                      ? Colors.white
                                      : Colors.white24,
                                  fontSize: 14.sp,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                pushCooldown > Duration.zero
                                    ? _cooldownLabel(pushCooldown)
                                    : 'Standard alert',
                                style: TextStyle(
                                  color: pushEnabled
                                      ? Colors.white38
                                      : Colors.white12,
                                  fontSize: 11.sp,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.arrow_forward_rounded,
                          color: pushEnabled ? Colors.white24 : Colors.white12,
                          size: 16.sp,
                        ),
                      ],
                    ),
                  ),
                ),

                _SheetDivider(),

                // ── Voice message — recorded and sent inside this sheet ──
                Padding(
                  padding: EdgeInsets.fromLTRB(20.w, 16.h, 20.w, 18.h),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.mic_none_rounded,
                            color: voiceEnabled || _recording
                                ? accent
                                : Colors.white24,
                            size: 20.sp,
                          ),
                          SizedBox(width: 10.w),
                          Text(
                            'Voice nudge',
                            style: TextStyle(
                              color: voiceEnabled || _recording
                                  ? Colors.white
                                  : Colors.white24,
                              fontSize: 14.sp,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      SizedBox(height: 5.h),
                      Text(
                        voiceCooldown > Duration.zero
                            ? 'Voice nudge sent recently — ${_cooldownLabel(voiceCooldown)}.'
                            : 'Press and hold the mic. Your recording is capped at 6 seconds and sent when you release.',
                        style: TextStyle(
                          color: voiceEnabled || _recording
                              ? Colors.white38
                              : Colors.white12,
                          fontSize: 11.sp,
                          height: 1.4,
                        ),
                      ),
                      SizedBox(height: 16.h),
                      Center(
                        child: Semantics(
                          button: true,
                          enabled: voiceEnabled,
                          label: _recording
                              ? 'Recording voice nudge, release to send'
                              : _sendingVoice
                              ? 'Sending voice nudge'
                              : 'Voice nudge, press and hold to record',
                          child: Listener(
                            onPointerDown: (_) {
                              if (!voiceEnabled) return;
                              // Immediate, subtle pulse the instant the press is
                              // registered — before we even know the recorder
                              // will start — so the touch feels acknowledged.
                              if (widget.hapticsEnabled) {
                                unawaited(HapticFeedback.lightImpact());
                              }
                              _pointerHeld = true;
                              _sendAfterPointerEnd = true;
                              unawaited(_beginRecording());
                            },
                            onPointerUp: (_) {
                              _pointerHeld = false;
                              _sendAfterPointerEnd = true;
                              unawaited(_finishRecording(send: true));
                            },
                            onPointerCancel: (_) {
                              _pointerHeld = false;
                              _sendAfterPointerEnd = false;
                              unawaited(_finishRecording(send: false));
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 160),
                              width: 104.r,
                              height: 104.r,
                              decoration: BoxDecoration(
                                color: _recording
                                    ? accent
                                    : _sendingVoice
                                    ? accent.withValues(alpha: 0.18)
                                    : const Color(0xff202020),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _recording || _sendingVoice
                                      ? accent
                                      : Colors.white.withValues(alpha: 0.09),
                                ),
                                boxShadow: _recording || _sendingVoice
                                    ? [
                                        BoxShadow(
                                          color: accent.withValues(alpha: 0.35),
                                          blurRadius: 26.r,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: _sendingVoice
                                  ? _SendingVoicePulse(accent: accent)
                                  : Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Padding(
                                          padding: EdgeInsets.all(6.r),
                                          child: CircularProgressIndicator(
                                            value: _recording
                                                ? recordingProgress
                                                : 0,
                                            strokeWidth: 4.r,
                                            color: Colors.white,
                                            backgroundColor: Colors.white24,
                                          ),
                                        ),
                                        Icon(
                                          _recording
                                              ? Icons.mic_rounded
                                              : Icons.mic_none_rounded,
                                          size: 42.sp,
                                          color: _recording
                                              ? Colors.black
                                              : voiceEnabled
                                              ? Colors.white
                                              : Colors.white24,
                                        ),
                                      ],
                                    ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox(height: 9.h),
                      Center(
                        child: Text(
                          _recording
                              ? '${(_elapsed.inMilliseconds / 1000).toStringAsFixed(1)} / 6.0 sec'
                              : _sendingVoice
                              ? 'Sending…'
                              : 'Hold to record · release to send',
                          style: TextStyle(
                            color: _recording || _sendingVoice
                                ? accent
                                : Colors.white30,
                            fontSize: 10.sp,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Status / no-friends message ──
                if (_friends.isEmpty ||
                    _nudgeableFriends.isEmpty ||
                    _message != null) ...[
                  Padding(
                    padding: EdgeInsets.fromLTRB(20.w, 4.h, 20.w, 0),
                    child: _NudgeStatus(
                      message: _friends.isEmpty
                          ? 'Invite a friend before sending a nudge.'
                          : _nudgeableFriends.isEmpty && _message == null
                          ? 'Everyone is already online — no nudge needed.'
                          : _message!,
                      isError:
                          _friends.isEmpty ||
                          (_messageIsError && _message != null),
                      isWarning: _messageIsWarning && _message != null,
                      isPending: _friends.isEmpty ? false : _messagePending,
                    ),
                  ),
                ],

                SizedBox(height: 28.h),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Replaces the generic spinner previously shown while a voice nudge
/// uploads: a paper-plane glyph gently bobbing inside two staggered,
/// outward-fading ripples — reads as "transmitting" rather than "loading"
/// and keeps the mic button's footprint identical so nothing jumps around.
class _SendingVoicePulse extends StatefulWidget {
  const _SendingVoicePulse({required this.accent});

  final Color accent;

  @override
  State<_SendingVoicePulse> createState() => _SendingVoicePulseState();
}

class _SendingVoicePulseState extends State<_SendingVoicePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Stack(
          alignment: Alignment.center,
          fit: StackFit.expand,
          children: [
            _ripple((t + 0.0) % 1.0),
            _ripple((t + 0.5) % 1.0),
            Transform.translate(
              offset: Offset(0, -3.r * math.sin(t * 2 * math.pi)),
              child: Icon(Icons.send_rounded, size: 32.sp, color: Colors.white),
            ),
          ],
        );
      },
    );
  }

  Widget _ripple(double progress) {
    final scale = 0.5 + progress * 0.85;
    final opacity = (1 - progress) * 0.5;
    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Transform.scale(
        scale: scale,
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.4),
          ),
        ),
      ),
    );
  }
}

// Thin sheet section divider
class _SheetDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Divider(
      color: Colors.white.withValues(alpha: 0.06),
      height: 1,
      indent: 20.w,
      endIndent: 20.w,
    );
  }
}

// Compact ring duration chip
class _RingChip extends StatelessWidget {
  const _RingChip({
    required this.seconds,
    required this.accent,
    required this.enabled,
    required this.onTap,
  });

  final int seconds;
  final Color accent;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled
          ? accent.withValues(alpha: 0.12)
          : Colors.white.withValues(alpha: 0.04),
      borderRadius: BorderRadius.circular(10.r),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10.r),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 6.h),
          child: Text(
            '${seconds}s',
            style: TextStyle(
              color: enabled ? accent : Colors.white24,
              fontSize: 12.sp,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}

class _PendingRecipient {
  const _PendingRecipient({required this.userId, required this.displayName});

  final String userId;
  final String displayName;
}

class _NudgeRecipient extends StatelessWidget {
  const _NudgeRecipient({
    required this.label,
    required this.selected,
    required this.accent,
    required this.avatar,
    required this.onTap,
    this.enabled = true,
    this.dimmed = false,
    this.subtitle,
  });

  final String label;
  final bool selected;
  final Color accent;
  final Widget avatar;
  final VoidCallback? onTap;
  final bool enabled;
  final bool dimmed;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final tap = enabled ? onTap : null;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: subtitle != null ? '$label, $subtitle' : 'Send to $label',
      child: InkWell(
        onTap: tap,
        borderRadius: BorderRadius.circular(18.r),
        child: SizedBox(
          width: 60.w,
          child: Column(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: EdgeInsets.all(2.r),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xff1e1e1e),
                  border: Border.all(
                    color: selected ? accent : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ClipOval(
                  child: SizedBox(width: 46.r, height: 46.r, child: avatar),
                ),
              ),
              SizedBox(height: 5.h),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: dimmed
                      ? Colors.white30
                      : selected
                      ? Colors.white
                      : Colors.white54,
                  fontSize: 10.sp,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white24,
                    fontSize: 8.sp,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NudgeStatus extends StatelessWidget {
  const _NudgeStatus({
    required this.message,
    required this.isError,
    this.isWarning = false,
    this.isPending = false,
  });

  final String message;
  final bool isError;
  final bool isWarning;
  final bool isPending;

  @override
  Widget build(BuildContext context) {
    final color = isPending
        ? const Color(0xffe0a83c)
        : isError
        ? const Color(0xffff6b6f)
        : isWarning
        ? const Color(0xffe0a83c)
        : const Color(0xff9bdc28);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.w, vertical: 10.h),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isPending)
            Padding(
              padding: EdgeInsets.only(top: 1.h),
              child: SizedBox(
                width: 15.sp,
                height: 15.sp,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              ),
            )
          else
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : isWarning
                  ? Icons.warning_amber_rounded
                  : Icons.check_circle_outline,
              color: color,
              size: 17.sp,
            ),
          SizedBox(width: 8.w),
          Expanded(
            child: Text(
              message,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11.sp,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
