import 'package:one_one_app/one_one.dart';

Future<void> showNudgeBottomSheet(
  BuildContext context, {
  required GroupSummary group,
  required String currentUserId,
  required List<GroupMemberSummary> members,
  required Color accent,
  Set<String> onlineUserIds = const {},
  /// When true, LiveKit (or PTT) holds the hardware mic — voice recording
  /// must wait until the caller mutes. Re-checked on each press.
  bool Function()? isLiveMicrophoneInUse,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: false,
    backgroundColor: Colors.transparent,
    // Barrier/drag dismiss stay on; PopScope blocks them while holding to
    // record so a slip of the finger cannot close the sheet mid-nudge.
    isDismissible: true,
    enableDrag: true,
    builder: (_) => _QuickNudgeSheet(
      group: group,
      currentUserId: currentUserId,
      members: members,
      accent: accent,
      onlineUserIds: onlineUserIds,
      isLiveMicrophoneInUse: isLiveMicrophoneInUse,
    ),
  );
}

class _QuickNudgeSheet extends StatefulWidget {
  const _QuickNudgeSheet({
    required this.group,
    required this.currentUserId,
    required this.members,
    required this.accent,
    required this.onlineUserIds,
    this.isLiveMicrophoneInUse,
  });

  final GroupSummary group;
  final String currentUserId;
  final List<GroupMemberSummary> members;
  final Color accent;
  final Set<String> onlineUserIds;
  final bool Function()? isLiveMicrophoneInUse;

  @override
  State<_QuickNudgeSheet> createState() => _QuickNudgeSheetState();
}

class _QuickNudgeSheetState extends State<_QuickNudgeSheet> {
  static const _autoDismissDelay = Duration(seconds: 5);

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

  // Whether to show live delivery status text during the wait (voice/ring/push).
  bool _showConfirmingText = false;

  // Tracks what kind of nudge was last sent, used to decide which badges to show.
  NudgeKind? _lastSentNudgeKind;

  // Real-time delivery confirmation (nudge reliability checklist): once a
  // ring/voice nudge is accepted by the backend, the sheet stays open
  // awaiting the receiver's genuine playback outcome instead of closing
  // immediately — push nudges have no such confirmation and are unaffected.
  StreamSubscription<NudgeDeliveryResult>? _deliverySub;
  StreamSubscription<NudgeRecipientResponse>? _responseSub;
  StreamSubscription<List<NudgeDeliveryResult>>? _deliveryStatusSub;
  String? _awaitingEventId;

  /// Kept after delivery finalize so late decline/snooze replies still match.
  String? _lastEventId;

  // Voice-nudge timing diagnostics. [_voiceRequestId] is a local request id
  // minted at record-start; once the backend returns an event id it becomes
  // the correlation key (nudgeId) for the rest of the sender-side trace.
  String? _voiceRequestId;
  String? _voiceNudgeId;
  /// Signed-URL reservation kicked off at record-start so backend RTDB work
  /// overlaps the hold instead of blocking after record-end.
  Future<Map<String, dynamic>>? _voiceUploadReservation;
  final Stopwatch _voiceNudgeWatch = Stopwatch();
  bool _voiceConfirmationLogged = false;
  Timer? _deliveryTimeoutTimer;
  /// Wall-clock when the confirmation window for [_awaitingEventId] started.
  DateTime? _deliveryWaitStartedAt;
  final Map<String, _PendingRecipient> _expectedRecipients = {};
  final Map<String, NudgeDeliveryResult> _resultsByUserId = {};
  final Map<String, NudgeRecipientReply> _repliesByUserId = {};
  MediaVolumeFeedback _rtdbVolumeFeedback = MediaVolumeFeedback.none;

  /// Initial wait for delivery/ack status after send. Missing acks at this
  /// point trigger an RTDB get; still-missing enter a short grace buffer —
  /// they are NOT marked dead yet. Live RTDB listen + FCM update instantly.
  static const _deliveryStatusCheckTimeout = Duration(seconds: 4);
  /// Extra buffer after the status-check RTDB get before a conclusive
  /// timeout/dead state. Total confirmation window ≈ 7s (4s + 3s).
  static const _deliveryGracePeriod = Duration(seconds: 3);

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
              ? (signifier.failureReason ?? 'unknown')
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
          _messageIsWarning =
              last.status == LastNudgeStatus.volumeLow ||
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

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _recordingCapTimer?.cancel();
    _cooldownTicker?.cancel();
    _cancelDeliveryWaitTimers();
    _stopDeliveryStatusWatch();
    _autoDismissTimer?.cancel();
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

