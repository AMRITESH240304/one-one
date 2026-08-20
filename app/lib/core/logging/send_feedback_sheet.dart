import 'package:flutter/material.dart';

import '../ui/bottom_system_inset.dart';
import 'device_log_report.dart';
import 'log_level.dart';
import 'log_manager.dart';

Future<void> showSendFeedbackSheet(
  BuildContext context, {
  String? userId,
  String? groupId,
  DeviceLogReport? report,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xff1b1b1b),
    showDragHandle: true,
    builder: (sheetContext) => _SendFeedbackSheet(
      userId: userId,
      groupId: groupId,
      report: report ?? DeviceLogReport(),
    ),
  );
}

class _SendFeedbackSheet extends StatefulWidget {
  const _SendFeedbackSheet({
    required this.userId,
    required this.groupId,
    required this.report,
  });

  final String? userId;
  final String? groupId;
  final DeviceLogReport report;

  @override
  State<_SendFeedbackSheet> createState() => _SendFeedbackSheetState();
}

class _SendFeedbackSheetState extends State<_SendFeedbackSheet> {
  final _controller = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final description = _controller.text.trim();
    try {
      await widget.report.upload(
        kind: DeviceLogReportKind.feedback,
        userId: widget.userId,
        groupId: widget.groupId,
        description: description.isEmpty ? null : description,
      );
      LogManager.log(
        LogLevel.info,
        'DeviceLogReport',
        'Feedback report sent',
        userId: widget.userId,
        groupId: widget.groupId,
      );
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.pop(context);
      messenger?.showSnackBar(
        const SnackBar(content: Text('Thanks, your report was sent')),
      );
    } catch (error) {
      LogManager.log(
        LogLevel.error,
        'DeviceLogReport',
        'Feedback upload failed: $error',
        userId: widget.userId,
        groupId: widget.groupId,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _error = 'Couldn\'t send your report. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return BottomSystemSafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 4, 18, 16 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Send Feedback',
              style: TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Describe what went wrong. Recent on-device logs will be attached.',
              style: TextStyle(color: Colors.white54, fontSize: 12.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _controller,
              enabled: !_sending,
              maxLines: 5,
              maxLength: 2000,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'What happened? (optional)',
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: const Color(0xff101010),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white24),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.white24),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 4),
              Text(
                _error!,
                style: const TextStyle(color: Color(0xffff8a80), fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _sending ? null : _submit,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: _sending
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Send Report'),
            ),
          ],
        ),
      ),
    );
  }
}
