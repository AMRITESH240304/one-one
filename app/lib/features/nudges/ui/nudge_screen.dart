import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../identity/ui/profile_avatar.dart';
import '../data/android_voice_nudge_bridge.dart';
import '../data/media_volume_store.dart';
import '../data/nudge_repository.dart';
import '../data/voice_nudge_audio.dart';
import '../models/media_volume_reading.dart';
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
    useSafeArea: false,
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
  String? _awaitingEventId;
  Timer? _deliveryTimeoutTimer;
  final Map<String, _PendingRecipient> _expectedRecipients = {};
  final Map<String, NudgeDeliveryResult> _resultsByUserId = {};
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
    if (last.signifiers.isNotEmpty &&
        last.status != LastNudgeStatus.sent &&
        last.status != LastNudgeStatus.waiting) {
      _showDeliveryBadges = true;
      for (final signifier in last.signifiers) {
        _expectedRecipients[signifier.userId] = _PendingRecipient(
          userId: signifier.userId,
          displayName: signifier.displayName,
        );
        _resultsByUserId[signifier.userId] = NudgeDeliveryResult(
          eventId: last.eventId,
          status: signifier.failed ? 'failed' : 'played',
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
        _messagePending = true;
        break;
      case LastNudgeStatus.played:
      case LastNudgeStatus.volumeLow:
      case LastNudgeStatus.volumeMuted:
        // Delivery outcome is restored as avatar signifiers, not text.
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
  }) {
    NudgeStatusMemory.instance.record(
      widget.group.groupId,
      LastNudgeState(
        eventId: _awaitingEventId ?? '',
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

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recordingCapTimer?.cancel();
    _cooldownTicker?.cancel();
    _deliveryTimeoutTimer?.cancel();
    _autoDismissTimer?.cancel();
    unawaited(_deliverySub?.cancel());
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

  /// Returns true when this recipient's nudge was not played (skull state).
  bool _isDeliveryFailed(String userId) {
    if (!_showDeliveryBadges) return false;
    if (!_expectedRecipients.containsKey(userId)) return false;
    final result = _resultsByUserId[userId];
    return result != null && !result.played;
  }

  /// Returns the volume band to show as a corner badge for this recipient.
  /// Only returns a value for voice nudges (ring/PN never show volume bands
  /// per spec). Returns null when the avatar should show nothing extra.
  MediaVolumeBand? _volumeBandFor(String userId) {
    if (!_showDeliveryBadges) return null;
    if (_isDeliveryFailed(userId)) return null;
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
      _expectedRecipients
        ..clear()
        ..addEntries(expected.map((e) => MapEntry(e.userId, e)));
      _resultsByUserId.clear();
      // Step 2 text only for voice nudges — ring skips straight to icons.
      if (_showConfirmingText && waitingMessage.isNotEmpty) {
        _message = waitingMessage;
        _messageIsError = false;
        _messageIsWarning = false;
        _messagePending = true;
      }
    });
    _recordLastStatus(LastNudgeStatus.waiting, 'Waiting for receiver');
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
    if (failed.isNotEmpty) {
      _recordLastStatus(
        LastNudgeStatus.failed,
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

    // Steps 3 & 4: delivery state is communicated entirely through profile
    // icon signifiers — no text notifiers shown.
    setState(() {
      _awaitingEventId = null;
      _messagePending = false;
      _showDeliveryBadges = true;
      _message = null;
      _messageIsError = false;
      _messageIsWarning = false;
    });
    _scheduleAutoDismiss();
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
    switch (reason) {
      case 'permission_denied_foreground_service':
        return 'Nudge did not reach $name \u2014 their phone blocked the app '
            'from playing it. Ask them to reopen Duo.';
      case 'playback_error':
      case 'playback_service_start_error':
      case 'download_error':
      case 'timeout':
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
    return [
      for (final pending in _expectedRecipients.values)
        LastNudgeRecipientSignifier(
          userId: pending.userId,
          displayName: pending.displayName,
          failed: _resultsByUserId[pending.userId]?.played == false,
          band: _snapshotBandFor(pending.userId),
        ),
    ];
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
    _showConfirmingText = false; // ring skips step 2 text
    await _send(
      () => _repository.sendRing(
        groupId: widget.group.groupId,
        target: _effectiveTarget(),
        durationSeconds: durationSeconds,
      ),
      kind: NudgeKind.ring,
      awaitsDeliveryConfirmation: true,
      waitingMessage: '',
    );
  }

  // ── Push ─────────────────────────────────────────────────────────────────

  /// Sends a push notification. No delivery confirmation, no volume badges —
  /// per spec, PN nudges skip steps 2 & 3 entirely and use silent success.
  Future<void> _sendPush() async {
    if (_cooldownRemaining(NudgeKind.push) > Duration.zero) return;
    _lastSentNudgeKind = NudgeKind.push;
    _showConfirmingText = false;
    await _send(
      () => _repository.sendPush(
        groupId: widget.group.groupId,
        target: _effectiveTarget(),
      ),
      kind: NudgeKind.push,
      silentSuccess: true,
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
        // Clear any stale failure and dismiss silently.
        NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
        _recordLastStatus(LastNudgeStatus.sent, 'Sent');
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
      if (widget.hapticsEnabled) unawaited(HapticFeedback.mediumImpact());
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
            .clamp(
          0.0,
          1.0,
        );
    final accent = widget.accent;

    // Only show status widget for: errors, no-friends/all-online guards,
    // step 1 (voice uploading), and step 2 (voice confirming).
    // Delivery results (steps 3 & 4) are shown as avatar badges only.
    final showStatus =
        _friends.isEmpty ||
        _nudgeableFriends.isEmpty ||
        (_messageIsError && _message != null) ||
        (_sendingVoice && _message != null) ||
        (_messagePending && _awaitingEventId != null && _message != null);

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

                // ── Recipient picker (with delivery state badges) ──
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
                        enabled: actionEnabled && _nudgeableFriends.isNotEmpty,
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
                            final volumeBand = _volumeBandFor(friend.userId);
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
                              deliveryBadge: (!failed && volumeBand != null)
                                  ? _VolumeBadgeIcon(band: volumeBand)
                                  : null,
                              avatar: Opacity(
                                opacity: online ? 0.38 : 1,
                                child: _buildFriendAvatar(
                                  friend: friend,
                                  failed: failed,
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                ),

                SizedBox(height: 20.h),
                _SheetDivider(),
                SizedBox(height: 24.h),

                // ── Three-element action row: Ring | Voice | Push ──
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 24.w),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Left: Ring duration selector
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

                      // Center: Voice mic (press-and-hold, unchanged behavior)
                      _buildVoiceMicButton(
                        accent: accent,
                        voiceEnabled: voiceEnabled,
                        recordingProgress: recordingProgress,
                        voiceCooldown: voiceCooldown,
                      ),

                      // Right: Push notification
                      _PushActionButton(
                        accent: accent,
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
                              fallback:
                                  UserFacingCopy.notificationDeliveryFailure,
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

  /// Builds a friend's avatar with optional skull+grayscale overlay for
  /// failed delivery state.
  Widget _buildFriendAvatar({
    required GroupMemberSummary friend,
    required bool failed,
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

    // Grayscale + skull for "nudge not received at all" state.
    return Stack(
      fit: StackFit.expand,
      children: [
        ColorFiltered(
          colorFilter: const ColorFilter.matrix([
            0.2126, 0.7152, 0.0722, 0, 0,
            0.2126, 0.7152, 0.0722, 0, 0,
            0.2126, 0.7152, 0.0722, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: baseAvatar,
        ),
        Center(
          child: Text(
            '\u{1F480}',
            textScaler: TextScaler.noScaling,
            style: TextStyle(fontSize: 18.sp),
          ),
        ),
      ],
    );
  }

  /// Builds the central voice mic button (unchanged behavior, new sizing).
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
              if (widget.hapticsEnabled) unawaited(HapticFeedback.lightImpact());
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
              : 'Hold to record',
          style: TextStyle(
            color: _recording || _sendingVoice
                ? accent
                : voiceEnabled
                ? Colors.white54
                : Colors.white24,
            fontSize: 11.sp,
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
// Circular button on the left of the three-element row. Matches the notify
// button chrome (not the accent). Single tap sends a 5s ring; double tap
// sends a 10s ring.

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: enabled ? onTap : null,
          onDoubleTap: enabled ? onDoubleTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 72.r,
            height: 72.r,
            decoration: BoxDecoration(
              color: enabled
                  ? const Color(0xff232323)
                  : const Color(0xff1a1a1a),
              shape: BoxShape.circle,
              border: Border.all(
                color: enabled
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.06),
                width: 1.5,
              ),
            ),
            child: Icon(
              Icons.vibration_rounded,
              color: enabled ? Colors.white70 : Colors.white24,
              size: 30.sp,
            ),
          ),
        ),
        SizedBox(height: 8.h),
        Text(
          cooldownLabel ?? 'Double tap',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: enabled ? Colors.white54 : Colors.white24,
            fontSize: 11.sp,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

// ── Push notification action button ────────────────────────────────────────

class _PushActionButton extends StatelessWidget {
  const _PushActionButton({
    required this.accent,
    required this.enabled,
    required this.onTap,
    this.cooldownLabel,
  });

  final Color accent;
  final bool enabled;
  final VoidCallback onTap;
  final String? cooldownLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: enabled ? onTap : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: 72.r,
            height: 72.r,
            decoration: BoxDecoration(
              color: enabled
                  ? const Color(0xff232323)
                  : const Color(0xff1a1a1a),
              shape: BoxShape.circle,
              border: Border.all(
                color: enabled
                    ? Colors.white.withValues(alpha: 0.18)
                    : Colors.white.withValues(alpha: 0.06),
                width: 1.5,
              ),
            ),
            child: Icon(
              Icons.notifications_none_rounded,
              color: enabled ? Colors.white70 : Colors.white24,
              size: 30.sp,
            ),
          ),
        ),
        SizedBox(height: 8.h),
        Text(
          cooldownLabel ?? 'Tap to poke',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: enabled ? Colors.white54 : Colors.white24,
            fontSize: 11.sp,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
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
      child: Center(child: Icon(icon, size: 15.sp, color: color)),
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
                      child: SizedBox(
                        width: 46.r,
                        height: 46.r,
                        child: avatar,
                      ),
                    ),
                  ),
                  if (deliveryBadge != null)
                    Positioned(
                      right: -6,
                      bottom: -6,
                      child: deliveryBadge!,
                    ),
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
// Shown only for: errors, step 1 ("Voice nudge sending…"), step 2
// ("Confirming if everyone received…"), and guard conditions (no friends /
// all already online). Steps 3 & 4 delivery results are shown as avatar badges.

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
