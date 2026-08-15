import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/core/logging/log_level.dart';
import 'package:one_one_app/core/logging/log_line.dart';

void main() {
  test('formats an ISO-8601 local timestamp with UTC offset', () {
    final time = DateTime(2026, 8, 15, 22, 1, 2, 123);
    final stamp = LogLine.formatTimestamp(time);
    expect(stamp, startsWith('2026-08-15T22:01:02.123'));
    expect(stamp, matches(RegExp(r'.+[+-]\d{2}:\d{2}$')));
  });

  test('formats a full log line with metadata', () {
    final line = LogLine.format(
      time: DateTime(2026, 8, 15, 22, 1, 2, 123),
      level: LogLevel.error,
      tag: 'NudgeService',
      message: 'Nudge not delivered: network error',
      metadata: const LogMetadata(
        userId: 'user-1',
        groupId: 'group-9',
        networkType: 'WiFi',
        networkStrength: '-50 dBm',
        deviceModel: 'Pixel 8',
        androidVersion: '15',
        appVersion: '1.0.8+8',
      ),
    );
    expect(line, contains('[ERROR]'));
    expect(line, contains('[NudgeService]'));
    expect(line, contains('Nudge not delivered: network error'));
    expect(
      line,
      contains(
        '{ userId: user-1, groupId: group-9, networkType: WiFi, '
        'networkStrength: -50 dBm, deviceModel: Pixel 8, '
        'androidVersion: 15, appVersion: 1.0.8+8 }',
      ),
    );
  });

  test('daily file name uses YYYYMMDD', () {
    expect(
      LogLine.dailyFileName(DateTime(2026, 8, 15, 23, 59)),
      'oneone_logs_20260815.txt',
    );
  });
}
