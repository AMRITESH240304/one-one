import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  testWidgets('loading UI appears only after the startup threshold', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DelayedLoadingIndicator(child: Text('loading')),
      ),
    );

    expect(find.text('loading'), findsNothing);
    await tester.pump(startupLoadingThreshold - const Duration(milliseconds: 1));
    expect(find.text('loading'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.text('loading'), findsOneWidget);
  });
}
