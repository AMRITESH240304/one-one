import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../models/group_chat_message.dart';

/// Renders sent chat bubbles in the group screen's cleared center area. Own
/// messages align right, others' align left; every bubble shows the
/// sender's name and self-removes once [expiresAt] elapses via its own
/// independent timer (see [_ChatBubbleTile]). The host caps how many past
/// bubbles stay in the list (rolling window).
class ChatBubbleFeed extends StatelessWidget {
  const ChatBubbleFeed({
    super.key,
    required this.messages,
    required this.currentUserId,
    required this.accent,
    required this.onExpire,
  });

  final List<GroupChatMessage> messages;
  final String currentUserId;
  final Color accent;
  final ValueChanged<String> onExpire;

  @override
  Widget build(BuildContext context) {
    final visible = messages
        .where((message) => !message.isExpired)
        .toList(growable: false);
    if (visible.isEmpty) return const SizedBox.shrink();

    // Stretch so each row is full-width; without that, MainAxisAlignment
    // start/end has no room to pin bubbles left (theirs) vs right (ours).
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final message in visible)
          _ChatBubbleTile(
            key: ValueKey(message.messageId),
            message: message,
            isOwn: message.senderUserId == currentUserId,
            accent: accent,
            onExpire: () => onExpire(message.messageId),
          ),
      ],
    );
  }
}

class _ChatBubbleTile extends StatefulWidget {
  const _ChatBubbleTile({
    super.key,
    required this.message,
    required this.isOwn,
    required this.accent,
    required this.onExpire,
  });

  final GroupChatMessage message;
  final bool isOwn;
  final Color accent;
  final VoidCallback onExpire;

  @override
  State<_ChatBubbleTile> createState() => _ChatBubbleTileState();
}

class _ChatBubbleTileState extends State<_ChatBubbleTile> {
  Timer? _expiryTimer;

  @override
  void initState() {
    super.initState();
    // Each bubble owns its own expiry timer rather than sharing one clock
    // with the rest of the feed, so late-joining tiles (e.g. after a
    // rebuild) still expire exactly 15 minutes after they were sent.
    _expiryTimer = Timer(
      Duration(seconds: widget.message.secondsUntilExpiry),
      () {
        if (mounted) widget.onExpire();
      },
    );
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isOwn = widget.isOwn;

    return Padding(
      padding: EdgeInsets.symmetric(vertical: 3.h),
      child: Row(
        mainAxisAlignment: isOwn
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: 230.w),
            child: Column(
              crossAxisAlignment: isOwn
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12.w),
                  child: Text(
                    isOwn ? 'You' : message.senderDisplayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10.sp,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                SizedBox(height: 2.h),
                Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: 14.w,
                    vertical: 8.h,
                  ),
                  decoration: BoxDecoration(
                    color: isOwn ? widget.accent : const Color(0xff2a2a2a),
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(16),
                      topRight: const Radius.circular(16),
                      bottomLeft: Radius.circular(isOwn ? 16 : 4),
                      bottomRight: Radius.circular(isOwn ? 4 : 16),
                    ),
                  ),
                  child: Text(
                    message.text,
                    style: TextStyle(
                      color: isOwn ? Colors.black : Colors.white,
                      fontSize: 13.sp,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
