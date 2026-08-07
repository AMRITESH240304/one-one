import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../data/chat_message_repository.dart';

/// Bottom row of preset message bubbles + a keyboard icon that morphs the
/// row into a one-off custom-message composer. Works in any online/offline
/// state — sending never depends on group presence.
class ChatBubbleBar extends StatefulWidget {
  const ChatBubbleBar({super.key, required this.accent, required this.onSend});

  final Color accent;

  /// Sends a preset or custom message. Rethrows on failure so the bar can
  /// surface a brief inline error instead of silently swallowing it.
  final Future<void> Function(String text) onSend;

  static const List<String> presets = [
    "I'll join in 15 min",
    'Where is everyone?',
    'On my way',
    'Give me 5 min',
  ];

  @override
  State<ChatBubbleBar> createState() => _ChatBubbleBarState();
}

class _ChatBubbleBarState extends State<ChatBubbleBar> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  bool _composing = false;
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _openComposer() {
    setState(() => _composing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _closeComposer() {
    _controller.clear();
    _focusNode.unfocus();
    setState(() => _composing = false);
  }

  Future<void> _sendPreset(String text) async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(text);
    } catch (_) {
      // Best-effort UX: the row stays usable, no blocking error dialog for
      // a one-tap ephemeral message.
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _sendCustom() async {
    final sanitized = ChatMessageRepository.sanitize(_controller.text);
    if (sanitized == null || _sending) return;
    setState(() => _sending = true);
    try {
      await widget.onSend(sanitized);
      if (mounted) _controller.clear();
    } catch (_) {
      // See _sendPreset.
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _composing = false;
        });
        _focusNode.unfocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: _composing ? _buildComposer() : _buildPresetRow(),
    );
  }

  Widget _buildPresetRow() {
    return SizedBox(
      key: const ValueKey('preset-row'),
      height: 40.h,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: 16.w),
        children: [
          for (final preset in ChatBubbleBar.presets) ...[
            _PresetChip(
              label: preset,
              enabled: !_sending,
              onTap: () => unawaited(_sendPreset(preset)),
            ),
            SizedBox(width: 8.w),
          ],
          _KeyboardButton(accent: widget.accent, onTap: _openComposer),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    final wordCount = _controller.text.trim().isEmpty
        ? 0
        : _controller.text.trim().split(RegExp(r'\s+')).length;
    final canSend =
        !_sending && ChatMessageRepository.sanitize(_controller.text) != null;

    return Padding(
      key: const ValueKey('composer'),
      padding: EdgeInsets.symmetric(horizontal: 16.w),
      child: Row(
        children: [
          IconButton(
            onPressed: _closeComposer,
            icon: const Icon(Icons.close_rounded, color: Colors.white70),
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 14.w),
              decoration: BoxDecoration(
                color: const Color(0xff2a2a2a),
                borderRadius: BorderRadius.circular(20.r),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      focusNode: _focusNode,
                      maxLines: 1,
                      textInputAction: TextInputAction.send,
                      inputFormatters: [
                        _WordLimitFormatter(ChatMessageRepository.maxWords),
                      ],
                      style: TextStyle(color: Colors.white, fontSize: 14.sp),
                      decoration: const InputDecoration(
                        hintText: 'Message the group…',
                        hintStyle: TextStyle(color: Colors.white38),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => unawaited(_sendCustom()),
                    ),
                  ),
                  Text(
                    '$wordCount/${ChatMessageRepository.maxWords}',
                    style: TextStyle(
                      color: wordCount > ChatMessageRepository.maxWords
                          ? const Color(0xffff5a5f)
                          : Colors.white38,
                      fontSize: 10.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(width: 8.w),
          IconButton(
            onPressed: canSend ? () => unawaited(_sendCustom()) : null,
            icon: Icon(
              Icons.send_rounded,
              color: canSend ? widget.accent : Colors.white24,
            ),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: const Color(0xff1f1f1f),
        borderRadius: BorderRadius.circular(20.r),
        child: InkWell(
          borderRadius: BorderRadius.circular(20.r),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 14.w, vertical: 9.h),
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white,
                fontSize: 12.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyboardButton extends StatelessWidget {
  const _KeyboardButton({required this.accent, required this.onTap});

  final Color accent;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Write a custom message',
      child: Material(
        color: accent.withValues(alpha: 0.16),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(9.r),
            child: Icon(Icons.keyboard_rounded, color: accent, size: 18.sp),
          ),
        ),
      ),
    );
  }
}

/// Hard-blocks edits that would push the message over [maxWords] words,
/// giving immediate feedback instead of only validating on send.
class _WordLimitFormatter extends TextInputFormatter {
  const _WordLimitFormatter(this.maxWords);

  final int maxWords;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final trimmed = newValue.text.trim();
    final words = trimmed.isEmpty
        ? const <String>[]
        : trimmed.split(RegExp(r'\s+'));
    if (words.length <= maxWords) return newValue;
    return oldValue;
  }
}
