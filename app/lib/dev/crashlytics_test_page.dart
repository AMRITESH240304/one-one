import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';

import '../core/firebase/crashlytics_service.dart';

/// Temporary debug screen for verifying Crashlytics end-to-end.
///
/// Remove or hide this once release verification is complete.
class CrashlyticsTestPage extends StatefulWidget {
  const CrashlyticsTestPage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const CrashlyticsTestPage(),
      ),
    );
  }

  @override
  State<CrashlyticsTestPage> createState() => _CrashlyticsTestPageState();
}

class _CrashlyticsTestPageState extends State<CrashlyticsTestPage> {
  String? _status;

  void _setStatus(String message) {
    debugPrint('[CrashlyticsTest] $message');
    if (!mounted) return;
    setState(() => _status = message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _testNativeCrash() async {
    await CrashlyticsService.log('test_native_crash_button');
    _setStatus('Native crash triggered — app will terminate');
    CrashlyticsService.crash();
  }

  Future<void> _testDartException() async {
    await CrashlyticsService.log('test_dart_exception_button');
    try {
      throw Exception('Manual test exception');
    } catch (error, stack) {
      await CrashlyticsService.recordFatalError(
        error,
        stack,
        reason: 'manual_dart_exception',
      );
      _setStatus('Dart exception recorded as fatal');
    }
  }

  Future<void> _testAsyncException() async {
    await CrashlyticsService.log('test_async_exception_button');
    // Intentionally unawaited so Zone / PlatformDispatcher can observe it.
    Future<void>.delayed(Duration.zero, () {
      throw Exception('Manual async test exception');
    });
    _setStatus('Async exception scheduled');
  }

  Future<void> _testHandledException() async {
    await CrashlyticsService.log('test_handled_exception_button');
    try {
      throw Exception('Manual handled test exception');
    } catch (error, stack) {
      await CrashlyticsService.recordError(
        error,
        stack,
        reason: 'manual_handled_exception',
      );
      _setStatus('Handled (non-fatal) exception recorded');
    }
  }

  Future<void> _testLogs() async {
    await CrashlyticsService.log('test_log_one');
    await CrashlyticsService.log('test_log_two');
    await CrashlyticsService.log('test_log_three');
    _setStatus('Wrote 3 Crashlytics breadcrumb logs');
  }

  Future<void> _testCustomKeys() async {
    await CrashlyticsService.setCustomKeys({
      'test_screen': 'CrashlyticsTestPage',
      'test_build': 'debug',
      'test_feature': 'crashlytics_verification',
      'test_count': 3,
    });
    _setStatus('Custom keys set');
  }

  Future<void> _testUserId() async {
    await CrashlyticsService.setUserIdentifier('crashlytics-test-user');
    _setStatus('User ID set to crashlytics-test-user');
  }

  @override
  Widget build(BuildContext context) {
    final collectionEnabled =
        FirebaseCrashlytics.instance.isCrashlyticsCollectionEnabled;

    return Scaffold(
      backgroundColor: const Color(0xff101010),
      appBar: AppBar(
        backgroundColor: const Color(0xff101010),
        foregroundColor: Colors.white,
        title: const Text('Crashlytics Test'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Collection enabled: $collectionEnabled',
            style: const TextStyle(color: Colors.white70),
          ),
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(
              _status!,
              style: const TextStyle(color: Color(0xffF8BE03)),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _testNativeCrash,
            child: const Text('1. Test Native Crash'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _testDartException,
            child: const Text('2. Test Dart Exception'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _testAsyncException,
            child: const Text('3. Test Async Exception'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _testHandledException,
            child: const Text('4. Test Handled Exception'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _testLogs,
            child: const Text('5. Test Logs'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _testCustomKeys,
            child: const Text('6. Test Custom Keys'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _testUserId,
            child: const Text('7. Test User ID'),
          ),
          const SizedBox(height: 24),
          const Text(
            'After a native crash, reopen the app and wait 2–10 minutes. '
            'Reports only upload on the next launch.',
            style: TextStyle(color: Colors.white54, height: 1.4),
          ),
        ],
      ),
    );
  }
}
