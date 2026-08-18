import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../models/active_nudge.dart';

/// One row of incoming-nudge UI, shared by the dialogue overlay and the
/// optional multi-nudge list sheet so either surface can be swapped in.
class IncomingNudgePromptItem {
  const IncomingNudgePromptItem({
    required this.nudge,
    required this.groupName,
    required this.remainingOtherCount,
  });

  final ActiveNudge nudge;
  final String groupName;

  /// How many *other groups* still have an active nudge after this one.
  final int remainingOtherCount;

  String? get remainingHint {
    if (remainingOtherCount <= 0) return null;
    if (remainingOtherCount == 1) return '1 more nudge in another group';
    return '$remainingOtherCount more nudges in other groups';
  }
}

/// Modal Accept/Decline dialogue shown on top of the relevant group.
class IncomingNudgeDialogue extends StatelessWidget {
  const IncomingNudgeDialogue({
    super.key,
    required this.item,
    required this.accent,
    required this.onAccept,
    required this.onDecline,
    this.busy = false,
  });

  final IncomingNudgePromptItem item;
  final Color accent;
  final VoidCallback onAccept;
  final VoidCallback onDecline;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final hint = item.remainingHint;
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      child: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 28.w),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: 360.w),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xff161616),
                  borderRadius: BorderRadius.circular(24.r),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                ),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(22.w, 22.h, 22.w, 18.h),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Nudge',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 12.sp,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.6,
                        ),
                      ),
                      SizedBox(height: 8.h),
                      Text(
                        item.groupName,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22.sp,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                        ),
                      ),
                      SizedBox(height: 6.h),
                      Text(
                        'Join this group live?',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: 14.sp,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (hint != null) ...[
                        SizedBox(height: 12.h),
                        Text(
                          hint,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: accent.withValues(alpha: 0.9),
                            fontSize: 12.sp,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      SizedBox(height: 22.h),
                      Row(
                        children: [
                          Expanded(
                            child: _PromptButton(
                              label: 'Decline',
                              enabled: !busy,
                              onTap: onDecline,
                              background: Colors.white.withValues(alpha: 0.08),
                              foreground: Colors.white70,
                            ),
                          ),
                          SizedBox(width: 10.w),
                          Expanded(
                            child: _PromptButton(
                              label: 'Accept',
                              enabled: !busy,
                              onTap: onAccept,
                              background: accent,
                              foreground: Colors.black,
                              busy: busy,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PromptButton extends StatelessWidget {
  const _PromptButton({
    required this.label,
    required this.enabled,
    required this.onTap,
    required this.background,
    required this.foreground,
    this.busy = false,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final Color background;
  final Color foreground;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: enabled ? onTap : null,
      style: FilledButton.styleFrom(
        backgroundColor: background,
        foregroundColor: foreground,
        disabledBackgroundColor: background.withValues(alpha: 0.5),
        padding: EdgeInsets.symmetric(vertical: 14.h),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16.r),
        ),
      ),
      child: busy
          ? SizedBox(
              width: 18.sp,
              height: 18.sp,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: foreground,
              ),
            )
          : Text(
              label,
              style: TextStyle(fontSize: 15.sp, fontWeight: FontWeight.w700),
            ),
    );
  }
}

/// Alternative home-open UI: a bottom sheet listing every group with an
/// active nudge, each with inline Join / Decline. Not wired up yet — the
/// dialogue overlay is the default. Swap by pointing the home screen at
/// this instead of [IncomingNudgeDialogue].
Future<void> showIncomingNudgeListSheet(
  BuildContext context, {
  required List<IncomingNudgePromptItem> items,
  required Color accent,
  required Future<void> Function(IncomingNudgePromptItem item) onAccept,
  required Future<void> Function(IncomingNudgePromptItem item) onDecline,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) {
      return IncomingNudgeListSheet(
        items: items,
        accent: accent,
        onAccept: onAccept,
        onDecline: onDecline,
      );
    },
  );
}

class IncomingNudgeListSheet extends StatelessWidget {
  const IncomingNudgeListSheet({
    super.key,
    required this.items,
    required this.accent,
    required this.onAccept,
    required this.onDecline,
  });

  final List<IncomingNudgePromptItem> items;
  final Color accent;
  final Future<void> Function(IncomingNudgePromptItem item) onAccept;
  final Future<void> Function(IncomingNudgePromptItem item) onDecline;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xff141414),
      borderRadius: BorderRadius.vertical(top: Radius.circular(28.r)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20.w, 12.h, 20.w, 20.h),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 38.w,
                  height: 4.h,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              SizedBox(height: 16.h),
              Text(
                'Active nudges',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 12.h),
              for (final item in items) ...[
                _IncomingNudgeListRow(
                  item: item,
                  accent: accent,
                  onAccept: () => onAccept(item),
                  onDecline: () => onDecline(item),
                ),
                SizedBox(height: 8.h),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _IncomingNudgeListRow extends StatelessWidget {
  const _IncomingNudgeListRow({
    required this.item,
    required this.accent,
    required this.onAccept,
    required this.onDecline,
  });

  final IncomingNudgePromptItem item;
  final Color accent;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(14.w, 12.h, 10.w, 12.h),
      decoration: BoxDecoration(
        color: const Color(0xff1e1e1e),
        borderRadius: BorderRadius.circular(16.r),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.groupName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white,
                fontSize: 15.sp,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: onDecline,
            child: Text(
              'Decline',
              style: TextStyle(color: Colors.white54, fontSize: 13.sp),
            ),
          ),
          FilledButton(
            onPressed: onAccept,
            style: FilledButton.styleFrom(
              backgroundColor: accent,
              foregroundColor: Colors.black,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('Join'),
          ),
        ],
      ),
    );
  }
}