  List<_PendingRecipient> _acceptedRecipients(
    Object? response,
    List<_PendingRecipient> requested,
  ) {
    if (response is! Map || response['recipientUserIds'] is! List) {
      return requested;
    }
    final accepted = (response['recipientUserIds'] as List)
        .map((value) => value.toString())
        .toSet();
    return requested
        .where((recipient) => accepted.contains(recipient.userId))
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
    // Start the confirmation window and timer immediately — do NOT await
    // _loadVolumeFeedback first (that RTDB call can take up to 2s and was
    // delaying both the "Delivering…" text and the hard timeout start).
    _beginAwaitingDeliveryConfirmation(
      eventId,
      waitingMessage: waitingMessage,
      expected: expected,
    );
    // Load volume feedback concurrently; only needed for avatar badges which
    // appear after finalization, so latency here is not user-visible.
    final feedback = await _loadVolumeFeedback(expected);
    if (mounted && _awaitingEventId == eventId) {
      _rtdbVolumeFeedback = feedback;
    }
  }

  void _beginAwaitingDeliveryConfirmation(
    String? eventId, {
    required String waitingMessage,
    required List<_PendingRecipient> expected,
  }) {
    if (eventId == null || eventId.isEmpty) return;
    final sentAt = DateTime.now();
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Awaiting delivery confirmation eventId=$eventId '
          'sentAt=${sentAt.toIso8601String()} '
          'statusCheckMs=${_deliveryStatusCheckTimeout.inMilliseconds} '
          'graceMs=${_deliveryGracePeriod.inMilliseconds} '
          'totalWindowMs=${_deliveryStatusCheckTimeout.inMilliseconds + _deliveryGracePeriod.inMilliseconds} '
          'expected=[${expected.map((e) => '${e.displayName}:${e.userId}').join(', ')}]',
      groupId: widget.group.groupId,
    );
    _cancelDeliveryWaitTimers();
    _autoDismissTimer?.cancel();
    _deliveryWaitStartedAt = sentAt;
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
    _startDeliveryStatusWatch(eventId);
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
    // Phase 1: wait for acks. Do NOT mark anyone dead when this fires —
    // enter the grace buffer instead (see [_onDeliveryStatusCheckElapsed]).
    _deliveryTimeoutTimer = Timer(_deliveryStatusCheckTimeout, () {
      if (!mounted || _awaitingEventId != eventId) return;
      _onDeliveryStatusCheckElapsed(eventId);
    });
  }

  /// Called ~4s after send when some recipients may still be pending.
  /// Reconciles via RTDB immediately; only enters grace if still incomplete.
  void _onDeliveryStatusCheckElapsed(String eventId) {
    unawaited(_runDeliveryStatusCheck(eventId));
  }

  Future<void> _runDeliveryStatusCheck(String eventId) async {
    if (!mounted || _awaitingEventId != eventId) return;
    final pendingBefore = _pendingRecipientIds();
    final checkAt = DateTime.now();
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery status check eventId=$eventId '
          'checkAt=${checkAt.toIso8601String()} '
          'elapsedSinceSentMs=${_deliveryElapsedMs()} '
          'acked=[${_resultsByUserId.entries.map((e) => '${e.key}:${e.value.status}').join(', ')}] '
          'pending=[${pendingBefore.map((id) {
            final p = _expectedRecipients[id];
            return '${p?.displayName ?? '?'}:$id';
          }).join(', ')}]',
      groupId: widget.group.groupId,
    );

    if (pendingBefore.isEmpty) {
      _cancelDeliveryWaitTimers();
      _finalizeDeliverySummary(timedOut: false);
      return;
    }

    // Authoritative RTDB get — often lands ACKs whose FCM push is still in flight.
    await _reconcileFromRtdb(eventId, source: 'status_check');
    if (!mounted || _awaitingEventId != eventId) return;

    final pendingAfter = _pendingRecipientIds();
    if (pendingAfter.isEmpty) {
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'Delivery status check complete via RTDB eventId=$eventId '
            'elapsedSinceSentMs=${_deliveryElapsedMs()}',
        groupId: widget.group.groupId,
      );
      _cancelDeliveryWaitTimers();
      _finalizeDeliverySummary(timedOut: false);
      return;
    }

    // Phase 2: short grace — still pending, not dead yet.
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery grace period start eventId=$eventId '
          'graceAt=${DateTime.now().toIso8601String()} '
          'graceMs=${_deliveryGracePeriod.inMilliseconds} '
          'pending=[${pendingAfter.map((id) {
            final p = _expectedRecipients[id];
            return '${p?.displayName ?? '?'}:$id';
          }).join(', ')}]',
      groupId: widget.group.groupId,
    );
    _deliveryTimeoutTimer = Timer(_deliveryGracePeriod, () {
      if (!mounted || _awaitingEventId != eventId) return;
      unawaited(_onDeliveryGraceElapsed(eventId));
    });
  }

  /// End of confirmation window: one last RTDB get before any timeout/dead.
  Future<void> _onDeliveryGraceElapsed(String eventId) async {
    final timeoutAt = DateTime.now();
    LogManager.log(
      LogLevel.warn,
      'NudgeService',
      'Delivery confirmation window elapsed eventId=$eventId '
          'timeoutAt=${timeoutAt.toIso8601String()} '
          'elapsedSinceSentMs=${_deliveryElapsedMs()} '
          'stillPendingBeforeReconcile=[${_pendingRecipientIds().map((id) {
            final p = _expectedRecipients[id];
            return '${p?.displayName ?? '?'}:$id';
          }).join(', ')}]',
      groupId: widget.group.groupId,
    );

    await _reconcileFromRtdb(eventId, source: 'grace_timeout');
    if (!mounted || _awaitingEventId != eventId) return;

    final stillPending = _pendingRecipientIds();
    LogManager.log(
      stillPending.isEmpty ? LogLevel.info : LogLevel.warn,
      'NudgeService',
      'Delivery confirmation after RTDB reconcile eventId=$eventId '
          'elapsedSinceSentMs=${_deliveryElapsedMs()} '
          'stillPending=[${stillPending.map((id) {
            final p = _expectedRecipients[id];
            return '${p?.displayName ?? '?'}:$id';
          }).join(', ')}] '
          'acked=[${_resultsByUserId.entries.map((e) => '${e.key}:${e.value.status}').join(', ')}]',
      groupId: widget.group.groupId,
    );
    _finalizeDeliverySummary(timedOut: stillPending.isNotEmpty);
  }

  Future<void> _reconcileFromRtdb(
    String eventId, {
    required String source,
  }) async {
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery RTDB reconcile start eventId=$eventId source=$source '
          'elapsedSinceSentMs=${_deliveryElapsedMs()}',
      groupId: widget.group.groupId,
    );
    final results = await NudgeDeliveryStatusStore.instance.loadFromRtdb(
      senderUserId: widget.currentUserId,
      eventId: eventId,
    );
    for (final result in results) {
      _onDeliveryResult(result, source: 'rtdb_$source');
    }
  }

  void _startDeliveryStatusWatch(String eventId) {
    _stopDeliveryStatusWatch();
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery RTDB listen attach eventId=$eventId '
          'senderUserId=${widget.currentUserId} '
          'elapsedSinceSentMs=${_deliveryElapsedMs()}',
      groupId: widget.group.groupId,
    );
    _deliveryStatusSub = NudgeDeliveryStatusStore.instance
        .watch(
          senderUserId: widget.currentUserId,
          eventId: eventId,
        )
        .listen(
          (results) {
            for (final result in results) {
              _onDeliveryResult(result, source: 'rtdb');
            }
          },
          onError: (Object error) {
            LogManager.log(
              LogLevel.warn,
              'NudgeService',
              'Delivery RTDB watch error eventId=$eventId detail=$error',
              groupId: widget.group.groupId,
            );
          },
        );
  }

  void _stopDeliveryStatusWatch() {
    if (_deliveryStatusSub != null) {
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'Delivery RTDB listen detach eventId=${_lastEventId ?? _awaitingEventId}',
        groupId: widget.group.groupId,
      );
    }
    unawaited(_deliveryStatusSub?.cancel());
    _deliveryStatusSub = null;
  }

  List<String> _pendingRecipientIds() {
    if (_expectedRecipients.isEmpty) {
      return _resultsByUserId.isEmpty ? const ['unknown'] : const [];
    }
    return _expectedRecipients.keys
        .where((id) => !_resultsByUserId.containsKey(id))
        .toList(growable: false);
  }

  int _deliveryElapsedMs() {
    final started = _deliveryWaitStartedAt;
    if (started == null) return -1;
    return DateTime.now().difference(started).inMilliseconds;
  }

  void _onDeliveryResult(
    NudgeDeliveryResult result, {
    String source = 'fcm',
  }) {
    if (!mounted) return;
    final awaiting = _awaitingEventId;
    final lastId = _lastEventId;
    final isActiveWait = awaiting != null && result.eventId == awaiting;
    final isLateForLast =
        !isActiveWait && lastId != null && result.eventId == lastId;
    if (!isActiveWait && !isLateForLast) {
      LogManager.log(
        LogLevel.warn,
        'NudgeService',
        'Delivery result ignored: eventId mismatch result=${result.eventId} '
            'awaiting=$awaiting last=$lastId status=${result.status} '
            'source=$source elapsedSinceSentMs=${_deliveryElapsedMs()}',
        groupId: widget.group.groupId,
      );
      return;
    }

    final ackAt = DateTime.now();
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery result matched eventId=${result.eventId} status=${result.status} '
          'source=$source late=$isLateForLast '
          'ackAt=${ackAt.toIso8601String()} '
          'elapsedSinceSentMs=${_deliveryElapsedMs()} '
          'reason=${result.reason ?? '-'} attention=${result.attention ?? '-'} '
          'recipientUserId=${result.recipientUserId ?? '-'} '
          'recipientName=${result.recipientName ?? '-'}',
      groupId: widget.group.groupId,
    );
    if (result.played && result.attention != null) {
      LogManager.log(
        LogLevel.warn,
        'NudgeService',
        'NUDGE_SILENT_PLAYBACK nudgeId=${result.eventId} '
            'attention=${result.attention} '
            'recipientUserId=${result.recipientUserId ?? '-'} '
            'recipientName=${result.recipientName ?? '-'}',
        groupId: widget.group.groupId,
      );
    }
    if (result.played && _voiceNudgeId == result.eventId) {
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'VOICE_NUDGE_PLAYBACK_STARTED nudgeId=${result.eventId} '
            'recipientUserId=${result.recipientUserId ?? '-'} '
            'recipientName=${result.recipientName ?? '-'} '
            'attention=${result.attention ?? '-'} '
            'elapsedSinceRecordEndMs=${_voiceNudgeWatch.elapsedMilliseconds} '
            'elapsedSinceSentMs=${_deliveryElapsedMs()}',
        groupId: widget.group.groupId,
      );
    }

    final matchedId = _matchDeliveryRecipientId(result);
    final existing = _resultsByUserId[matchedId];
    // Never let a timeout/failed overwrite a real played ACK (stale timer /
    // duplicate reconcile), and skip no-op re-applies from RTDB watches.
    if (existing != null && existing.played && !result.played) {
      return;
    }
    if (existing != null &&
        existing.status == result.status &&
        existing.attention == result.attention &&
        existing.reason == result.reason) {
      if (isLateForLast) return;
      // Active wait: still check whether everyone is done (e.g. RTDB replay).
    } else {
      _resultsByUserId[matchedId] = result;
    }

    if (isLateForLast) {
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'Delivery late reconcile eventId=${result.eventId} source=$source '
            'recipientUserId=$matchedId status=${result.status} '
            'clearsPriorFailure=${existing != null && !existing.played && result.played} '
            'elapsedSinceSentMs=${_deliveryElapsedMs()}',
        groupId: widget.group.groupId,
      );
      _refreshFinalDeliveryUiFromResults();
      return;
    }

    _refreshInProgressDeliveryUi();

    final expectedCount = _expectedRecipients.isEmpty
        ? 1
        : _expectedRecipients.length;
    final resolvedExpected = _expectedRecipients.isEmpty
        ? _resultsByUserId.length
        : _expectedRecipients.keys
            .where((id) => _resultsByUserId.containsKey(id))
            .length;
    if (resolvedExpected >= expectedCount) {
      _cancelDeliveryWaitTimers();
      _finalizeDeliverySummary(timedOut: false);
    } else {
      setState(() {});
    }
  }

  String _matchDeliveryRecipientId(NudgeDeliveryResult result) {
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
    return matchedId;
  }

  /// Rebuild badges/message after a late ACK clears a premature timeout skull.
  void _refreshFinalDeliveryUiFromResults() {
    final summaryMessage = _buildDeliveryMessage(partial: false);
    final signifiers = _snapshotSignifiers();
    final failed = _resultsByUserId.values.where((r) => !r.played).toList();
    final volumeWarnings = _mergedVolumeWarnings();
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'Delivery UI refresh after late/RTDB update '
          'eventId=$_lastEventId failed=${failed.length} '
          'results=[${_resultsByUserId.entries.map((e) => '${e.key}:${e.value.status}').join(', ')}] '
          'elapsedSinceSentMs=${_deliveryElapsedMs()}',
      groupId: widget.group.groupId,
    );
    final anyDeclined = _repliesByUserId.values.any(
      (r) => r == NudgeRecipientReply.declined,
    );
    final anySnoozed = _repliesByUserId.values.any(
      (r) => r == NudgeRecipientReply.snoozed,
    );

    if (failed.isEmpty) {
      NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
    }

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

    setState(() {
      _showDeliveryBadges = true;
      _messagePending = false;
      _message = summaryMessage;
      _messageIsError = failed.isNotEmpty;
      _messageIsWarning = failed.isEmpty && volumeWarnings.isNotEmpty;
    });
  }

  void _refreshInProgressDeliveryUi() {
    if (_awaitingEventId == null || !_showConfirmingText) return;
    _message = _buildInProgressDeliveryMessage();
    _messageIsError = false;
    _messageIsWarning = false;
    _messagePending = true;
  }

  String _deliveryResultFirstName(NudgeDeliveryResult result) {
    final full = result.recipientName?.trim();
    if (full != null && full.isNotEmpty) {
      return full.split(RegExp(r'\s+')).first;
    }
    final userId = result.recipientUserId;
    if (userId != null) {
      final pending = _expectedRecipients[userId];
      if (pending != null) {
        return pending.displayName.trim().split(RegExp(r'\s+')).first;
      }
    }
    return 'Someone';
  }

  /// Live status line while awaiting acks — updates the moment playback starts
  /// on a receiver, before the final per-person summary replaces it.
  String _buildInProgressDeliveryMessage() {
    final results = _resultsByUserId.values.toList(growable: false);
    final played = results.where((r) => r.played).toList(growable: false);

    if (played.isNotEmpty) {
      final names = played.map(_deliveryResultFirstName).toList(growable: false);
      if (_lastSentNudgeKind == NudgeKind.voice) {
        if (names.length == 1) {
          return 'Started playing on ${names.first}\'s device\u2026';
        }
        return 'Started playing for ${_joinNames(names)}\u2026';
      }
      if (names.length == 1) {
        return '${names.first} received it\u2026';
      }
      return '${_joinNames(names)} received it\u2026';
    }

    return switch (_lastSentNudgeKind) {
      NudgeKind.voice => 'Delivering voice nudge\u2026',
      NudgeKind.ring => 'Delivering ring nudge\u2026',
      NudgeKind.push => 'Delivering nudge\u2026',
      null => 'Confirming if they received\u2026',
    };
  }

  void _cancelDeliveryWaitTimers() {
    _deliveryTimeoutTimer?.cancel();
    _deliveryTimeoutTimer = null;
  }

  void _onRecipientResponse(NudgeRecipientResponse response) {
    if (!mounted) return;
    if (response.groupId != widget.group.groupId) return;
    final lastId = _lastEventId ?? _awaitingEventId;
    if (lastId != null &&
        lastId.isNotEmpty &&
        response.eventId != lastId &&
        response.isAccept) {
      return;
    }

    // Cancel sender 10-min expiry on any terminal reply (accept/decline/snooze).
    unawaited(
      AndroidVoiceNudgeBridge.shared.cancelSenderNudgeExpiry(response.eventId),
    );

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
    // Claim this wait cycle immediately so a racing status-check/grace timer
    // cannot re-enter and overwrite a successful ack with synthesized failures.
    final eventId = _awaitingEventId;
    if (eventId == null) return;
    _awaitingEventId = null;
    _cancelDeliveryWaitTimers();

    final elapsedMs = _deliveryElapsedMs();
    if (_voiceNudgeId != null && !_voiceConfirmationLogged) {
      _voiceConfirmationLogged = true;
      _voiceNudgeWatch.stop();
      final totalMs = _voiceNudgeWatch.elapsedMilliseconds;
      if (timedOut) {
        LogManager.log(
          LogLevel.warn,
          'NudgeService',
          'VOICE_NUDGE_CONFIRMATION_TIMEOUT nudgeId=$_voiceNudgeId '
              'totalMs=$totalMs elapsedSinceSentMs=$elapsedMs',
          groupId: widget.group.groupId,
        );
      } else {
        LogManager.log(
          LogLevel.info,
          'NudgeService',
          'VOICE_NUDGE_CONFIRMATION_RECEIVED nudgeId=$_voiceNudgeId '
              'VOICE_NUDGE_TOTAL_TIME nudgeId=$_voiceNudgeId totalMs=$totalMs '
              'elapsedSinceSentMs=$elapsedMs',
          groupId: widget.group.groupId,
        );
      }
    }
    LogManager.log(
      timedOut ? LogLevel.warn : LogLevel.info,
      'NudgeService',
      'Finalizing delivery summary timedOut=$timedOut '
          'eventId=$eventId '
          'finalizeAt=${DateTime.now().toIso8601String()} '
          'elapsedSinceSentMs=$elapsedMs '
          'results=[${_resultsByUserId.entries.map((e) => '${e.key}:${e.value.status}').join(', ')}] '
          'expected=[${_expectedRecipients.keys.join(', ')}]',
      groupId: widget.group.groupId,
    );
    final expected = _expectedRecipients.values.toList(growable: false);
    // Synthesize timeout failures only after the full confirmation window
    // (status check + grace). Recipients are evaluated independently — only
    // those still missing a result become conclusive failures.
    for (final pending in expected) {
      if (!_resultsByUserId.containsKey(pending.userId)) {
        LogManager.log(
          LogLevel.warn,
          'NudgeService',
          'No delivery result for ${pending.displayName} (${pending.userId}); '
              'synthesizing failed/${timedOut ? 'timeout' : 'unknown'} '
              'elapsedSinceSentMs=$elapsedMs',
          groupId: widget.group.groupId,
        );
        _resultsByUserId[pending.userId] = NudgeDeliveryResult(
          eventId: eventId,
          status: 'failed',
          reason: timedOut ? 'timeout' : 'unknown',
          recipientUserId: pending.userId,
          recipientName: pending.displayName,
        );
      }
    }

    _deliveryWaitStartedAt = null;

    // Persist failure summaries so they can be shown on sheet reopen.
    final failed = <NudgeDeliveryResult>[];
    final failedNames = <String>[];
    final failedReasons = <String?>[];
    for (final entry in _resultsByUserId.entries) {
      final result = entry.value;
      final name =
          result.recipientName ??
          _expectedRecipients[entry.key]?.displayName ??
          'them';
      if (!result.played) {
        failed.add(result);
        failedNames.add(name.trim().split(RegExp(r'\s+')).first);
        failedReasons.add(result.reason);
      }
    }
    final volumeWarnings = _mergedVolumeWarnings();
    final totalRecipients = _resultsByUserId.length;
    if (failed.isEmpty) {
      NudgeFailureMemory.instance.clearGroup(widget.group.groupId);
    } else {
      final persistMsg = _persistedFailureMessage(
        failed.length,
        totalRecipients,
        failedNames,
        reasons: failedReasons,
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
      if (failed.length == 1) {
        return _shortFailureWithReason(
          nameOf(failed.first),
          failed.first.reason,
        );
      }
      // Prefer per-person lines when there are only a couple of failures so
      // the sender sees exactly who did not receive the nudge.
      if (failed.length <= 2) {
        return failed
            .map((f) => _shortFailureWithReason(nameOf(f), f.reason))
            .join('\n');
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
      return 'Played on ${name.trim().split(RegExp(r'\s+')).first}\u2019s device';
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
      case 'playback_error':
      case 'download_failed':
        return 'Nudge did not reach $name \u2014 something went wrong on '
            'Duo\u2019s end.';
      default:
        return 'Nudge did not reach $name.';
    }
  }

  String _persistedFailureMessage(
    int failedCount,
    int totalRecipients,
    List<String> failedNames, {
    List<String?> reasons = const [],
  }) {
    if (failedCount == 1 && failedNames.isNotEmpty) {
      return _shortFailureWithReason(
        failedNames.first,
        reasons.isNotEmpty ? reasons.first : null,
      );
    }
    if (failedCount <= 2 &&
        failedNames.length == failedCount &&
        reasons.length == failedCount) {
      return [
        for (var i = 0; i < failedCount; i++)
          _shortFailureWithReason(failedNames[i], reasons[i]),
      ].join('\n');
    }
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
    // snapshots signifiers before flipping that flag so reopen restores the
    // same per-recipient failure state.
    final signifiers = <LastNudgeRecipientSignifier>[];
    for (final pending in _expectedRecipients.values) {
      final result = _resultsByUserId[pending.userId];
      final failed = result?.played == false;
      signifiers.add(
        LastNudgeRecipientSignifier(
          userId: pending.userId,
          displayName: pending.displayName,
          failed: failed,
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

  /// Hardware mic is held by the live session — voice nudge cannot record.
  bool get _liveMicBlocksVoice =>
      widget.isLiveMicrophoneInUse?.call() ?? false;

  /// Block sheet dismiss (back, barrier, drag) for the whole press-and-hold.
  bool get _blockDismissWhileHolding =>
      _pointerHeld || _recording || _startingRecording;

  void _scheduleAutoDismiss() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = Timer(_autoDismissDelay, () {
      if (!mounted) return;
      if (_pointerHeld ||
          _recording ||
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

  /// Each tap adds one three-second phrase, capped at three consecutive rings.
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
      waitingMessage: 'Delivering ring nudge\u2026',
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
      waitingMessage: 'Delivering ring nudge\u2026',
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

  /// Requests microphone permission so a later background auto-connect can
  /// start the LiveKit session without showing a foreground dialog. No-op if
  /// it is already granted or the platform cannot request it right now.
  Future<void> _ensureMicrophonePermission() async {
    try {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        LogManager.log(
          LogLevel.warn,
          'NudgeService',
          'Microphone permission not granted at send time; background '
              'auto-connect may require reopening the app',
          groupId: widget.group.groupId,
        );
      }
    } catch (_) {
      // Best-effort — the normal go-online path still re-checks permission.
    }
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
    // Best-effort: make sure the microphone permission is granted while the
    // sender is still in the foreground. If the app is backgrounded and the
    // receiver later accepts, the LiveKit session can auto-connect in the
    // background without a foreground permission dialog.
    unawaited(_ensureMicrophonePermission());
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
      final acceptedExpected = _acceptedRecipients(result, expected);
      setState(() => _busy = false);
      if (awaitsDeliveryConfirmation && result is Map) {
        final eventId = result['notificationEventId']?.toString();
        if (eventId != null && eventId.isNotEmpty) {
          _scheduleSenderExpiry(eventId, acceptedExpected);
          await _prepareDeliveryWait(
            eventId: eventId,
            expected: acceptedExpected,
            waitingMessage: waitingMessage,
          );
          return;
        }
      }
      if (!awaitsDeliveryConfirmation && result is Map) {
        final eventId = result['notificationEventId']?.toString();
        if (eventId != null && eventId.isNotEmpty) {
          _lastEventId = eventId;
          _scheduleSenderExpiry(eventId, acceptedExpected);
        }
      }
      // Check aggregate send/failed counts before claiming success.
      if (!awaitsDeliveryConfirmation && result is Map<String, dynamic>) {
        final nudgeResult = NudgeResult.fromSendResponse(
          result,
          acceptedExpected.map((e) => e.userId).toList(growable: false),
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
          ..addEntries(acceptedExpected.map((e) => MapEntry(e.userId, e)));
        final signifiers = [
          for (final pending in acceptedExpected)
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
        await _showImmediateSendOutcome(acceptedExpected);
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
    if (_liveMicBlocksVoice) {
      if (mounted) {
        setState(() {
          _message = 'Mute your mic first to send a voice nudge.';
          _messageIsError = false;
          _messageIsWarning = true;
          _messagePending = false;
        });
      }
      return;
    }
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
        _voiceUploadReservation = null;
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
      _voiceRequestId = const Uuid().v4();
      _voiceNudgeId = null;
      _voiceConfirmationLogged = false;
      // Reserve the signed write URL while the user holds — the backend
      // recipient lookup (~4s on groups) finishes before record-end.
      _voiceUploadReservation = _repository.initiateVoiceUpload(
        groupId: widget.group.groupId,
        target: _effectiveTarget(),
        durationMs: VoiceNudgeAudio.maxRecordingDuration.inMilliseconds,
      );
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'VOICE_NUDGE_RECORD_START nudgeId=$_voiceRequestId '
            'encoder=aacLc bitRate=${VoiceNudgeAudio.bitRate} '
            'sampleRate=${VoiceNudgeAudio.sampleRate} '
            'channels=${VoiceNudgeAudio.numChannels} '
            'capMs=${VoiceNudgeAudio.maxRecordingDuration.inMilliseconds} '
            'uploadReserveAtStart=true',
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
      _voiceUploadReservation = null;
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
    // Recording feedback stays on a fixed default — Settings haptics only
    // apply to incoming voice-nudge playback.
    unawaited(HapticFeedback.selectionClick());
    final actualDurationMs = _recordingWatch.elapsedMilliseconds;
    final durationMs = actualDurationMs.clamp(
      0,
      VoiceNudgeAudio.maxAcceptedDurationMs,
    );
    // Start the end-to-end clock at record-end: everything below (flush,
    // upload, dispatch, receiver download/decode/playback, confirmation) must
    // fit within the target window.
    _voiceNudgeWatch
      ..reset()
      ..start();
    LogManager.log(
      LogLevel.info,
      'NudgeService',
      'VOICE_NUDGE_RECORD_END nudgeId=${_voiceRequestId ?? '-'} '
          'durationMs=$actualDurationMs send=$send '
          'capMs=${VoiceNudgeAudio.maxRecordingDuration.inMilliseconds}',
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
    final uploadReservation =
        send && durationMs >= minMs ? _voiceUploadReservation : null;
    _voiceUploadReservation = null;
    try {
      // AAC-LC encoding happens inside the recorder while recording; the
      // stop() call only flushes/finalizes the M4A container. This is the
      // single measurable "compression" step on the sender.
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'VOICE_NUDGE_COMPRESSION_START nudgeId=${_voiceRequestId ?? '-'}',
        groupId: widget.group.groupId,
      );
      final stopWatch = Stopwatch()..start();
      path = await _recorder.stop();
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'VOICE_NUDGE_COMPRESSION_END nudgeId=${_voiceRequestId ?? '-'} '
            'elapsedMs=${stopWatch.elapsedMilliseconds} path=${path != null}',
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
      // Overlap reading the M4A off disk with the upload-url reservation that
      // was kicked off at record-start — avoids serializing on slow paths.
      Uint8List audio;
      Map<String, dynamic>? initiatedUpload;
      try {
        if (uploadReservation != null) {
          final parallel = await Future.wait<Object?>([
            file.readAsBytes(),
            uploadReservation,
          ]);
          audio = parallel.first as Uint8List;
          if (parallel.length > 1 && parallel[1] is Map) {
            initiatedUpload = parallel[1] as Map<String, dynamic>;
          }
        } else {
          audio = await file.readAsBytes();
        }
      } catch (_) {
        audio = await file.readAsBytes();
        initiatedUpload = null;
      }
      final response = await _repository.sendVoice(
        groupId: widget.group.groupId,
        target: _effectiveTarget(),
        audio: audio,
        durationMs: durationMs,
        initiatedUpload: initiatedUpload,
      );
      _cooldowns.record(NudgeKind.voice);
      sent = true;
      voiceEventId = response['notificationEventId']?.toString();
      _voiceNudgeId = voiceEventId;
      LogManager.log(
        LogLevel.info,
        'NudgeService',
        'VOICE_NUDGE_SEND_ACK nudgeId=${voiceEventId ?? '-'} '
            'clientRequestId=${_voiceRequestId ?? '-'} '
            'elapsedSinceRecordEndMs=${_voiceNudgeWatch.elapsedMilliseconds}',
        groupId: widget.group.groupId,
      );
      _expectedRecipients
        ..clear()
        ..addEntries(
          _acceptedRecipients(
            response,
            _recipientsForTarget(),
          ).map((recipient) => MapEntry(recipient.userId, recipient)),
        );
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
          // Voice nudge: delivering → started playing → confirmed summary.
          _lastSentNudgeKind = NudgeKind.voice;
          _showConfirmingText = true;
          await _prepareDeliveryWait(
            eventId: voiceEventId,
            expected: _expectedRecipients.values.toList(growable: false),
            waitingMessage: 'Delivering voice nudge\u2026',
          );
        } else if (sent) {
          await _showImmediateSendOutcome(
            _expectedRecipients.values.toList(growable: false),
          );
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
    final voiceBlockedByLiveMic = _liveMicBlocksVoice;
    final voiceEnabled =
        _canSend && voiceCooldown <= Duration.zero && !voiceBlockedByLiveMic;
    final recordingProgress =
        (_elapsed.inMilliseconds /
                VoiceNudgeAudio.maxRecordingDuration.inMilliseconds)
            .clamp(0.0, 1.0);
    final accent = widget.accent;

    // Errors, confirming, received/failed confirmation, and empty-group guards.
    final showStatus =
        _friends.isEmpty || _nudgeableFriends.isEmpty || _message != null;

    return PopScope(
      canPop: !_blockDismissWhileHolding,
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
                maxHeight: MediaQuery.sizeOf(context).height * 0.68,
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── Drag handle ──
                    Center(
                      child: Padding(
                        padding: EdgeInsets.only(top: 8.h, bottom: 8.h),
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
                            child: Text(
                              'Get their attention',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18.sp,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _blockDismissWhileHolding
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

                    SizedBox(height: 10.h),

                    // ── Recipient picker (selection is self-explanatory) ──
                    SizedBox(
                      height: 92.h,
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
                            SizedBox(width: 12.w),
                            Builder(
                              builder: (context) {
                                final online = _isOnline(friend.userId);
                                final failed = _isDeliveryFailed(friend.userId);
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
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ],
                      ),
                    ),

                    SizedBox(height: 12.h),
                    _SheetDivider(),
                    SizedBox(height: 18.h),

                    // ── Primary action: hold-to-speak (centered lower sheet) ──
                    Center(
                      child: _buildVoiceMicButton(
                        accent: accent,
                        voiceEnabled: voiceEnabled,
                        recordingProgress: recordingProgress,
                        voiceCooldown: voiceCooldown,
                      ),
                    ),

                    SizedBox(height: 18.h),

                    // ── Secondary actions: ring + push ──
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24.w),
                      child: Text(
                        'More ways to get their attention',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                        ),
                      ),
                    ),
                    SizedBox(height: 12.h),
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
                            onRingCount: (count) => unawaited(
                              _sendRing(durationSeconds: count * 3),
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

                    if (showStatus) ...[
                      SizedBox(height: 14.h),
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

                    SizedBox(height: 18.h),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds a friend's avatar with an optional skull overlay when the nudge
  /// was not received.
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

    // Grayscale + skull for "nudge not received" states.
    final overlay = Text(
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
    final muteFirstLabel = _liveMicBlocksVoice && !_recording && !_sendingVoice;
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
              : muteFirstLabel
              ? 'Mute your microphone first to record a voice nudge'
              : 'Voice nudge, press and hold to record',
          child: Listener(
            onPointerDown: (_) {
              if (!voiceEnabled) {
                if (_liveMicBlocksVoice) {
                  setState(() {
                    _message = 'Mute your mic first to send a voice nudge.';
                    _messageIsError = false;
                    _messageIsWarning = true;
                    _messagePending = false;
                  });
                }
                return;
              }
              // Fixed default while holding to record (not Settings intensity).
              unawaited(HapticFeedback.lightImpact());
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
                          muteFirstLabel
                              ? Icons.mic_off_rounded
                              : _recording
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
              : muteFirstLabel
              ? 'Mute first'
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
              offset: Offset(0, -3.r * sin(t * 2 * pi)),
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
// Up to three rapid taps are coalesced into one consecutive ring request.

class _RingActionButton extends StatefulWidget {
  const _RingActionButton({
    required this.enabled,
    required this.onRingCount,
    this.cooldownLabel,
  });

  final bool enabled;
  final ValueChanged<int> onRingCount;
  final String? cooldownLabel;

  @override
  State<_RingActionButton> createState() => _RingActionButtonState();
}

class _RingActionButtonState extends State<_RingActionButton> {
  Timer? _dispatchTimer;
  int _tapCount = 0;

  void _queueRing() {
    if (!widget.enabled || _tapCount >= 3) return;
    setState(() => _tapCount++);
    _dispatchTimer?.cancel();
    _dispatchTimer = Timer(const Duration(milliseconds: 350), () {
      final count = _tapCount;
      if (!mounted || count == 0) return;
      setState(() => _tapCount = 0);
      widget.onRingCount(count);
    });
  }

  @override
  void dispose() {
    _dispatchTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: 'Ring their phone',
      child: GestureDetector(
        onTap: widget.enabled ? _queueRing : null,
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
                  color: widget.enabled ? Colors.white70 : Colors.white24,
                  size: 28.sp,
                ),
              ),
              SizedBox(height: 4.h),
              Text(
                widget.cooldownLabel ??
                    (_tapCount > 1 ? 'Ring ×$_tapCount' : 'Ring'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: widget.enabled ? Colors.white54 : Colors.white24,
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
//   Declined → Icons.dark_mode_rounded (filled moon — can't join right now)
//   Snoozed  → LucideIcons.timer  (⏳ — ask me later)

class _ResponseBadgeIcon extends StatelessWidget {
  const _ResponseBadgeIcon({required this.reply});

  final NudgeRecipientReply reply;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (reply) {
      NudgeRecipientReply.declined => (Icons.dark_mode_rounded, Colors.white70),
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
// skull / volume on top of this.

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
