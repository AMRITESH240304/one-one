import 'package:one_one_app/one_one.dart';

enum DeviceLogReportKind { crash, feedback }

/// Uploads the retained on-device log files to the app Cloud Storage bucket.
class DeviceLogReport {
  DeviceLogReport({ApiClient? apiClient}) : _apiClient = apiClient ?? ApiClient();

  static const _uploadTimeout = Duration(seconds: 60);

  /// True while the mandatory post-crash dialog is on screen.
  static bool uiBlocking = false;

  final ApiClient _apiClient;

  Future<void> upload({
    required DeviceLogReportKind kind,
    String? userId,
    String? groupId,
    String? description,
  }) async {
    final tags = LogManager.reportTags(userId: userId, groupId: groupId);
    final files = await LogManager.retainedLogFiles();
    final bytes = DeviceLogBundle.build(
      logFiles: files,
      tags: tags,
      description: description,
      memoryFallback: LogManager.memorySnapshot(),
    );

    LogManager.log(
      LogLevel.info,
      'DeviceLogReport',
      'Uploading ${kind.name} report bytes=${bytes.length} files=${files.length}',
      userId: tags['userId'],
      groupId: tags['groupId'],
    );

    final initiated = await _apiClient.postJson('/v1/device-logs/upload', {
      'kind': kind.name,
      'groupId': tags['groupId'],
      'appVersion': tags['appVersion'],
      'deviceModel': tags['deviceModel'],
      'androidVersion': tags['androidVersion'],
      if (description != null && description.trim().isNotEmpty)
        'description': description.trim(),
    });

    final uploadUrl = initiated['uploadUrl']?.toString();
    final storagePath = initiated['storagePath']?.toString();
    if (uploadUrl == null ||
        uploadUrl.isEmpty ||
        storagePath == null ||
        storagePath.isEmpty) {
      throw const ApiException(
        statusCode: 500,
        code: 'device_log_upload_url_invalid',
        message: 'Backend did not return a usable signed write URL.',
      );
    }

    final requiredHeaders = <String, String>{};
    final rawHeaders = initiated['requiredHeaders'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        requiredHeaders[key.toString()] = value.toString();
      });
    }
    if (!requiredHeaders.containsKey('content-type')) {
      requiredHeaders['content-type'] =
          initiated['contentType']?.toString() ?? 'application/zip';
    }

    await _apiClient.putBytesToUrl(
      uploadUrl,
      bytes,
      headers: requiredHeaders,
      timeout: _uploadTimeout,
    );

    final metadata = initiated['metadata'];
    await _apiClient.postJson('/v1/device-logs/complete', {
      'storagePath': storagePath,
      'metadata': metadata is Map<String, dynamic>
          ? metadata
          : metadata is Map
          ? Map<String, dynamic>.from(metadata)
          : tags,
    });

    debugPrint(
      '[DeviceLogReport] uploaded kind=${kind.name} path=$storagePath '
      'bytes=${bytes.length}',
    );
  }
}
