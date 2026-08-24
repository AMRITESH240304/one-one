import 'package:one_one_app/one_one.dart';

/// RTDB access for receiver-reported media volume.
///
/// Writes are one-shot (foreground + FCM receive), never a stream. Reads are
/// a single `mediaVolume/{groupId}` get after the sender's nudge is accepted.
class MediaVolumeStore {
  MediaVolumeStore({
    FirebaseDatabase? database,
    DateTime Function()? clock,
    Future<int?> Function()? readLocalPercent,
  }) : _database = database ?? AppDatabase.instance(),
       _clock = clock ?? DateTime.now,
       _readLocalPercent =
           readLocalPercent ??
           AndroidVoiceNudgeBridge.shared.getMediaVolumePercent;

  static final MediaVolumeStore instance = MediaVolumeStore();

  final FirebaseDatabase _database;
  final DateTime Function() _clock;
  final Future<int?> Function() _readLocalPercent;

  DateTime? _lastReportAt;
  int? _lastPercent;
  String? _lastSignature;

  /// Receiver: write this device's STREAM_MUSIC percent for each group.
  Future<void> reportForGroups({
    required String userId,
    required Iterable<String> groupIds,
  }) async {
    if (userId.isEmpty) return;
    final uniqueGroupIds = groupIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    if (uniqueGroupIds.isEmpty) return;

    final percent = await _readLocalPercent();
    if (percent == null) return;

    final signature = '$userId|${uniqueGroupIds.join(',')}';
    final now = _clock();
    if (_lastPercent == percent &&
        _lastSignature == signature &&
        _lastReportAt != null &&
        now.difference(_lastReportAt!) < const Duration(seconds: 15)) {
      return;
    }

    final payload = <String, Object>{
      'userId': userId,
      'volumeLevel': percent.clamp(0, 100),
      'timestamp': now.millisecondsSinceEpoch,
    };
    final updates = <String, Object>{
      for (final groupId in uniqueGroupIds)
        'mediaVolume/$groupId/$userId': {...payload, 'groupId': groupId},
    };
    try {
      await _database.ref().update(updates);
      _lastReportAt = now;
      _lastPercent = percent;
      _lastSignature = signature;
    } catch (_) {
      // Best-effort — a missed write just means the next sender sees stale
      // / missing and will not invent a volume warning.
    }
  }

  /// Sender: fetch reported volume for [recipients] in [groupId].
  Future<MediaVolumeFeedback> feedbackFor({
    required String groupId,
    required List<MediaVolumeRecipient> recipients,
  }) async {
    if (groupId.isEmpty || recipients.isEmpty) return MediaVolumeFeedback.none;
    try {
      final snapshot = await _database.ref('mediaVolume/$groupId').get();
      final readings = MediaVolumeReading.parseGroup(
        groupId: groupId,
        raw: snapshot.value,
      );
      return MediaVolumeFeedback.fromReadings(
        readings: readings,
        recipients: recipients,
        now: _clock(),
      );
    } catch (_) {
      return MediaVolumeFeedback.none;
    }
  }
}
