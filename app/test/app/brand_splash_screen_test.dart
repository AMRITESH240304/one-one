import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/app/brand_splash_screen.dart';
import 'package:one_one_app/app/google_auth_screen.dart';

void main() {
  testWidgets('startup underlay matches native splash color and has no logo', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: BrandSplashScreen()));

    expect(find.byType(Image), findsNothing);

    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    expect(scaffold.backgroundColor, BrandSplashScreen.backgroundColor);
  });

  testWidgets('GoogleAuthScreen initializing does not paint a Flutter logo', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: GoogleAuthScreen(initializing: true)),
    );

    expect(find.byType(Image), findsNothing);
    expect(find.text('Welcome to Duo'), findsNothing);
    expect(find.byType(BrandSplashScreen), findsOneWidget);
  });
}
