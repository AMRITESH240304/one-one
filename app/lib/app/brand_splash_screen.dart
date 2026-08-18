import 'package:flutter/material.dart';

/// Logo-less underlay matching the native Android splash background.
///
/// The native splash (`LaunchTheme` + `installSplashScreen`) owns the
/// branded logo. This widget exists only so that if the native splash
/// dismisses before the first real screen is ready, Flutter does not
/// paint a second, larger logo on top of the same yellow background.
class BrandSplashScreen extends StatelessWidget {
  const BrandSplashScreen({super.key});

  static const backgroundColor = Color(0xffF8BE03);

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: backgroundColor,
      body: SizedBox.expand(),
    );
  }
}
