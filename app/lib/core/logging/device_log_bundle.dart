import 'package:one_one_app/one_one.dart';

/// Zips retained daily log files plus a JSON manifest of report tags.
class DeviceLogBundle {
  static const maxArchiveBytes = 8 * 1024 * 1024;

  static Uint8List build({
    required List<File> logFiles,
    required Map<String, String> tags,
    String? description,
    List<String> memoryFallback = const [],
  }) {
    final archive = Archive();
    archive.addFile(
      ArchiveFile.string(
        'manifest.json',
        const JsonEncoder.withIndent('  ').convert({
          ...tags,
          if (description != null && description.trim().isNotEmpty)
            'description': description.trim(),
        }),
      ),
    );
    if (description != null && description.trim().isNotEmpty) {
      archive.addFile(ArchiveFile.string('description.txt', description.trim()));
    }

    var addedLogs = 0;
    for (final file in logFiles) {
      if (!file.existsSync()) continue;
      final bytes = file.readAsBytesSync();
      final name = file.uri.pathSegments.isEmpty
          ? 'log.txt'
          : file.uri.pathSegments.last;
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
      addedLogs += 1;
    }
    if (addedLogs == 0 && memoryFallback.isNotEmpty) {
      archive.addFile(
        ArchiveFile.string('memory_snapshot.txt', memoryFallback.join('\n')),
      );
    }

    final encoded = ZipEncoder().encode(archive);
    if (encoded.length > maxArchiveBytes) {
      throw StateError(
        'Log archive is ${encoded.length} bytes; max is $maxArchiveBytes.',
      );
    }
    return Uint8List.fromList(encoded);
  }
}
