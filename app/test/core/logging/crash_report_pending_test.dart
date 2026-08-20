import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/core/logging/crash_report_pending.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('pending crash report flag can be set and cleared', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await CrashReportPending.isPending(), isFalse);
    await CrashReportPending.markPending();
    expect(await CrashReportPending.isPending(), isTrue);
    await CrashReportPending.clear();
    expect(await CrashReportPending.isPending(), isFalse);
  });
}
