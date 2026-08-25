import 'package:one_one_app/one_one.dart';

class LogFileInfo {
  const LogFileInfo({
    required this.file,
    required this.sizeBytes,
    required this.lastModified,
  });

  final File file;
  final int sizeBytes;
  final DateTime lastModified;

  String get sizeLabel {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Persistent in-memory + file logger. Safe to call before [initialize]
/// completes — lines are queued and flushed once storage is ready.
class LogManager {
  LogManager._();

  static const MethodChannel _channel = MethodChannel('app.oneone/device_log');
  static const int _memoryCapacity = 400;
  static const int _retainDays = 3;

  static final Queue<String> _memory = Queue<String>();
  static Future<void> _writeChain = Future.value();
  static Completer<void>? _ready;
  static Directory? _directory;
  static String _userId = '-';
  static String _groupId = '-';
  static String _deviceModel = '-';
  static String _androidVersion = '-';
  static String _appVersion = '-';

  static Future<void> initialize() {
    final existing = _ready;
    if (existing != null) return existing.future;
    final completer = Completer<void>();
    _ready = completer;
    _doInitialize().then(completer.complete).catchError((Object error, StackTrace stack) {
      debugPrint('[LogManager] initialize failed: $error');
      completer.complete();
    });
    return completer.future;
  }

  static Future<void> _doInitialize() async {
    final package = await PackageInfo.fromPlatform();
    _appVersion = '${package.version}+${package.buildNumber}';
    if (Platform.isAndroid) {
      _androidVersion = 'Android ${Platform.operatingSystemVersion}';
    } else {
      _androidVersion = '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    }
    _deviceModel = Platform.localHostname;
    try {
      final dir = Platform.isAndroid
          ? await getExternalStorageDirectory()
          : await getApplicationDocumentsDirectory();
      _directory = Directory('${(dir ?? await getApplicationDocumentsDirectory()).path}/logs');
      await _directory!.create(recursive: true);
    } catch (error) {
      final fallback = await getApplicationDocumentsDirectory();
      _directory = Directory('${fallback.path}/logs');
      await _directory!.create(recursive: true);
      debugPrint('[LogManager] using documents dir fallback: $error');
    }
    await _pruneOldFiles();
    if (Platform.isAndroid) {
      try {
        final meta = await _channel.invokeMapMethod<String, dynamic>('getDeviceMeta');
        final model = meta?['deviceModel']?.toString().trim();
        final version = meta?['androidVersion']?.toString().trim();
        if (model != null && model.isNotEmpty) _deviceModel = model;
        if (version != null && version.isNotEmpty) _androidVersion = version;
      } catch (_) {
        // Native plugin may not be registered in tests.
      }
    }
    log(
      LogLevel.info,
      'LogManager',
      'Logger initialized; retaining $_retainDays daily files in ${_directory?.path}',
    );
  }

  static void setIdentity({String? userId, String? groupId}) {
    if (userId != null) _userId = userId.trim().isEmpty ? '-' : userId.trim();
    if (groupId != null) _groupId = groupId.trim().isEmpty ? '-' : groupId.trim();
    if (Platform.isAndroid) {
      unawaited(
        _channel.invokeMethod<void>('setIdentity', {
          'userId': _userId,
          'groupId': _groupId,
        }).then((_) {}, onError: (_) {}),
      );
    }
  }

  static void log(
    LogLevel level,
    String tag,
    String message, {
    String? userId,
    String? groupId,
  }) {
    unawaited(_logAsync(level, tag, message, userId: userId, groupId: groupId));
  }

  static Future<void> _logAsync(
    LogLevel level,
    String tag,
    String message, {
    String? userId,
    String? groupId,
  }) async {
    try {
      final network = await _captureNetwork();
      final line = LogLine.format(
        time: DateTime.now(),
        level: level,
        tag: tag,
        message: message,
        metadata: LogMetadata(
          userId: userId?.trim().isNotEmpty == true ? userId!.trim() : _userId,
          groupId: groupId?.trim().isNotEmpty == true
              ? groupId!.trim()
              : _groupId,
          networkType: network.$1,
          networkStrength: network.$2,
          deviceModel: _deviceModel,
          androidVersion: _androidVersion,
          appVersion: _appVersion,
        ),
      );
      _remember(line);
      debugPrint(line);
      _enqueueWrite(line);
    } catch (error) {
      // Logging must never fatal the root zone (AppLifecycle logs on every
      // foreground/background). Native meta maps can be unmodifiable.
      debugPrint('[LogManager] log failed tag=$tag error=$error');
    }
  }

  static void _remember(String line) {
    _memory.addLast(line);
    while (_memory.length > _memoryCapacity) {
      _memory.removeFirst();
    }
  }

  static void _enqueueWrite(String line) {
    _writeChain = _writeChain.then((_) async {
      await (_ready?.future ?? initialize());
      final directory = _directory;
      if (directory == null) return;
      final file = File('${directory.path}/${LogLine.dailyFileName(DateTime.now())}');
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
    }).catchError((Object error) {
      debugPrint('[LogManager] write failed: $error');
    });
  }

  static Future<(String, String)> _captureNetwork() async {
    try {
      if (Platform.isAndroid) {
        final meta = await _channel.invokeMapMethod<String, dynamic>('getNetworkMeta');
        if (meta != null) {
          return (
            meta['networkType']?.toString() ?? 'Unknown',
            meta['networkStrength']?.toString() ?? '-',
          );
        }
      }
      final results = await Connectivity().checkConnectivity();
      return (_networkTypeLabel(results), '-');
    } catch (_) {
      return ('Unknown', '-');
    }
  }

  static String _networkTypeLabel(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi)) return 'WiFi';
    if (results.contains(ConnectivityResult.mobile)) return 'Mobile';
    if (results.contains(ConnectivityResult.ethernet)) return 'Ethernet';
    if (results.contains(ConnectivityResult.vpn)) return 'VPN';
    if (results.contains(ConnectivityResult.none) || results.isEmpty) return 'None';
    return results.first.name;
  }

  static Future<void> _pruneOldFiles() async {
    final directory = _directory;
    if (directory == null || !directory.existsSync()) return;
    final cutoff = DateTime.now().subtract(Duration(days: _retainDays));
    final cutoffName = LogLine.dailyFileName(cutoff);
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('oneone_logs_') || !name.endsWith('.txt')) continue;
      if (name.compareTo(cutoffName) < 0) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }

