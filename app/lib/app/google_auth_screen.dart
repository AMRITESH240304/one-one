import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../core/firebase/crashlytics_service.dart';
import '../features/identity/data/identity_repository.dart';

class GoogleAuthScreen extends StatefulWidget {
  const GoogleAuthScreen({super.key, this.initializing = false});

  /// When true, shows the brand splash (logo + pulse dots) only — never the
  /// signed-out welcome CTA. Used while Firebase is still initializing so a
  /// returning signed-in session never flashes "Welcome to Duo".
  final bool initializing;

  @override
  State<GoogleAuthScreen> createState() => _GoogleAuthScreenState();
}

class _GoogleAuthScreenState extends State<GoogleAuthScreen> {
  IdentityRepository? _identityRepository;
  bool _isSigningIn = false;
  String? _errorMessage;

  IdentityRepository get _repo =>
      _identityRepository ??= IdentityRepository();

  @override
  void dispose() {
    _identityRepository?.dispose();
    super.dispose();
  }

  Future<void> _continueWithGoogle() async {
    if (_isSigningIn) return;
    // IMMEDIATELY replace the welcome UI with the splash screen so the user
    // sees an instant transition rather than waiting on a button spinner.
    // The Firebase auth stream will swap this screen out for StartupGateScreen
    // once sign-in completes.
    setState(() {
      _isSigningIn = true;
      _errorMessage = null;
    });

    try {
      await _repo.signInWithGoogle();
      // On success the root Firebase auth stream advances to onboarding.
      // Don't touch _isSigningIn – leave this screen in its splash state
      // until the StreamBuilder replaces it.
    } catch (error, stack) {
      final message = error.toString();
      final cancelled =
          message.contains('canceled') || message.contains('cancelled');
      if (!cancelled) {
        await CrashlyticsService.recordError(
          error,
          stack,
          reason: 'google_sign_in_failed',
        );
      }
      if (!mounted) return;
      setState(() {
        _isSigningIn = false;
        _errorMessage = _friendlyError(error);
      });
    }
  }

  String _friendlyError(Object error) {
    final message = error.toString();
    if (message.contains('canceled') || message.contains('cancelled')) {
      return 'Google sign-in was cancelled. Please try again.';
    }
    return 'Google sign-in couldn\'t be completed. Check your internet connection and try again.';
  }

  @override
  Widget build(BuildContext context) {
    // Firebase still booting, or Google sign-in just started: brand splash only.
    // Matches StartupGateScreen so cold starts never flash the welcome CTA at
    // already-signed-in users.
    if (widget.initializing || _isSigningIn) {
      return const BrandSplashScreen();
    }

    return Scaffold(
      backgroundColor: const Color(0xffF8BE03),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(28.w, 28.h, 28.w, 24.h),
          child: Column(
            children: [
              const Spacer(flex: 2),
              // Logo — static, no animation. Rendered in its final position
              // from the very first frame.
              Image.asset(
                'assets/logo.png',
                width: 172.w,
                fit: BoxFit.contain,
              ),
              SizedBox(height: 36.h),
              Text(
                'Welcome to Duo',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: const Color(0xff252a2e),
                  fontSize: 26.sp,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 10.h),
              Text(
                'Sign in or create your account before setting up your profile.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: const Color.fromRGBO(37, 42, 46, 0.72),
                  fontSize: 14.sp,
                  height: 1.45,
                ),
              ),
              const Spacer(flex: 3),
              if (_errorMessage != null) ...[
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: const Color(0xff7a2f2f),
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                SizedBox(height: 14.h),
              ],
              _GoogleSignInButton(
                busy: false,
                busyLabel: 'Signing in…',
                onTap: _continueWithGoogle,
              ),
              SizedBox(height: 22.h),
              Text(
                'By continuing, you agree to our terms & policies.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: const Color.fromRGBO(56, 64, 71, 0.72),
                  fontSize: 11.sp,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Brand splash with no Firebase access. Used while Firebase boots and
/// immediately after tapping Continue with Google.
class BrandSplashScreen extends StatelessWidget {
  const BrandSplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xffF8BE03),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 28.w),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset(
                  'assets/logo.png',
                  width: 190.w,
                  fit: BoxFit.contain,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GoogleSignInButton extends StatefulWidget {
  const _GoogleSignInButton({
    required this.busy,
    required this.onTap,
    this.busyLabel = 'Signing in…',
  });
  final bool busy;
  final VoidCallback onTap;
  final String busyLabel;
  @override
  State<_GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<_GoogleSignInButton> {
  bool _pressed = false;
  @override
  Widget build(BuildContext context) => AnimatedScale(
    scale: _pressed ? .96 : 1,
    duration: const Duration(milliseconds: 100),
    child: Material(
      color: widget.busy ? Colors.white70 : Colors.white,
      borderRadius: BorderRadius.circular(27.r),
      child: InkWell(
        onTap: widget.busy ? null : widget.onTap,
        onTapDown: widget.busy ? null : (_) => setState(() => _pressed = true),
        onTapUp: widget.busy ? null : (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        borderRadius: BorderRadius.circular(27.r),
        child: SizedBox(
          width: double.infinity,
          height: 54.h,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              widget.busy
                  ? SizedBox.square(
                      dimension: 19.w,
                      child: const CircularProgressIndicator(
                        strokeWidth: 2.3,
                        color: Color(0xff384047),
                      ),
                    )
                  : Text(
                      'G',
                      style: TextStyle(
                        fontSize: 19.sp,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
              SizedBox(width: 10.w),
              Text(
                widget.busy ? widget.busyLabel : 'Continue with Google',
                style: TextStyle(
                  color: const Color(0xff384047),
                  fontSize: 15.sp,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
