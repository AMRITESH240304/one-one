import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:lucide_flutter/lucide_flutter.dart';
import 'package:record/record.dart';

import '../../../core/firebase/crashlytics_service.dart';
import '../../../core/logging/log_level.dart';
import '../../../core/logging/log_manager.dart';
import '../../../core/logging/user_facing_copy.dart';
import '../../../core/network/api_client.dart';
import '../../../core/ui/bottom_system_inset.dart';
import '../../groups/models/group_member_summary.dart';
import '../../groups/models/group_summary.dart';
import '../../identity/models/haptics_intensity.dart';
import '../../identity/ui/profile_avatar.dart';
import '../data/android_voice_nudge_bridge.dart';
import '../data/media_volume_store.dart';
import '../data/nudge_repository.dart';
import '../data/voice_nudge_audio.dart';
import '../models/media_volume_reading.dart';
import '../nudge_cooldowns.dart';
import '../nudge_failure_memory.dart';
import '../nudge_haptics.dart';
import '../nudge_status_memory.dart';

Future<void> showNudgeBottomSheet(
  BuildContext context, {
  required GroupSummary group,
  required String currentUserId,
  required List<GroupMemberSummary> members,
  required Color accent,
  HapticsIntensity hapticsIntensity = HapticsIntensity.light,
  Set<String> onlineUserIds = const {},
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    // Drag/barrier dismiss is unsafe during hold-to-speak: a second finger
    // or stray swipe pops the sheet and aborts recording. Close is X / back,
    // both of which are disabled while the hold (or send) is in progress.
    isDismissible: false,
    enableDrag: false,
    builder: (_) => _QuickNudgeSheet(
      group: group,
      currentUserId: currentUserId,
      members: members,
      accent: accent,
      hapticsIntensity: hapticsIntensity,
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
    required this.hapticsIntensity,
    required this.onlineUserIds,
  });

  final GroupSummary group;
  final String currentUserId;
  final List<GroupMemberSummary> members;
  final Color accent;
  final HapticsIntensity hapticsIntensity;
  final Set<String> onlineUserIds;

  @override
  State<_QuickNudgeSheet> createState() => _QuickNudgeSheetState();
}

class _QuickNudgeSheetState extends State<_QuickNudgeSheet> {
  static const _autoDismissDelay = Duration(seconds: 5);
  static const _ringTapDurationSeconds = 5;
  static const _ringDoubleTapDurationSeconds = 10;

  final NudgeRepository _repository = NudgeRepository();
  final AudioRecorder _recorder = AudioRecorder();
  final Stopwatch _recordingWatch = Stopwatch();
  final NudgeCooldownTracker _cooldowns = NudgeCooldownTracker.instance;
  final Set<String> _selectedUserIds = {};
  Timer? _recordingTimer;
  Timer? _recordingCapTimer;
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

  // Delivery icon state: when true, delivery results appear as avatar badges
  // rather than the _NudgeStatus text widget.
  bool _showDeliveryBadges = false;

  // Whether to show "Confirming if everyone received…" text during delivery wait.
  // True for voice nudges only (ring skips step 2 per spec).
  bool _showConfirmingText = false;

  // Tracks what kind of nudge was last sent, used to decide which badges to show.
  NudgeKind? _lastSentNudgeKind;

  // Real-time delivery confirmation (nudge reliability checklist): once a
  // ring/voice nudge is accepted by the backend, the sheet stays open
  // awaiting the receiver's genuine playback outcome instead of closing
  // immediately — push nudges have no such confirmation and are unaffected.
  StreamSubscription<NudgeDeliveryResult>? _deliverySub;
  StreamSubscription<NudgeRecipientResponse>? _responseSub;
  String? _awaitingEventId;

