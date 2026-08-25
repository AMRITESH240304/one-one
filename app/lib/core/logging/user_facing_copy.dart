/// Maps internal diagnostic strings to copy that is safe to show in the UI.
///
/// Worker names (`W1`, `FCM-W2`), channel IDs, and FCM checkpoints belong in
/// Crashlytics / logcat — never in SnackBars, banners, or notifications.
abstract final class UserFacingCopy {
  static const notificationDeliveryFailure =
      'Couldn\u2019t deliver notification. Please check your connection.';

  /// Checkpoint codes such as `FCM-W1`, `FCM-BE-W1`, `DART-W1`, `[FCM-W2]`.
  static final _checkpointCode = RegExp(
    r'\[OneOneFCM\]'
    r'|\b[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)*-[WE]\d+\b'
    r'|\[(?:FCM|DART|NUDGE)[^\]]*\]'
    r'|walkie_alerts(?:_v\d+)?'
    r'|\bvoice_nudges\b',
    caseSensitive: false,
  );

  /// Phrases like "W1 and W2 notification handling".
  static final _workerPhrase = RegExp(
    r'\bW\d+\b(?:\s*(?:and|/|,)\s*\bW\d+\b)*.{0,40}'
    r'(?:notification|handling|worker|checkpoint|FCM)'
    r'|(?:notification|handling|worker|checkpoint|FCM).{0,40}\bW\d+\b',
    caseSensitive: false,
  );

  static bool containsInternalIdentifier(String text) {
    return _checkpointCode.hasMatch(text) || _workerPhrase.hasMatch(text);
  }

  /// Returns [fallback] when [error] contains worker / channel / FCM internals.
  static String sanitize(
    Object error, {
    String fallback = notificationDeliveryFailure,
  }) {
    final text = error.toString().trim();
    if (text.isEmpty || containsInternalIdentifier(text)) return fallback;
    return text;
  }
}

/// Structured Crashlytics `information` lines for FCM handling failures.
abstract final class FcmHandlingContext {
  static const failureReason = 'fcm_notification_handling_failure';

  static List<String> information({
    required String worker,
    String? groupId,
    String? eventId,
    String? kind,
    DateTime? timestamp,
    required bool inBackground,
  }) {
    final time = (timestamp ?? DateTime.now().toUtc())
        .toUtc()
        .toIso8601String();
    return [
      'worker: $worker',
      'groupId: ${groupId?.trim().isNotEmpty == true ? groupId : '-'}',
      'eventId: ${eventId?.trim().isNotEmpty == true ? eventId : '-'}',
      'kind: ${kind?.trim().isNotEmpty == true ? kind : '-'}',
      'timestamp: $time',
      'appState: ${inBackground ? 'background' : 'foreground'}',
    ];
  }
}
