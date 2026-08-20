import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/core/logging/device_log_bundle.dart';

void main() {
  test('bundles retained log files with tagged manifest', () {
    final dir = Directory.systemTemp.createTempSync('oneone-logs-');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    final file = File('${dir.path}/oneone_logs_20260820.txt')
      ..writeAsStringSync('line-one\n');

    final zipBytes = DeviceLogBundle.build(
      logFiles: [file],
      tags: const {
        'userId': 'user-1',
        'groupId': 'group-9',
        'appVersion': '1.0.11+11',
        'deviceModel': 'Pixel 8',
        'androidVersion': '16',
        'timestamp': '2026-08-20T00:00:00.000Z',
      },
      description: 'app crashed after going online',
    );

    expect(zipBytes.length, greaterThan(4));
    expect(String.fromCharCodes(zipBytes.take(2)), 'PK');

    final archive = ZipDecoder().decodeBytes(zipBytes);
    final names = archive.map((f) => f.name).toSet();
    expect(names, containsAll(['manifest.json', 'description.txt', 'oneone_logs_20260820.txt']));
    final manifest = archive.findFile('manifest.json')!;
    final manifestText = String.fromCharCodes(manifest.content as List<int>);
    expect(manifestText, contains('user-1'));
    expect(manifestText, contains('group-9'));
    expect(manifestText, contains('Pixel 8'));
  });

  test('falls back to in-memory snapshot when no files exist', () {
    final zipBytes = DeviceLogBundle.build(
      logFiles: const [],
      tags: const {'userId': 'user-1', 'timestamp': 't'},
      memoryFallback: const ['[INFO] hello'],
    );
    final archive = ZipDecoder().decodeBytes(zipBytes);
    expect(archive.findFile('memory_snapshot.txt'), isNotNull);
  });
}
