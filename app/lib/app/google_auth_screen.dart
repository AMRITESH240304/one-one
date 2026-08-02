import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../core/firebase/crashlytics_service.dart';
import '../features/identity/data/identity_repository.dart';

class GoogleAuthScreen extends StatefulWidget {
  const GoogleAuthScreen({super.key});

  @override
  State<GoogleAuthScreen> createState() => _GoogleAuthScreenState();
}

class _GoogleAuthScreenState extends State<GoogleAuthScreen>
    with SingleTickerProviderStateMixin {
  final IdentityRepository _identityRepository = IdentityRepository();
  late final AnimationController _logoController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  )..forward();
  bool _isSigningIn = false;
  String? _errorMessage;

  @override
  void dispose() {
    _logoController.dispose();
    _identityRepository.dispose();
    super.dispose();
  }

  Future<void> _continueWithGoogle() async {
    if (_isSigningIn) return;
    setState(() {
      _isSigningIn = true;
      _errorMessage = null;
    });

    try {
      await _identityRepository.signInWithGoogle();
      // The root Firebase auth stream advances to onboarding.
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
    final logoAnimation = CurvedAnimation(
      parent: _logoController,
      curve: Curves.easeOutCubic,
    );
    return Scaffold(
      backgroundColor: const Color(0xffF8BE03),
      body: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(28.w, 28.h, 28.w, 24.h),
          child: Column(
            children: [
              const Spacer(flex: 2),
              FadeTransition(
                opacity: logoAnimation,
                child: AnimatedBuilder(
                  animation: logoAnimation,
                  child: Image.asset(
                    'assets/logo.png',
                    width: 172.w,
                    fit: BoxFit.contain,
                  ),
                  builder: (context, child) => Transform.translate(
                    offset: Offset(0, 28.h * (1 - logoAnimation.value)),
                    child: child,
                  ),
                ),
              ),
              SizedBox(height: 36.h),
              Text(
                'Welcome to One One',
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
                busy: _isSigningIn,
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

class _GoogleSignInButton extends StatefulWidget {
  const _GoogleSignInButton({required this.busy, required this.onTap});
  final bool busy;
  final VoidCallback onTap;
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
                widget.busy ? 'Signing in…' : 'Continue with Google',
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
