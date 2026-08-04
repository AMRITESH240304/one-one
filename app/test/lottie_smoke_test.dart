import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lottie/lottie.dart';

void main() {
  for (final asset in [
    'assets/lottie/mic_pulse.json',
    'assets/lottie/notification_wave.json',
    'assets/lottie/radio_connect.json',
  ]) {
    testWidgets('$asset loads and animates without error', (tester) async {
      FlutterError? caught;
      final prevHandler = FlutterError.onError;
      FlutterError.onError = (details) {
        caught ??= details.exception is FlutterError
            ? details.exception as FlutterError
            : FlutterError(details.exceptionAsString());
      };

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 240,
                height: 240,
                child: Lottie.asset(asset, repeat: true),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));

      FlutterError.onError = prevHandler;
      expect(caught, isNull, reason: caught?.toString());
      expect(find.byType(Lottie), findsOneWidget);
    });
  }
}
