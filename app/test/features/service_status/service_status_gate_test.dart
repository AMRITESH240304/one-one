import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/features/service_status/service_status_gate.dart';

void main() {
  test('remote service states are parsed safely', () {
    expect(
      ServiceStatus.fromRemoteValue('maintenance'),
      ServiceStatus.maintenance,
    );
    expect(
      ServiceStatus.fromRemoteValue('country_restricted'),
      ServiceStatus.countryRestricted,
    );
    expect(
      ServiceStatus.fromRemoteValue('slow_network'),
      ServiceStatus.slowNetwork,
    );
    expect(
      ServiceStatus.fromRemoteValue('backend_failure'),
      ServiceStatus.backendFailure,
    );
    expect(
      ServiceStatus.fromRemoteValue('future_unknown_value'),
      ServiceStatus.operational,
    );
  });

  testWidgets('every required service state has user-facing guidance', (
    tester,
  ) async {
    const expectedTitles = {
      ServiceStatus.maintenance: 'Services are currently unavailable.',
      ServiceStatus.countryRestricted:
          'This service is currently unavailable in your country.',
      ServiceStatus.offline: 'No internet connection.',
      ServiceStatus.slowNetwork: 'Network quality is poor.',
      ServiceStatus.backendFailure: "We're experiencing server issues.",
    };

    for (final entry in expectedTitles.entries) {
      await tester.pumpWidget(
        MaterialApp(
          home: ServiceStatusScreen(
            status: entry.key,
            guidance: '',
            updatesUrl: '',
            onRetry: () async {},
            onContinue: entry.key == ServiceStatus.slowNetwork ? () {} : null,
          ),
        ),
      );
      expect(find.text(entry.value), findsOneWidget);
    }
  });
}