  /// Kept after delivery finalize so late decline/snooze replies still match.
  String? _lastEventId;
  Timer? _deliveryTimeoutTimer;
  final Map<String, _PendingRecipient> _expectedRecipients = {};
  final Map<String, NudgeDeliveryResult> _resultsByUserId = {};
  final Map<String, NudgeRecipientReply> _repliesByUserId = {};
  MediaVolumeFeedback _rtdbVolumeFeedback = MediaVolumeFeedback.none;

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
    _responseSub = AndroidVoiceNudgeBridge.recipientResponses.listen(
      _onRecipientResponse,
    );
    _selectedUserIds.addAll(_nudgeableFriends.map((f) => f.userId));
    _restorePersistedFailures();
    _restoreLastNudgeStatus();
  }

  /// Re-surface the latest failure reason for anyone who didn't receive the
  /// previous nudge (until success or [NudgeFailureMemory.timeout]).
  void _scheduleSenderExpiry(String eventId, List<_PendingRecipient> expected) {
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
    final failure = NudgeFailureMemory.instance.forGroup(widget.group.groupId);
    if (failure == null) return;
    _message = failure.message;
    _messageIsError = true;
    _messageIsWarning = false;
    _messagePending = false;
  }

  void _restoreLastNudgeStatus() {
    final last = NudgeStatusMemory.instance.forGroup(widget.group.groupId);
    if (last == null) return;
    _lastSentNudgeKind = last.kind;
    if (last.eventId.isNotEmpty) _lastEventId = last.eventId;
    if (last.signifiers.isNotEmpty &&
        last.status != LastNudgeStatus.sent &&
        last.status != LastNudgeStatus.waiting) {
      _showDeliveryBadges = true;
      for (final signifier in last.signifiers) {
        _expectedRecipients[signifier.userId] = _PendingRecipient(
          userId: signifier.userId,
          displayName: signifier.displayName,
        );
        final reply = signifier.reply;
        if (reply != null) {
          _repliesByUserId[signifier.userId] = reply;
        }
        _resultsByUserId[signifier.userId] = NudgeDeliveryResult(
          eventId: last.eventId,
          status: signifier.failed ? 'failed' : 'played',
          reason: signifier.failed
              ? (signifier.failureReason ??
                    (signifier.deviceBlocked
                        ? 'battery_optimization_active'
                        : 'unknown'))
              : null,
          attention: switch (signifier.band) {
            MediaVolumeBand.muted => 'volume_muted',
            MediaVolumeBand.veryLow => 'volume_very_low',
            MediaVolumeBand.low => 'volume_low',
            MediaVolumeBand.ok => null,
            null => null,
          },
          recipientUserId: signifier.userId,
          recipientName: signifier.displayName,
        );
      }
    }
    switch (last.status) {
      case LastNudgeStatus.sent:
      case LastNudgeStatus.waiting:
        _message = last.message;
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = last.status == LastNudgeStatus.waiting;
        break;
      case LastNudgeStatus.played:
      case LastNudgeStatus.volumeLow:
      case LastNudgeStatus.volumeMuted:
      case LastNudgeStatus.declined:
      case LastNudgeStatus.snoozed:
        if (last.message.isNotEmpty) {
          _message = last.message;
          _messageIsError = false;
          _messageIsWarning = last.status == LastNudgeStatus.volumeLow ||
              last.status == LastNudgeStatus.volumeMuted;
          _messagePending = false;
        }
        break;
      case LastNudgeStatus.failed:
        _message = last.message;
        _messageIsError = true;
        _messageIsWarning = false;
        _messagePending = false;
        break;
    }
  }

  void _recordLastStatus(
    LastNudgeStatus status,
    String message, {
    List<LastNudgeRecipientSignifier>? signifiers,
    String? eventId,
  }) {
    NudgeStatusMemory.instance.record(
      widget.group.groupId,
      LastNudgeState(
        eventId: eventId ?? _lastEventId ?? _awaitingEventId ?? '',
        status: status,
        message: message,
        at: DateTime.now(),
        kind: _lastSentNudgeKind,
        signifiers: signifiers ?? const [],
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

  List<GroupMemberSummary> get _nudgeableFriends =>
      _friends.where((f) => !_isOnline(f.userId)).toList(growable: false);

  bool get _canSend =>
      _nudgeableFriends.isNotEmpty &&
      _selectedUserIds.isNotEmpty &&
      !_busy &&
      !_startingRecording &&
      !_finishingRecording &&
      !_recording &&
      _awaitingEventId == null;

  /// True while the sheet must not dismiss (hold-to-speak, send in flight,
  /// or waiting on delivery confirmation). Barrier/drag dismiss are disabled
  /// for the whole sheet; this gates system back and the close button.
  bool get _sheetInteractionLocked =>
      _busy ||
      _recording ||
      _startingRecording ||
      _finishingRecording ||
      _pointerHeld ||
      _awaitingEventId != null;

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recordingCapTimer?.cancel();
    _cooldownTicker?.cancel();
    _deliveryTimeoutTimer?.cancel();
    _autoDismissTimer?.cancel();
    NudgeHaptics.stopWild();
    unawaited(_deliverySub?.cancel());
    unawaited(_responseSub?.cancel());
    if (_recording) unawaited(_recorder.stop());
    unawaited(_recorder.dispose());
    super.dispose();
  }

  List<_PendingRecipient> _recipientsForTarget() {
    final selected = _nudgeableFriends
        .where((f) => _selectedUserIds.contains(f.userId))
        .toList(growable: false);
    return selected
        .map(
          (f) =>
              _PendingRecipient(userId: f.userId, displayName: f.displayName),
        )
        .toList(growable: false);
  }

  bool get _isEveryoneSelected {
    final nudgeable = _nudgeableFriends;
    return nudgeable.isNotEmpty &&
        nudgeable.every((f) => _selectedUserIds.contains(f.userId));
  }

  void _selectEveryone() {
    setState(() {
      _selectedUserIds
        ..clear()
        ..addAll(_nudgeableFriends.map((f) => f.userId));
    });
  }

  void _toggleFriend(String userId) {
    if (_isOnline(userId)) return;
    setState(() {
      // Starting from "Everyone": first friend tap narrows to only that
      // person. Further taps then add/remove individuals selectively.
      if (_isEveryoneSelected) {
        _selectedUserIds
          ..clear()
          ..add(userId);
        return;
      }
      if (_selectedUserIds.contains(userId)) {
        if (_selectedUserIds.length == 1) return;
        _selectedUserIds.remove(userId);
      } else {
        _selectedUserIds.add(userId);
      }
    });
  }

  List<MediaVolumeRecipient> _volumeRecipients(
    List<_PendingRecipient> expected,
  ) => [
    for (final recipient in expected)
      MediaVolumeRecipient(
        userId: recipient.userId,
        displayName: recipient.displayName,
      ),
  ];

  Future<MediaVolumeFeedback> _loadVolumeFeedback(
    List<_PendingRecipient> expected,
  ) async {
    try {
      return await MediaVolumeStore.instance
          .feedbackFor(
            groupId: widget.group.groupId,
            recipients: _volumeRecipients(expected),
          )
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      return MediaVolumeFeedback.none;
    }
  }

  // ── Delivery badge helpers ──────────────────────────────────────────────────

  /// Returns true when this recipient's nudge was not played.
  bool _isDeliveryFailed(String userId) {
    if (!_showDeliveryBadges) return false;
    if (!_expectedRecipients.containsKey(userId)) return false;
    final result = _resultsByUserId[userId];
    return result != null && !result.played;
  }

  /// True when delivery failed because the recipient's own device/OS blocked
  /// it (permissions, force-stop, battery policy, etc.) — lock signifier.
  bool _isDeviceLockedFailure(String userId) {
    if (!_isDeliveryFailed(userId)) return false;
    return _resultsByUserId[userId]?.isReceiverDeviceBlocked ?? false;
  }

  NudgeRecipientReply? _replyFor(String userId) {
    if (!_showDeliveryBadges) return null;
    return _repliesByUserId[userId];
  }

  /// Returns the volume band to show as a corner badge for this recipient.
  /// Only returns a value for voice nudges (ring/PN never show volume bands
  /// per spec). Returns null when the avatar should show nothing extra.
  MediaVolumeBand? _volumeBandFor(String userId) {
    if (!_showDeliveryBadges) return null;
    if (_isDeliveryFailed(userId)) return null;
    if (_replyFor(userId) != null) return null;
    if (!_expectedRecipients.containsKey(userId)) return null;
    if (_lastSentNudgeKind != NudgeKind.voice) return null;

    // Ground truth: live playback attention flag from the receiver.
    final result = _resultsByUserId[userId];
    if (result != null && result.played) {
      final band = MediaVolumeBandX.fromAttention(result.attention);
      if (band != null) return band;
      // Played with no attention = volume was OK; show green badge.
      return MediaVolumeBand.ok;
    }

    // Fallback: RTDB self-report for recipients where we have no result yet
    // (e.g. awaiting-mid-delivery partial results) or for voice nudges whose
    // event IDs did not return a delivery ack (rare edge case).
    return _rtdbVolumeFeedback.bandsByUserId[userId];
  }

  // ── Send helpers ────────────────────────────────────────────────────────────

  Future<void> _prepareDeliveryWait({
    required String eventId,
    required List<_PendingRecipient> expected,
    required String waitingMessage,
  }) async {
    // Load RTDB volume for badge fallback data — but do not surface volume
    // warnings as text here; they appear as avatar badges after finalization.
    final feedback = await _loadVolumeFeedback(expected);
    if (!mounted) return;
    _rtdbVolumeFeedback = feedback;
    _beginAwaitingDeliveryConfirmation(
      eventId,
      waitingMessage: waitingMessage,
      expected: expected,
    );
  }

  void _beginAwaitingDeliveryConfirmation(
    String? eventId, {
    required String waitingMessage,
    required List<_PendingRecipient> expected,
  }) {
    if (eventId == null || eventId.isEmpty) return;
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Awaiting delivery confirmation eventId=$eventId '
          'expected=[${expected.map((e) => '${e.displayName}:${e.userId}').join(', ')}]',
      groupId: widget.group.groupId,
    );
    _deliveryTimeoutTimer?.cancel();
    _autoDismissTimer?.cancel();
    setState(() {
      _awaitingEventId = eventId;
      _lastEventId = eventId;
      _expectedRecipients
        ..clear()
        ..addEntries(expected.map((e) => MapEntry(e.userId, e)));
      _resultsByUserId.clear();
      _repliesByUserId.clear();
      // Step 2 text only for voice nudges — ring skips straight to icons.
      if (_showConfirmingText && waitingMessage.isNotEmpty) {
        _message = waitingMessage;
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = true;
      }
    });
    _recordLastStatus(
      LastNudgeStatus.waiting,
      'Waiting for receiver',
      eventId: eventId,
      signifiers: [
        for (final pending in expected)
          LastNudgeRecipientSignifier(
            userId: pending.userId,
            displayName: pending.displayName,
            failed: false,
          ),
      ],
    );
    _deliveryTimeoutTimer = Timer(_deliveryConfirmationTimeout, () {
      if (!mounted || _awaitingEventId != eventId) return;
      _finalizeDeliverySummary(timedOut: true);
    });
  }

  void _onDeliveryResult(NudgeDeliveryResult result) {
    if (!mounted) return;
    if (result.eventId != _awaitingEventId) {
      LogManager.log(
        LogLevel.warn,
        'NudgeService',
        'Delivery result ignored: eventId mismatch result=${result.eventId} '
            'awaiting=${_awaitingEventId} status=${result.status}',
        groupId: widget.group.groupId,
      );
      return;
    }
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery result matched eventId=${result.eventId} status=${result.status} '
          'reason=${result.reason ?? '-'} attention=${result.attention ?? '-'} '
          'recipientUserId=${result.recipientUserId ?? '-'} '
          'recipientName=${result.recipientName ?? '-'}',
      groupId: widget.group.groupId,
    );

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
    matchedId ??= _expectedRecipients.length == 1
        ? _expectedRecipients.keys.first
        : null;
    if (matchedId == null || matchedId.isEmpty) {
      matchedId =
          result.recipientUserId ??
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
      // Partial progress: trigger rebuild so in-flight badges update live.
      setState(() {});
    }
  }

  void _onRecipientResponse(NudgeRecipientResponse response) {
    if (!mounted) return;
    if (response.groupId != widget.group.groupId) return;
    final lastId = _lastEventId ?? _awaitingEventId;
    if (lastId != null &&
        lastId.isNotEmpty &&
        response.eventId != lastId) {
      return;
    }

    if (response.isAccept) {
      NudgeStatusMemory.instance.clear(widget.group.groupId);
      if (mounted) {
        setState(() {
          _repliesByUserId.clear();
          _showDeliveryBadges = false;
        });
      }
      return;
    }

    final reply = response.isDecline
        ? NudgeRecipientReply.declined
        : response.isSnooze
        ? NudgeRecipientReply.snoozed
        : null;
    if (reply == null) return;

    String? matchedId = response.responderUserId;
    if (matchedId == null || matchedId.isEmpty) {
      final name = response.responderName?.trim().toLowerCase();
      if (name != null && name.isNotEmpty) {
        matchedId = _expectedRecipients.entries
            .where((e) => e.value.displayName.trim().toLowerCase() == name)
            .map((e) => e.key)
            .firstOrNull;
      }
    }
    matchedId ??= _expectedRecipients.length == 1
        ? _expectedRecipients.keys.first
        : null;
    if (matchedId == null || matchedId.isEmpty) return;

    final displayName =
        response.responderName ??
        _expectedRecipients[matchedId]?.displayName ??
        'Friend';
    _expectedRecipients.putIfAbsent(
      matchedId,
      () => _PendingRecipient(userId: matchedId!, displayName: displayName),
    );
    _repliesByUserId[matchedId] = reply;
    _lastEventId ??= response.eventId;

    NudgeStatusMemory.instance.applyRecipientResponse(
      eventId: response.eventId,
      groupId: response.groupId,
      responderUserId: matchedId,
      responderName: displayName,
      action: response.action,
    );

    setState(() {
      _showDeliveryBadges = true;
      _message = null;
      _messageIsError = false;
      _messageIsWarning = false;
      _messagePending = false;
    });
    // Give the sender time to see the new reply badge.
    _scheduleAutoDismiss();
  }

  void _finalizeDeliverySummary({required bool timedOut}) {
    if (!mounted) return;
    LogManager.log(
      timedOut ? LogLevel.warn : LogLevel.info,
      'NudgeService',
      'Finalizing delivery summary timedOut=$timedOut '
          'results=[${_resultsByUserId.entries.map((e) => '${e.key}:${e.value.status}').join(', ')}] '
          'expected=[${_expectedRecipients.keys.join(', ')}]',
      groupId: widget.group.groupId,
    );
    final expected = _expectedRecipients.values.toList(growable: false);
    // Synthesize timeout failures for anyone without a result.
    for (final pending in expected) {
      if (!_resultsByUserId.containsKey(pending.userId)) {
        LogManager.log(
          LogLevel.warn,
          'NudgeService',
          'No delivery result for ${pending.displayName} (${pending.userId}); '
              'synthesizing failed/${timedOut ? 'timeout' : 'unknown'}',
          groupId: widget.group.groupId,
        );
        _resultsByUserId[pending.userId] = NudgeDeliveryResult(
          eventId: _awaitingEventId ?? '',
          status: 'failed',
          reason: timedOut ? 'timeout' : 'unknown',
          recipientUserId: pending.userId,
          recipientName: pending.displayName,
        );
      }
    }

    // Persist failure summaries so they can be shown on sheet reopen.
    final failed = <NudgeDeliveryResult>[];
    final failedNames = <String>[];
    for (final entry in _resultsByUserId.entries) {
      final result = entry.value;
      final name =
          result.recipientName ??
          _expectedRecipients[entry.key]?.displayName ??
          'them';
      if (!result.played) {
        failed.add(result);
        failedNames.add(name.trim().split(RegExp(r'\s+')).first);
      }
    }
    final volumeWarnings = _mergedVolumeWarnings();
    final totalRecipients = _resultsByUserId.length;
    if (failed.isEmpty) {
      NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
    } else {
      final persistMsg = failed.length == 1
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
        persistMsg,
      );
    }

    // Record status to memory for sheet reopen restoration.
    final summaryMessage = _buildDeliveryMessage(partial: false);
    final signifiers = _snapshotSignifiers();
    final anyDeclined = _repliesByUserId.values.any(
      (r) => r == NudgeRecipientReply.declined,
    );
    final anySnoozed = _repliesByUserId.values.any(
      (r) => r == NudgeRecipientReply.snoozed,
    );
    if (failed.isNotEmpty) {
      _recordLastStatus(
        LastNudgeStatus.failed,
        summaryMessage,
        signifiers: signifiers,
      );
    } else if (anyDeclined) {
      _recordLastStatus(
        LastNudgeStatus.declined,
        summaryMessage,
        signifiers: signifiers,
      );
    } else if (anySnoozed) {
      _recordLastStatus(
        LastNudgeStatus.snoozed,
        summaryMessage,
        signifiers: signifiers,
      );
    } else if (volumeWarnings.isNotEmpty) {
      final allMuted = volumeWarnings.every((l) => l.contains(' is muted'));
      _recordLastStatus(
        allMuted ? LastNudgeStatus.volumeMuted : LastNudgeStatus.volumeLow,
        summaryMessage,
        signifiers: signifiers,
      );
    } else {
      _recordLastStatus(
        LastNudgeStatus.played,
        summaryMessage,
        signifiers: signifiers,
      );
    }

    // Record status to memory for sheet reopen restoration. Keep the
    // confirmation text on screen — delivery badges alone were too easy
    // to miss, and auto-dismiss made "received" vanish.
    setState(() {
      _awaitingEventId = null;
      _messagePending = false;
      _showDeliveryBadges = true;
      _message = summaryMessage;
      _messageIsError = failed.isNotEmpty;
      _messageIsWarning = failed.isEmpty && volumeWarnings.isNotEmpty;
    });
  }

  String _buildDeliveryMessage({required bool partial}) {
    final expected = _expectedRecipients;
    final results = _resultsByUserId.values.toList(growable: false);
    if (results.isEmpty) {
      return partial
          ? 'Confirming delivery\u2026'
          : 'Nudge wasn\u2019t played, try again.';
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

    final volumeWarnings = _mergedVolumeWarnings();
    if (volumeWarnings.isNotEmpty) return volumeWarnings.join('\n');

    if (expected.length <= 1 && results.length == 1) {
      final name =
          results.first.recipientName ??
          expected.values.firstOrNull?.displayName;
      if (name == null) return 'Everyone received the nudge \u2713';
      if (_lastSentNudgeKind == NudgeKind.push) {
        return 'Nudge received on ${name.trim().split(RegExp(r'\s+')).first}\u2019s device';
      }
      return 'Nudge successfully playing on $name\u2019s device';
    }
    return 'Everyone received the nudge \u2713';
  }

  List<String> _mergedVolumeWarnings() {
    final warnings = <String>[];
    final covered = <String>{};

    void addWarning(String userId, String displayName, MediaVolumeBand? band) {
      if (band == null || !band.isWarning) return;
      if (!covered.add(userId)) return;
      warnings.add(band.warningMessage(mediaVolumeFirstName(displayName))!);
    }

    for (final entry in _resultsByUserId.entries) {
      final result = entry.value;
      if (!result.played) {
        covered.add(entry.key);
        continue;
      }
      final pending = _expectedRecipients[entry.key];
      final name = result.recipientName ?? pending?.displayName ?? 'They';
      addWarning(
        entry.key,
        name,
        MediaVolumeBandX.fromAttention(result.attention),
      );
      covered.add(entry.key);
    }

    for (final entry in _expectedRecipients.entries) {
      if (covered.contains(entry.key)) continue;
      final band = _rtdbVolumeFeedback.bandsByUserId[entry.key];
      addWarning(entry.key, entry.value.displayName, band);
    }
    return warnings;
  }

  String _joinNames(List<String> names) {
    if (names.isEmpty) return 'Someone';
    if (names.length == 1) return names.first;
    if (names.length == 2) return '${names[0]} and ${names[1]}';
    return '${names.sublist(0, names.length - 1).join(', ')}, and ${names.last}';
  }

  String _shortFailureWithReason(String name, String? reason) {
    switch (NudgeDeliveryFailure.canonicalReason(reason)) {
      case 'permission_denied_notifications':
        return 'Nudge did not reach $name \u2014 notifications are turned off '
            'on their phone. Ask them to re-enable Duo notifications.';
      case 'permission_denied_microphone':
        return 'Nudge did not reach $name \u2014 microphone access was blocked '
            'on their phone.';
      case 'background_fg_service_blocked':
      case 'permission_denied_foreground_service':
        return 'Nudge did not reach $name \u2014 their phone blocked the app '
            'from playing it. Ask them to reopen Duo.';
      case 'battery_optimization_active':
        return 'Nudge did not reach $name \u2014 battery restrictions on their '
            'phone may be blocking Duo in the background.';
      case 'fcm_not_delivered':
      case 'app_force_stopped':
      case 'timeout':
        return 'Nudge did not reach $name \u2014 their phone may have Duo closed, '
            'force-stopped, or restricted. Ask them to reopen the app.';
      case 'playback_error':
      case 'playback_service_start_error':
      case 'download_error':
        return 'Nudge did not reach $name \u2014 something went wrong on '
            'Duo\u2019s end.';
      default:
        return 'Nudge did not reach $name.';
    }
  }

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

  List<LastNudgeRecipientSignifier> _snapshotSignifiers() {
    // Read results directly — do NOT gate on [_showDeliveryBadges]. Finalize
    // snapshots signifiers before flipping that flag; using the badge helpers
    // here previously forced every failure to deviceBlocked=false (skull), so
    // reopening the sheet flipped lock → skull with no real state change.
    final signifiers = <LastNudgeRecipientSignifier>[];
    for (final pending in _expectedRecipients.values) {
      final result = _resultsByUserId[pending.userId];
      final failed = result?.played == false;
      signifiers.add(
        LastNudgeRecipientSignifier(
          userId: pending.userId,
          displayName: pending.displayName,
          failed: failed,
          deviceBlocked: failed && (result?.isReceiverDeviceBlocked ?? false),
          failureReason: failed ? result?.reason : null,
          band: _snapshotBandFor(pending.userId),
          reply: _repliesByUserId[pending.userId],
        ),
      );
    }
    return signifiers;
  }

  MediaVolumeBand? _snapshotBandFor(String userId) {
    final result = _resultsByUserId[userId];
    if (result != null && !result.played) return null;
    if (_lastSentNudgeKind != NudgeKind.voice) return null;
    if (result != null && result.played) {
      return MediaVolumeBandX.fromAttention(result.attention) ??
          MediaVolumeBand.ok;
    }
    return _rtdbVolumeFeedback.bandsByUserId[userId];
  }

  Duration _cooldownRemaining(NudgeKind kind) => _cooldowns.remaining(kind);

  String _cooldownLabel(Duration remaining) {
    final seconds = remaining.inMilliseconds / 1000;
    return seconds <= 1 ? 'wait 1s' : 'wait ${seconds.ceil()}s';
  }

  void _scheduleAutoDismiss() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = Timer(_autoDismissDelay, () {
      if (!mounted) return;
      if (_recording ||
          _startingRecording ||
          _finishingRecording ||
          _awaitingEventId != null) {
        return;
      }
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });
  }

  // ── Ring ─────────────────────────────────────────────────────────────────

  /// Single tap rings for 5s; double tap rings for 10s.
  /// Ring skips the "Confirming…" text step and shows results as avatar badges.
  Future<void> _sendRing({required int durationSeconds}) async {
    if (_cooldownRemaining(NudgeKind.ring) > Duration.zero) return;
    _lastSentNudgeKind = NudgeKind.ring;
    _showConfirmingText = true;
    await _send(
      () => _repository.sendRing(
        groupId: widget.group.groupId,
        target: _effectiveTarget(),
        durationSeconds: durationSeconds,
      ),
      kind: NudgeKind.ring,
      awaitsDeliveryConfirmation: true,
      waitingMessage: 'Confirming if they received\u2026',
    );
  }

  // ── Push ─────────────────────────────────────────────────────────────────

  /// Sends a push notification and waits for the recipient device to confirm
  /// it actually posted the shade notification.
  Future<void> _sendPush() async {
    if (_cooldownRemaining(NudgeKind.push) > Duration.zero) return;
    _lastSentNudgeKind = NudgeKind.push;
    _showConfirmingText = true;
    await _send(
      () => _repository.sendPush(
        groupId: widget.group.groupId,
        target: _effectiveTarget(),
      ),
      kind: NudgeKind.push,
      awaitsDeliveryConfirmation: true,
      waitingMessage: 'Confirming if they received\u2026',
    );
  }

  NudgeTarget _effectiveTarget() {
    final selected = _nudgeableFriends
        .where((f) => _selectedUserIds.contains(f.userId))
        .map((f) => f.userId)
        .toList(growable: false);
    if (selected.isEmpty || selected.length == _nudgeableFriends.length) {
      return const NudgeTarget.allFriends();
    }
    if (selected.length == 1) {
      return NudgeTarget.singleFriend(selected.first);
    }
    return NudgeTarget.selectedFriends(selected);
  }

  Future<void> _send(
    Future<Object?> Function() action, {
    required NudgeKind kind,
    bool awaitsDeliveryConfirmation = false,
    String waitingMessage = '',
    bool silentSuccess = false,
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
    setState(() {
      _busy = true;
      _message = null;
      _messageIsError = false;
      _messageIsWarning = false;
      _messagePending = false;
      _showDeliveryBadges = false;
      _repliesByUserId.clear();
    });
    _rtdbVolumeFeedback = MediaVolumeFeedback.none;
    try {
      final result = await action();
      _cooldowns.record(kind);
      if (!mounted) return;
      setState(() => _busy = false);
      if (awaitsDeliveryConfirmation && result is Map) {
        final eventId = result['notificationEventId']?.toString();
        if (eventId != null && eventId.isNotEmpty) {
          _scheduleSenderExpiry(eventId, expected);
          await _prepareDeliveryWait(
            eventId: eventId,
            expected: expected,
            waitingMessage: waitingMessage,
          );
          return;
        }
      }
      if (!awaitsDeliveryConfirmation && result is Map) {
        final eventId = result['notificationEventId']?.toString();
        if (eventId != null && eventId.isNotEmpty) {
          _lastEventId = eventId;
          _scheduleSenderExpiry(eventId, expected);
        }
      }
      // Check aggregate send/failed counts before claiming success.
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
          unawaited(
            CrashlyticsService.recordNudgeFailure(
              error: StateError(message),
              failureReason: NudgeFailureReason.fcmNotDelivered,
              senderId: widget.currentUserId,
              groupId: widget.group.groupId,
              extras: {
                'failed_count': nudgeResult.failedCount,
                'total_recipients': nudgeResult.totalRecipients,
              },
            ),
          );
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

      if (silentSuccess) {
        // Push/PN: no delivery confirmation, no volume badges (spec).
        // Still seed recipient signifiers so decline/snooze can land later.
        NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
        _expectedRecipients
          ..clear()
          ..addEntries(expected.map((e) => MapEntry(e.userId, e)));
        final signifiers = [
          for (final pending in expected)
            LastNudgeRecipientSignifier(
              userId: pending.userId,
              displayName: pending.displayName,
              failed: false,
            ),
        ];
        _recordLastStatus(
          LastNudgeStatus.sent,
          'Sent',
          eventId: _lastEventId,
          signifiers: signifiers,
        );
        setState(() {
          _message = null;
          _messageIsError = false;
          _messageIsWarning = false;
          _messagePending = false;
        });
        _scheduleAutoDismiss();
      } else {
        await _showImmediateSendOutcome(expected);
      }
    } catch (error, stack) {
      final cancelled = error.toString().toLowerCase().contains('cancel');
      final expectedDelivery = error is NudgeDeliveryException;
      if (!cancelled && !expectedDelivery) {
        unawaited(
          CrashlyticsService.recordNudgeFailure(
            error: error,
            stack: stack,
            failureReason:
                error is ApiException && error.code == 'permission_denied'
                ? NudgeFailureReason.permissionDeniedFirebase
                : NudgeFailureReason.unknown,
            senderId: widget.currentUserId,
            groupId: widget.group.groupId,
          ),
        );
      }
      if (!mounted) return;
      final rateLimited =
          error is ApiException && error.code == 'nudge_rate_limited';
      final message = rateLimited ? error.message : _friendlyError(error);
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

  Future<void> _showImmediateSendOutcome(
    List<_PendingRecipient> expected,
  ) async {
    if (mounted) {
      setState(() {
        _message = 'Sent\u2026';
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = true;
      });
    }
    final feedback = await _loadVolumeFeedback(expected);
    if (!mounted) return;
    _rtdbVolumeFeedback = feedback;
    if (feedback.hasWarnings) {
      NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
      _recordLastStatus(
        _statusForVolumeWarnings(feedback),
        feedback.joinedWarnings,
      );
      setState(() {
        _message = feedback.joinedWarnings;
        _messageIsError = false;
        _messageIsWarning = true;
        _messagePending = false;
      });
    } else {
      final successMessage = MediaVolumeFeedback.successMessage(
        recipientCount: expected.length,
        singleFirstName: expected.length == 1
            ? mediaVolumeFirstName(expected.first.displayName)
            : null,
      );
      NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
      _recordLastStatus(LastNudgeStatus.sent, successMessage);
      setState(() {
        _message = successMessage;
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = false;
      });
    }
    _scheduleAutoDismiss();
  }

  LastNudgeStatus _statusForVolumeWarnings(MediaVolumeFeedback feedback) {
    final anyMuted = feedback.bandsByUserId.values.any(
      (band) => band == MediaVolumeBand.muted,
    );
    return anyMuted ? LastNudgeStatus.volumeMuted : LastNudgeStatus.volumeLow;
  }

  // ── Voice recording ─────────────────────────────────────────────────────

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
        '${Directory.systemTemp.path}/one_one_voice_${DateTime.now().microsecondsSinceEpoch}.${VoiceNudgeAudio.fileExtension}',
      );
      await _recorder.start(VoiceNudgeAudio.recordConfig, path: file.path);
      if (!mounted) {
        await _recorder.stop();
        return;
      }
      _recordingWatch
        ..reset()
        ..start();
      _recordingTimer?.cancel();
      _recordingCapTimer?.cancel();
      _recordingCapTimer = Timer(VoiceNudgeAudio.maxRecordingDuration, () {
        unawaited(_finishRecording(send: true));
      });
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'Voice recording start capMs=${VoiceNudgeAudio.maxRecordingDuration.inMilliseconds}',
        groupId: widget.group.groupId,
      );
      _recordingTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (!mounted || !_recording) return;
        setState(() => _elapsed = _recordingWatch.elapsed);
      });
      setState(() {
        _recording = true;
        _elapsed = Duration.zero;
        _message = 'Recording\u2026 release to send';
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = true;
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
    _recordingCapTimer?.cancel();
    _recordingWatch.stop();
    unawaited(NudgeHaptics.playEnd(widget.hapticsIntensity));
    final actualDurationMs = _recordingWatch.elapsedMilliseconds;
    final durationMs = actualDurationMs.clamp(
      0,
      VoiceNudgeAudio.maxAcceptedDurationMs,
    );
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Voice recording end durationMs=$actualDurationMs '
          'send=$send capMs=${VoiceNudgeAudio.maxRecordingDuration.inMilliseconds}',
      groupId: widget.group.groupId,
    );
    if (mounted) {
      setState(() {
        _recording = false;
        _busy = send;
        _sendingVoice = send;
        // Step 1: "Voice nudge sending"
        _message = send ? 'Voice nudge sending\u2026' : null;
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = send;
        _showDeliveryBadges = false;
      });
    }

    String? path;
    var sent = false;
    String? voiceEventId;
    final minMs = VoiceNudgeAudio.minRecordingDuration.inMilliseconds;
    final uploadReservation = send && durationMs >= minMs
        ? _repository.initiateVoiceUpload(
            groupId: widget.group.groupId,
            target: _effectiveTarget(),
            durationMs: durationMs,
          )
        : null;
    try {
      final stopWatch = Stopwatch()..start();
      path = await _recorder.stop();
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'Voice recorder flush elapsedMs=${stopWatch.elapsedMilliseconds} '
            'path=${path != null}',
        groupId: widget.group.groupId,
      );
      if (!send || path == null) return;
      if (durationMs < minMs) {
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
      Map<String, dynamic>? initiatedUpload;
      if (uploadReservation != null) {
        try {
          initiatedUpload = await uploadReservation;
        } catch (_) {
          initiatedUpload = null;
        }
      }
      final response = await _repository.sendVoice(
        groupId: widget.group.groupId,
        target: _effectiveTarget(),
        audio: await file.readAsBytes(),
        durationMs: durationMs,
        initiatedUpload: initiatedUpload,
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
        } catch (_) {}
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
          // Voice nudge: show step 2 "Confirming if everyone received"
          // then transition to avatar badges on finalization.
          _lastSentNudgeKind = NudgeKind.voice;
          _showConfirmingText = true;
          await _prepareDeliveryWait(
            eventId: voiceEventId,
            expected: _recipientsForTarget(),
            waitingMessage: 'Confirming if everyone received\u2026',
          );
        } else if (sent) {
          await _showImmediateSendOutcome(_recipientsForTarget());
        }
      }
    }
  }

  String _friendlyError(Object error) {
    if (error is ApiException && error.code == 'nudge_rate_limited') {
      return error.message;
    }
    if (error is NudgeDeliveryException) {
      return UserFacingCopy.sanitize(error.message);
    }
    final text = error.toString();
    if (UserFacingCopy.containsInternalIdentifier(text)) {
      return UserFacingCopy.notificationDeliveryFailure;
    }
    if (text.contains('nudge_rate_limited')) {
      return 'Nudge limit reached. Please wait before trying again.';
    }
    if (text.contains('voice_nudge_too_large')) {
      return 'Recording was too large. Try again.';
    }
    return 'Couldn\u2019t send the nudge. Check your connection.';
  }

  // ── Build ───────────────────────────────────────────────────────────────

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
        (_elapsed.inMilliseconds /
                VoiceNudgeAudio.maxRecordingDuration.inMilliseconds)
            .clamp(0.0, 1.0);
    final accent = widget.accent;

    // Errors, confirming, received/failed confirmation, and empty-group guards.
    final showStatus =
        _friends.isEmpty ||
        _nudgeableFriends.isEmpty ||
        _message != null;

    return PopScope(
      canPop: !_sheetInteractionLocked,
      child: Material(
        color: const Color(0xff141414),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28.r)),
        clipBehavior: Clip.antiAlias,
        child: BottomSystemSafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 15),
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
                                SizedBox(height: 4.h),
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
                            onPressed: _sheetInteractionLocked
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

                    SizedBox(height: 16.h),

                    // ── Recipient picker (with delivery state badges) ──
                    Padding(
                      padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 10.h),
                      child: Text(
                        'Whom do you want to reach?',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 100.h,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        clipBehavior: Clip.none,
                        padding: EdgeInsets.symmetric(horizontal: 20.w),
                        children: [
                          // "Everyone" group chip — no delivery badge (not a user)
                          _NudgeRecipient(
                            label: 'Everyone',
                            selected: _isEveryoneSelected,
                            accent: accent,
                            enabled:
                                actionEnabled && _nudgeableFriends.isNotEmpty,
                            onTap: actionEnabled && _nudgeableFriends.isNotEmpty
                                ? _selectEveryone
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
                            SizedBox(width: 14.w),
                            Builder(
                              builder: (context) {
                                final online = _isOnline(friend.userId);
                                final failed = _isDeliveryFailed(friend.userId);
                                final deviceLocked =
                                    _isDeviceLockedFailure(friend.userId);
                                final reply = _replyFor(friend.userId);
                                final volumeBand = _volumeBandFor(
                                  friend.userId,
                                );
                                final Widget? deliveryBadge = failed
                                    ? null
                                    : reply != null
                                    ? _ResponseBadgeIcon(reply: reply)
                                    : volumeBand != null
                                    ? _VolumeBadgeIcon(band: volumeBand)
                                    : null;
                                return _NudgeRecipient(
                                  label: friend.displayName,
                                  subtitle: online ? 'already online' : null,
                                  selected:
                                      !online &&
                                      _selectedUserIds.contains(friend.userId),
                                  accent: accent,
                                  enabled: actionEnabled && !online,
                                  dimmed: online,
                                  onTap: actionEnabled && !online
                                      ? () => _toggleFriend(friend.userId)
                                      : null,
                                  deliveryBadge: deliveryBadge,
                                  avatar: Opacity(
                                    opacity: online ? 0.38 : 1,
                                    child: _buildFriendAvatar(
                                      friend: friend,
                                      failed: failed,
                                      deviceLocked: deviceLocked,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),

                    SizedBox(height: 16.h),
                    _SheetDivider(),
                    SizedBox(height: 28.h),

                    // ── Primary action: voice nudge ──
                    Center(
                      child: _buildVoiceMicButton(
                        accent: accent,
                        voiceEnabled: voiceEnabled,
                        recordingProgress: recordingProgress,
                        voiceCooldown: voiceCooldown,
                      ),
                    ),

                    SizedBox(height: 28.h),

                    // ── Secondary actions: ring + push ──
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24.w),
                      child: Text(
                        'More ways to get their attention',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15.sp,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                    ),
                    SizedBox(height: 18.h),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 48.w),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _RingActionButton(
                            enabled: ringEnabled,
                            cooldownLabel: ringCooldown > Duration.zero
                                ? _cooldownLabel(ringCooldown)
                                : null,
                            onTap: () => unawaited(
                              _sendRing(
                                durationSeconds: _ringTapDurationSeconds,
                              ),
                            ),
                            onDoubleTap: () => unawaited(
                              _sendRing(
                                durationSeconds: _ringDoubleTapDurationSeconds,
                              ),
                            ),
                          ),
                          _PushActionButton(
                            enabled: pushEnabled,
                            cooldownLabel: pushCooldown > Duration.zero
                                ? _cooldownLabel(pushCooldown)
                                : null,
                            onTap: _sendPush,
                          ),
                        ],
                      ),
                    ),

                    SizedBox(height: 24.h),

                    // ── Status (step 1, step 2, errors, guards) ──
                    if (showStatus) ...[
                      Padding(
                        padding: EdgeInsets.fromLTRB(20.w, 0, 20.w, 0),
                        child: _NudgeStatus(
                          message: _friends.isEmpty
                              ? 'Invite a friend before sending a nudge.'
                              : _nudgeableFriends.isEmpty && _message == null
                              ? 'Everyone is already online \u2014 no nudge needed.'
                              : UserFacingCopy.sanitize(
                                  _message!,
                                  fallback: UserFacingCopy
                                      .notificationDeliveryFailure,
                                ),
                          isError:
                              _friends.isEmpty ||
                              (_messageIsError && _message != null),
                          isWarning: _messageIsWarning && _message != null,
                          isPending: _friends.isEmpty ? false : _messagePending,
                        ),
                      ),
                    ],

                    SizedBox(height: 32.h),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a friend's avatar with optional failure overlay:
  /// lock (recipient device blocked) or skull (Duo/unknown failure).
  Widget _buildFriendAvatar({
    required GroupMemberSummary friend,
    required bool failed,
    required bool deviceLocked,
  }) {
    final baseAvatar = ProfileAvatar(
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
    );

    if (!failed) return baseAvatar;

    // Grayscale + lock/skull for "nudge not received" states.
    final overlay = deviceLocked
        ? Icon(LucideIcons.lock, color: Colors.white70, size: 18.sp)
        : Text(
            '\u{1F480}',
            textScaler: TextScaler.noScaling,
            style: TextStyle(fontSize: 18.sp),
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0.2126,
            0.7152,
            0.0722,
            0,
            0,
            0,
            0,
            0,
            1,
            0,
          ]),
          child: baseAvatar,
        ),
        Center(child: overlay),
      ],
    );
  }

  /// Builds the primary voice mic button (unchanged press-and-hold behavior).
  Widget _buildVoiceMicButton({
    required Color accent,
    required bool voiceEnabled,
    required double recordingProgress,
    required Duration voiceCooldown,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
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
              unawaited(NudgeHaptics.playStart(widget.hapticsIntensity));
              // Lock back/close on the same frame as press — before async
              // mic start — so a second gesture cannot pop the sheet.
              setState(() {
                _pointerHeld = true;
                _sendAfterPointerEnd = true;
              });
              unawaited(_beginRecording());
            },
            onPointerUp: (_) {
              setState(() {
                _pointerHeld = false;
                _sendAfterPointerEnd = true;
              });
              unawaited(_finishRecording(send: true));
            },
            onPointerCancel: (_) {
              setState(() {
                _pointerHeld = false;
                _sendAfterPointerEnd = false;
              });
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
                            value: _recording ? recordingProgress : 0,
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
        SizedBox(height: 8.h),
        Text(
          voiceCooldown > Duration.zero
              ? _cooldownLabel(voiceCooldown)
              : _recording
              ? '${(_elapsed.inMilliseconds / 1000).toStringAsFixed(1)} / 6.0s'
              : _sendingVoice
              ? 'Sending\u2026'
              : 'Hold to speak',
          style: TextStyle(
            color: _recording || _sendingVoice
                ? accent
                : voiceEnabled
                ? Colors.white70
                : Colors.white24,
            fontSize: 13.sp,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ── Sending animation ──────────────────────────────────────────────────────

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

// ── Shared divider ─────────────────────────────────────────────────────────

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

// ── Ring action button ─────────────────────────────────────────────────────
//
// Secondary control under "More ways to get their attention". Icon + label
// only — no circular chrome, so it does not compete with the primary mic.
// Single tap sends a 5s ring; double tap sends a 10s ring.

class _RingActionButton extends StatelessWidget {
  const _RingActionButton({
    required this.enabled,
    required this.onTap,
    required this.onDoubleTap,
    this.cooldownLabel,
  });

  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final String? cooldownLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Ring their phone',
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        onDoubleTap: enabled ? onDoubleTap : null,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: 72.w, minHeight: 48.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.all(8.r),
                child: Icon(
                  LucideIcons.bellRing,
                  color: enabled ? Colors.white70 : Colors.white24,
                  size: 28.sp,
                ),
              ),
              SizedBox(height: 4.h),
              Text(
                cooldownLabel ?? 'Ring',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: enabled ? Colors.white54 : Colors.white24,
                  fontSize: 12.sp,
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

// ── Push notification action button ────────────────────────────────────────
//
// Secondary control under "More ways to get their attention". Icon + label
// only — no circular chrome, so it does not compete with the primary mic.

class _PushActionButton extends StatelessWidget {
  const _PushActionButton({
    required this.enabled,
    required this.onTap,
    this.cooldownLabel,
  });

  final bool enabled;
  final VoidCallback onTap;
  final String? cooldownLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: enabled,
      label: 'Send a notification',
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        behavior: HitTestBehavior.opaque,
        child: ConstrainedBox(
          constraints: BoxConstraints(minWidth: 72.w, minHeight: 48.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: EdgeInsets.all(8.r),
                child: Icon(
                  LucideIcons.send,
                  color: enabled ? Colors.white70 : Colors.white24,
                  size: 28.sp,
                ),
              ),
              SizedBox(height: 4.h),
              Text(
                cooldownLabel ?? 'Notify',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: enabled ? Colors.white54 : Colors.white24,
                  fontSize: 12.sp,
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

// ── Volume badge icon ───────────────────────────────────────────────────────
//
// Small circular overlay shown at the bottom-right corner of a recipient's
// avatar after a voice nudge is delivered. Uses Lucide volume icons to
// communicate the receiver's device volume at playback time.
//
// Icon mapping (per spec):
//   Volume > 50%  → LucideIcons.volume2  (green)
//   Volume < 50%  → LucideIcons.volume1  (yellow)
//   Volume < 25%  → LucideIcons.volume   (red)
//   Muted         → LucideIcons.volumeX  (red)  — iOS-convention speaker+X

class _VolumeBadgeIcon extends StatelessWidget {
  const _VolumeBadgeIcon({required this.band});

  final MediaVolumeBand band;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (band) {
      MediaVolumeBand.muted => (LucideIcons.volumeX, const Color(0xffff4040)),
      MediaVolumeBand.veryLow => (LucideIcons.volume, const Color(0xffff4040)),
      MediaVolumeBand.low => (LucideIcons.volume1, const Color(0xffe0a83c)),
      MediaVolumeBand.ok => (LucideIcons.volume2, const Color(0xff4caf50)),
    };
    return _AvatarCornerBadge(icon: icon, color: color);
  }
}

// ── Decline / snooze badge icon ─────────────────────────────────────────────
//
// Same corner badge chrome as volume. Maps recipient reply to Lucide icons:
//   Declined → LucideIcons.moon   (💤 — can't join right now)
//   Snoozed  → LucideIcons.timer  (⏳ — ask me later)

class _ResponseBadgeIcon extends StatelessWidget {
  const _ResponseBadgeIcon({required this.reply});

  final NudgeRecipientReply reply;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (reply) {
      NudgeRecipientReply.declined => (
        LucideIcons.moon,
        const Color(0xff8e9aaf),
      ),
      NudgeRecipientReply.snoozed => (
        LucideIcons.timer,
        const Color(0xffe0a83c),
      ),
    };
    return _AvatarCornerBadge(icon: icon, color: color);
  }
}

class _AvatarCornerBadge extends StatelessWidget {
  const _AvatarCornerBadge({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26.r,
      height: 26.r,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: const Color(0xff1c1c1c),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.28),
          width: 1.2,
        ),
      ),
      child: Center(
        child: Icon(icon, size: 15.sp, color: color),
      ),
    );
  }
}

// ── Recipient chip ─────────────────────────────────────────────────────────

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
    this.deliveryBadge,
  });

  final String label;
  final bool selected;
  final Color accent;
  final Widget avatar;
  final VoidCallback? onTap;
  final bool enabled;
  final bool dimmed;
  final String? subtitle;

  /// Small icon widget shown at the bottom-right corner of the avatar circle.
  /// Used for Lucide volume badges. Skull state is embedded in [avatar] itself.
  final Widget? deliveryBadge;

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
          width: 68.w,
          child: Column(
            children: [
              Stack(
                clipBehavior: Clip.none,
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
                  if (deliveryBadge != null)
                    Positioned(right: -6, bottom: -6, child: deliveryBadge!),
                ],
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

// ── Status banner ──────────────────────────────────────────────────────────
//
// Shown for send progress, delivery confirmation ("received"), errors, and
// empty-group / everyone-online guards. Avatar badges still show per-person
// lock / skull / volume on top of this.

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
              maxLines: 6,
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
