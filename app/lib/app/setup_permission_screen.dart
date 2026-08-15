import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:permission_handler/permission_handler.dart';

enum _SetupStep { mic, notification, background }

class _StepVisual {
  const _StepVisual({
    required this.iconColor,
    required this.icon,
    required this.backgroundAsset,
    this.boxColor,
    this.shiftX = 0,
  });

  final Color iconColor;
  final IconData icon;
  final String backgroundAsset;

  /// Background color of the image's own artwork. When set, the image is
  /// wrapped in a box container painted with this exact color so the
  /// contained illustration blends seamlessly with the frame around it.
  final Color? boxColor;

  /// Horizontal offset (logical px) applied to the image. Used to nudge a
  /// step's artwork right by a fixed amount.
  final double shiftX;
}

/// Icon colors are picked to match the dominant tone of each onboarding
/// background image so the CTA card feels native to the artwork behind it.
///
/// `boxColor` must match the background color of the artwork exactly. Screens
/// 1 and 3 (Onboarding1/Onboarding3) use a box container painted with the
/// image's own backdrop so the illustration doesn't look like it was
/// over-enlarged to fill the screen.
const Map<_SetupStep, _StepVisual> _stepVisuals = {
  _SetupStep.mic: _StepVisual(
    iconColor: Color(0xff8fa83e),
    icon: Icons.mic_rounded,
    backgroundAsset: 'assets/Onboarding1.png',
    // Backdrop of Onboarding1.png is a solid lime green (mode rgb 140,162,77).
    boxColor: Color(0xff8CA24D),
  ),
  _SetupStep.notification: _StepVisual(
    iconColor: Color(0xff7a4fc9),
    icon: Icons.notifications_rounded,
    backgroundAsset: 'assets/Onboarding3.png',
    // Backdrop of Onboarding3.png is a solid purple (mode rgb 97,39,123).
    boxColor: Color(0xff61277B),
  ),
  _SetupStep.background: _StepVisual(
    iconColor: Color(0xffdb8a1e),
    icon: Icons.battery_saver_rounded,
    backgroundAsset: 'assets/Onboarding2.png',
    // Shift Onboarding2's artwork 20 logical px to the right. No box.
    shiftX: 20,
  ),
};

class SetupPermissionScreen extends StatefulWidget {
  const SetupPermissionScreen({super.key, required this.onComplete});

  final Future<void> Function() onComplete;

  @override
  State<SetupPermissionScreen> createState() => _SetupPermissionScreenState();
}

