import 'package:one_one_app/one_one.dart';

class LogMetadata {
  const LogMetadata({
    required this.userId,
    required this.groupId,
    required this.networkType,
    required this.networkStrength,
    required this.deviceModel,
    required this.androidVersion,
    required this.appVersion,
  });

  final String userId;
  final String groupId;
  final String networkType;
  final String networkStrength;
  final String deviceModel;
  final String androidVersion;
  final String appVersion;

  String toBlock() {
    return '{ userId: $userId, groupId: $groupId, networkType: $networkType, '
        'networkStrength: $networkStrength, deviceModel: $deviceModel, '
        'androidVersion: $androidVersion, appVersion: $appVersion }';
  }
}

class LogLine {
  static String formatTimestamp(DateTime time) {
    final local = time.isUtc ? time.toLocal() : time;
    final offset = local.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final minutes = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final y = local.year.toString().padLeft(4, '0');
    final mo = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final h = local.hour.toString().padLeft(2, '0');
    final mi = local.minute.toString().padLeft(2, '0');
    final s = local.second.toString().padLeft(2, '0');
    final ms = local.millisecond.toString().padLeft(3, '0');
    return '$y-$mo-${d}T$h:$mi:$s.$ms$sign$hours:$minutes';
  }

  static String format({
    required DateTime time,
    required LogLevel level,
    required String tag,
    required String message,
    required LogMetadata metadata,
  }) {
    final cleanTag = tag.trim().replaceAll(RegExp(r'^\[|\]$'), '');
    return '${formatTimestamp(time)} [${level.label}] [$cleanTag] $message '
        '${metadata.toBlock()}';
  }

  static String dailyFileName(DateTime time) {
    final local = time.isUtc ? time.toLocal() : time;
    final y = local.year.toString().padLeft(4, '0');
    final mo = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    return 'oneone_logs_$y$mo$d.txt';
  }
}
