/// Receiver media-volume self-report.
///
/// Android cannot read another device's media volume — that state is local
/// to each handset. Receivers therefore write their own STREAM_MUSIC level to
/// RTDB (`mediaVolume/{groupId}/{userId}`) so a sender can warn after a nudge.
/// Never treat a remote volume query as possible.
library;

const mediaVolumeFreshness = Duration(minutes: 5);

enum MediaVolumeBand { muted, veryLow, low, ok }

extension MediaVolumeBandX on MediaVolumeBand {
  bool get isWarning => this != MediaVolumeBand.ok;

  /// Sender-facing copy from the volume-state spec. [name] is a first name.
  String? warningMessage(String name) {
    final who = name.trim().isEmpty ? 'They' : name.trim();
    return switch (this) {
      MediaVolumeBand.muted => '⚠️ $who is muted',
      MediaVolumeBand.veryLow => '⚠️ $who\'s volume is very low (<25%)',
      MediaVolumeBand.low => '⚠️ $who\'s volume is low (<50%)',
      MediaVolumeBand.ok => null,
    };
  }

  static MediaVolumeBand fromPercent(int volumeLevel) {
    if (volumeLevel <= 0) return MediaVolumeBand.muted;
    if (volumeLevel < 25) return MediaVolumeBand.veryLow;
    if (volumeLevel < 50) return MediaVolumeBand.low;
    return MediaVolumeBand.ok;
  }

  /// Maps a playback `attention` flag (live at play time) onto the same bands.
  static MediaVolumeBand? fromAttention(String? attention) {
    return switch (attention) {
      'volume_muted' => MediaVolumeBand.muted,
      'volume_very_low' => MediaVolumeBand.veryLow,
      'volume_low' => MediaVolumeBand.low,
      _ => null,
    };
  }
}

class MediaVolumeRecipient {
  const MediaVolumeRecipient({required this.userId, required this.displayName});

  final String userId;
  final String displayName;
}

class MediaVolumeReading {
  const MediaVolumeReading({
    required this.userId,
    required this.groupId,
    required this.volumeLevel,
    required this.timestamp,
  });

  final String userId;
  final String groupId;

  /// 0–100 percent of STREAM_MUSIC max. `0` includes hardware mute.
  final int volumeLevel;
  final DateTime timestamp;

  MediaVolumeBand get band => MediaVolumeBandX.fromPercent(volumeLevel);

  bool isFresh(DateTime now, {Duration maxAge = mediaVolumeFreshness}) {
    final age = now.difference(timestamp);
    if (age.isNegative) {
      // Small clock skew still counts as fresh; a wild future stamp does not.
      return age.abs() <= const Duration(minutes: 1);
    }
    return age <= maxAge;
  }

  static MediaVolumeReading? tryParse({
    required String userId,
    required String groupId,
    required Object? raw,
  }) {
    if (raw is! Map) return null;
    final data = raw.map((key, value) => MapEntry(key.toString(), value));
    final level = _readInt(data['volumeLevel']);
    final timestamp = _readTimestamp(data['timestamp']);
    if (level == null || timestamp == null) return null;
    return MediaVolumeReading(
      userId: data['userId']?.toString().trim().isNotEmpty == true
          ? data['userId'].toString().trim()
          : userId,
      groupId: data['groupId']?.toString().trim().isNotEmpty == true
          ? data['groupId'].toString().trim()
          : groupId,
      volumeLevel: level.clamp(0, 100),
      timestamp: timestamp,
    );
  }

  /// Parses `mediaVolume/{groupId}` — a map of userId → reading.
  static List<MediaVolumeReading> parseGroup({
    required String groupId,
    required Object? raw,
  }) {
    if (raw is! Map) return const [];
    final readings = <MediaVolumeReading>[];
    raw.forEach((key, value) {
      final userId = key.toString();
      if (userId.isEmpty) return;
      final parsed = tryParse(userId: userId, groupId: groupId, raw: value);
      if (parsed != null) readings.add(parsed);
    });
    return readings;
  }
}

class MediaVolumeFeedback {
  const MediaVolumeFeedback({
    required this.warnings,
    required this.bandsByUserId,
  });

  static const none = MediaVolumeFeedback(warnings: [], bandsByUserId: {});

  /// Per-recipient warning lines, already formatted. Empty means no fresh
  /// warning-level reading — stale/missing states are omitted, not treated
  /// as OK and not shown as unknown.
  final List<String> warnings;
  final Map<String, MediaVolumeBand> bandsByUserId;

  bool get hasWarnings => warnings.isNotEmpty;

  String get joinedWarnings => warnings.join('\n');

  String? warningFor(String userId, String displayName) {
    final band = bandsByUserId[userId];
    if (band == null || !band.isWarning) return null;
    return band.warningMessage(mediaVolumeFirstName(displayName));
  }

  factory MediaVolumeFeedback.fromReadings({
    required Iterable<MediaVolumeReading> readings,
    required List<MediaVolumeRecipient> recipients,
    required DateTime now,
  }) {
    final byId = <String, MediaVolumeReading>{
      for (final reading in readings) reading.userId: reading,
    };
    final warnings = <String>[];
    final bands = <String, MediaVolumeBand>{};
    for (final recipient in recipients) {
      final reading = byId[recipient.userId];
      if (reading == null || !reading.isFresh(now)) continue;
      final band = reading.band;
      bands[recipient.userId] = band;
      final warning = band.warningMessage(
        mediaVolumeFirstName(recipient.displayName),
      );
      if (warning != null) warnings.add(warning);
    }
    return MediaVolumeFeedback(warnings: warnings, bandsByUserId: bands);
  }

  static String successMessage({
    required int recipientCount,
    String? singleFirstName,
  }) {
    final name = singleFirstName?.trim();
    if (recipientCount == 1 && name != null && name.isNotEmpty) {
      return 'Nudge sent to $name \u2713';
    }
    return 'Everyone received the nudge \u2713';
  }
}

String mediaVolumeFirstName(String displayName) {
  final trimmed = displayName.trim();
  if (trimmed.isEmpty) return 'They';
  return trimmed.split(RegExp(r'\s+')).first;
}

int? _readInt(Object? raw) {
  return switch (raw) {
    int value => value,
    num value => value.toInt(),
    String value => int.tryParse(value.trim()),
    _ => null,
  };
}

DateTime? _readTimestamp(Object? raw) {
  final value = _readInt(raw);
  if (value == null || value <= 0) return null;
  // Seconds vs milliseconds: 1e12 ms ≈ 2001-09-09.
  if (value >= 1000000000000) {
    return DateTime.fromMillisecondsSinceEpoch(value);
  }
  return DateTime.fromMillisecondsSinceEpoch(value * 1000);
}
