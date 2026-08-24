import 'package:flutter_test/flutter_test.dart';

import 'package:one_one_app/phase1_spike/phase1_spike_app.dart';

import 'package:one_one_app/one_one.dart';

void main() {
  testWidgets('Phase 1 spike screen loads', (WidgetTester tester) async {
    FlutterForegroundTask.initCommunicationPort();

    await tester.pumpWidget(const OneOnePhase1App());
    await tester.pump();

    expect(find.text('Phase 1 Audio Spike'), findsOneWidget);
    expect(find.text('LiveKit URL'), findsOneWidget);
    expect(find.text('Temporary LiveKit token'), findsOneWidget);
    expect(find.text('Go online'), findsOneWidget);
  });
}
