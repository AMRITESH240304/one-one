import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import 'log_level.dart';
import 'log_manager.dart';

Future<void> showDebugLogsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xff1b1b1b),
    showDragHandle: true,
    builder: (sheetContext) => const _DebugLogsSheet(),
  );
}

class _DebugLogsSheet extends StatefulWidget {
  const _DebugLogsSheet();

  @override
  State<_DebugLogsSheet> createState() => _DebugLogsSheetState();
}

class _DebugLogsSheetState extends State<_DebugLogsSheet> {
  LogFileInfo? _info;
  bool _loading = true;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await LogManager.todayFileInfo();
    if (!mounted) return;
    setState(() {
      _info = info;
      _loading = false;
    });
  }

  Future<void> _share() async {
    final file = _info?.file ?? LogManager.todayFile();
    if (file == null || !file.existsSync()) {
      setState(() => _message = 'No log file yet.');
      return;
    }
    LogManager.log(LogLevel.info, 'LogManager', 'Share log file requested');
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path, mimeType: 'text/plain')],
        subject: 'Duo debug logs',
      ),
    );
  }

  Future<void> _copy() async {
    final text = await LogManager.readTodayText();
    await Clipboard.setData(ClipboardData(text: text));
    LogManager.log(LogLevel.info, 'LogManager', 'Copied log text to clipboard');
    if (!mounted) return;
    setState(() => _message = 'Copied to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                'Debug Logs',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Text(
                _loading
                    ? 'Reading today’s log file…'
                    : info == null
                    ? 'No log file has been written yet today.'
                    : 'Today’s file · ${info.sizeLabel} · last updated ${_formatTime(info.lastModified)}',
                style: const TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              leading: const Icon(Icons.ios_share, color: Colors.white70),
              title: const Text(
                'Share Log File',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                'Opens the system share sheet with today’s .txt file',
                style: TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
              onTap: _share,
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined, color: Colors.white70),
              title: const Text(
                'Copy to Clipboard',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                'Copies the full text of today’s log file',
                style: TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
              onTap: _copy,
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                child: Text(
                  _message!,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