  static Future<LogFileInfo?> todayFileInfo() async {
    await initialize();
    final file = todayFile();
    if (file == null || !file.existsSync()) return null;
    final stat = await file.stat();
    return LogFileInfo(
      file: file,
      sizeBytes: stat.size,
      lastModified: stat.modified,
    );
  }

  static File? todayFile() {
    final directory = _directory;
    if (directory == null) return null;
    return File('${directory.path}/${LogLine.dailyFileName(DateTime.now())}');
  }

  static Future<void> flush() async {
    await initialize();
    await _writeChain;
  }

  static Future<List<File>> retainedLogFiles() async {
    await flush();
    final directory = _directory;
    if (directory == null || !directory.existsSync()) return const [];
    final files = <File>[];
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.startsWith('oneone_logs_') || !name.endsWith('.txt')) continue;
      files.add(entity);
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  static String get userId => _userId;
  static String get groupId => _groupId;
  static String get deviceModel => _deviceModel;
  static String get androidVersion => _androidVersion;
  static String get appVersion => _appVersion;

  static Map<String, String> reportTags({
    String? userId,
    String? groupId,
  }) {
    return {
      'userId': (userId != null && userId.trim().isNotEmpty) ? userId.trim() : _userId,
      'groupId': (groupId != null && groupId.trim().isNotEmpty)
          ? groupId.trim()
          : _groupId,
      'appVersion': _appVersion,
      'deviceModel': _deviceModel,
      'androidVersion': _androidVersion,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };
  }

  static Future<String> readTodayText() async {
    await initialize();
    await _writeChain;
    final file = todayFile();
    if (file == null || !file.existsSync()) {
      return _memory.join('\n');
    }
    return file.readAsString();
  }

  static List<String> memorySnapshot() => List<String>.unmodifiable(_memory);
}