class _SetupPermissionScreenState extends State<SetupPermissionScreen>
    with WidgetsBindingObserver {
  static const Duration _stageTransitionDuration = Duration(milliseconds: 320);

  _SetupStep _step = _SetupStep.mic;
  bool _micGranted = false;
  bool _notificationGranted = false;
  bool _backgroundGranted = false;
  bool _busy = false;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _step == _SetupStep.background &&
        _busy &&
        !_completed) {
      unawaited(_finishBackgroundPermission());
    }
  }

  Future<void> _requestMicPermission() async {
    if (_busy || _step != _SetupStep.mic) return;

    setState(() => _busy = true);
    final status = await Permission.microphone.request();
    if (!mounted) return;

    if (!status.isGranted) {
      setState(() => _busy = false);
      _showDeniedSnackBar('Microphone permission is required.');
      return;
    }

    setState(() => _micGranted = true);
    await Future<void>.delayed(_stageTransitionDuration);
    if (!mounted) return;

    setState(() {
      _busy = false;
      _step = _SetupStep.notification;
    });
  }

  Future<void> _requestNotificationPermission() async {
    if (_busy || _step != _SetupStep.notification) return;

    setState(() => _busy = true);
    final status = await Permission.notification.request();
    if (!mounted) return;

    if (!status.isGranted) {
      setState(() {
        _busy = false;
        _step = _SetupStep.background;
      });
      _showDeniedSnackBar(
        'Notifications can be enabled later in Android Settings.',
      );
      return;
    }

    setState(() => _notificationGranted = true);
    await Future<void>.delayed(_stageTransitionDuration);
    if (!mounted) return;

    setState(() {
      _busy = false;
      _step = _SetupStep.background;
    });
  }

  Future<void> _requestBackgroundPermission() async {
    if (_busy || _step != _SetupStep.background || _completed) return;
    setState(() => _busy = true);

    try {
      if (Platform.isAndroid && !await _isBackgroundActivityAllowed()) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
      await _finishBackgroundPermission();
    } catch (_) {
      if (!mounted || _completed) return;
      setState(() => _busy = false);
      _showDeniedSnackBar(
        'Allow background activity so nudges can reach you reliably.',
      );
    }
  }

  Future<void> _finishBackgroundPermission() async {
    if (!mounted || _completed || _step != _SetupStep.background) return;

    final granted = await _isBackgroundActivityAllowed();
    if (!mounted || _completed) return;
    if (!granted) {
      _completed = true;
      await widget.onComplete();
      return;
    }

    _completed = true;
    setState(() => _backgroundGranted = true);
    await Future<void>.delayed(_stageTransitionDuration);
    if (!mounted) return;
    try {
      await widget.onComplete();
    } catch (_) {
      if (!mounted) return;
      _completed = false;
      setState(() => _busy = false);
      _showDeniedSnackBar('Setup could not be completed. Please try again.');
    }
  }

  Future<bool> _isBackgroundActivityAllowed() async {
    if (!Platform.isAndroid) return true;
    try {
      return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    } catch (_) {
      return false;
    }
  }

  void _showDeniedSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Renders the step's artwork.
  ///
  /// Screens with a [boxColor] (Onboarding1/Onboarding3) are wrapped in a box
  /// container painted with the image's own backdrop color and fitted with
  /// `BoxFit.contain`, so the illustration is never enlarged to cover the
  /// full screen — the matching background blends the letterbox areas in.
  /// Screens without one keep the full-bleed `BoxFit.cover` and only apply a
  /// horizontal [shiftX] offset.
  Widget _buildStepBackground(_StepVisual visual) {
    final boxColor = visual.boxColor;
    Widget image = Image.asset(
      visual.backgroundAsset,
      key: ValueKey(visual.backgroundAsset),
      fit: boxColor != null ? BoxFit.contain : BoxFit.cover,
      width: double.infinity,
      height: double.infinity,
      alignment: Alignment.center,
    );
    if (visual.shiftX != 0) {
      image = Transform.translate(
        offset: Offset(visual.shiftX, 0),
        child: image,
      );
    }
    if (boxColor != null) {
      image = Container(
        color: boxColor,
        width: double.infinity,
        height: double.infinity,
        child: image,
      );
    }
    // The AnimatedSwitcher needs a stable, unique key on the widget it
    // directly receives so cross-fading detects the step change.
    return KeyedSubtree(
      key: ValueKey(visual.backgroundAsset),
      child: image,
    );
  }

  @override
  Widget build(BuildContext context) {
    final visual = _stepVisuals[_step]!;

    return Scaffold(
      backgroundColor: const Color(0xff000000),
      body: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedSwitcher(
            duration: _stageTransitionDuration,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) {
              return FadeTransition(opacity: animation, child: child);
            },
            child: _buildStepBackground(visual),
          ),
          // Bottom scrim so the CTA card and footnote stay legible over
          // whatever part of the artwork ends up behind them.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 320.h,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0),
                    Colors.black.withValues(alpha: 0.55),
                    Colors.black.withValues(alpha: 0.88),
                  ],
                  stops: const [0, 0.45, 1],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24.w),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  AnimatedSwitcher(
                    duration: _stageTransitionDuration,
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      final offsetAnimation = Tween<Offset>(
                        begin: const Offset(0.12, 0),
                        end: Offset.zero,
                      ).animate(animation);
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: offsetAnimation,
                          child: child,
                        ),
                      );
                    },
                    child: switch (_step) {
                      _SetupStep.mic => _PermissionCard(
                        key: const ValueKey('mic-card'),
                        iconColor: visual.iconColor,
                        icon: visual.icon,
                        title: 'mic',
                        subtitle:
                            'so your friends can hear you\nwhen you talk...',
                        checked: _micGranted,
                        onTap: _requestMicPermission,
                      ),
                      _SetupStep.notification => _PermissionCard(
                        key: const ValueKey('notification-card'),
                        iconColor: visual.iconColor,
                        icon: visual.icon,
                        title: 'notifications',
                        subtitle: 'know when your friends are\ntalking to you',
                        checked: _notificationGranted,
                        onTap: _requestNotificationPermission,
                      ),
                      _SetupStep.background => _PermissionCard(
                        key: const ValueKey('background-card'),
                        iconColor: visual.iconColor,
                        icon: visual.icon,
                        title: 'background activity',
                        subtitle: 'receive nudges when duo\nisn\'t open',
                        checked: _backgroundGranted,
                        onTap: _requestBackgroundPermission,
                      ),
                    },
                  ),
                  SizedBox(height: 16.h),
                  Text(
                    '*we need those for duo to work',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: const Color.fromRGBO(255, 255, 255, 0.72),
                      fontSize: 11.sp,
                      height: 1.2,
                    ),
                  ),
                  SizedBox(height: 28.h),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  const _PermissionCard({
    super.key,
    required this.iconColor,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.checked,
    required this.onTap,
  });

  final Color iconColor;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 14.h),
        decoration: BoxDecoration(
          color: const Color(0xff131d28),
          borderRadius: BorderRadius.circular(24.r),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.22),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 34.w,
              height: 34.w,
              decoration: BoxDecoration(
                color: iconColor,
                borderRadius: BorderRadius.circular(10.r),
              ),
              child: Icon(icon, color: Colors.white, size: 20.sp),
            ),
            SizedBox(width: 12.w),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18.sp,
                      fontWeight: FontWeight.w700,
                      height: 1,
                    ),
                  ),
                  SizedBox(height: 4.h),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: const Color.fromRGBO(255, 255, 255, 0.68),
                      fontSize: 12.sp,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(width: 12.w),
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 24.w,
              height: 24.w,
              decoration: BoxDecoration(
                color: checked ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(6.r),
                border: Border.all(
                  color: checked
                      ? Colors.white
                      : const Color.fromRGBO(255, 255, 255, 0.32),
                  width: 1.6,
                ),
              ),
              child: checked
                  ? Icon(
                      Icons.check_rounded,
                      size: 16.sp,
                      color: const Color(0xff131d28),
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
