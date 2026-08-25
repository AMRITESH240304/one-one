# Testing Plan for B1–B9 Changes

---

## B1 — VoiceSessionService RECORD_AUDIO Runtime Check

**Risk area:** VoicePip.kt — `VoiceSessionService.start()` and `onStartCommand()`

**Test cases:**
1. **Permission denied (critical path):** On API 34+ device, revoke mic permission in Settings → Apps → One One → Permissions → Microphone → Deny. Trigger a voice session. Service should *not* start, app should *not* crash. Expect a log: `[VOICE-SESSION] Skipping VoiceSessionService start: RECORD_AUDIO permission not granted at runtime.`
2. **Permission granted (happy path):** Grant mic permission. Start voice session. Service starts normally, foreground notification appears.
3. **API 33 and below:** Verify no regression — `Build.VERSION_CODES.UPSIDE_DOWN_CAKE` guard means the check is skipped entirely on older devices.
4. **Permission toggled at runtime:** Grant mic → start session → deny mic (via Settings while session is active) → stop and restart session. Service should refuse to restart.

**⚠️ Most likely break:** The `RECORD_AUDIO` check at `start()` uses `context` which is the caller's context. If the calling `MainActivity` has been destroyed and the context is stale, `ContextCompat.checkSelfPermission` may return unexpected results. Verify this doesn't crash.

---

## B2 — Firebase RTDB Rules for notificationDeliveries

**Risk area:** `realtime-database.rules.json` — changed from `false/false` to sender/recipient-based rules.

**Test cases:**
1. **Receiver writes delivery status:** From receiver's device, write `{"status": "played", "recipientUserId": "receiver123"}` to `/notificationDeliveries/event_abc`. Should succeed (auth.uid matches `recipientUserId`).
2. **Sender reads delivery status:** From sender's device, read `/notificationDeliveries/event_abc` where the node's `senderUserId` matches. Should succeed.
3. **Unauthorized user tries to read:** A third user who is in the group but neither sender nor receiver tries to read `/notificationDeliveries/event_abc`. Should fail with permission-denied.
4. **Unauthorized write attempt:** A malicious client tries to write with `recipientUserId` ≠ auth.uid. Should fail.

**⚠️ Most likely break:** If existing code was writing to `notificationDeliveries` indirectly (e.g., via a Firebase transaction or multi-path update), and that code doesn't set `senderUserId` or `recipientUserId` on the data, the `.read` rule will fail because `data.child(...)` returns null. Test the actual nudge flow end-to-end.

---

## B3 — Crashlytics Nudge Failure Logging

**Risk area:** `VoiceNudgeContract.kt` (new `recordNudgeFailure`), `VoiceNudgePlaybackService.kt`, `VoiceNudgeMessagingService.kt`

**Test cases:**
1. **Simulate playback error:** Send a voice nudge with a corrupted audio URL. The download should fail → `recordNudgeFailure("download_error", ...)` should fire. Check Crashlytics dashboard for a non-fatal event with key `nudge_failure_event = download_error`.
2. **Simulate volume muted:** On receiver device, mute media volume. Send a nudge. The `blockingReason()` returns `receiver_volume_muted` → should log with extras `stream_volume = 0`.
3. **Simulate FCM start failure:** This is harder to test — can try sending a nudge on a device with background restrictions. Check for `permission_denied_foreground_service` or `playback_service_start_error` in Crashlytics.
4. **Verify non-fatal:** None of these log events should crash the app. The `recordException` call uses `RuntimeException(...)` but wrapped in try-catch, so it should never throw.

**⚠️ Most likely break:** `FirebaseCrashlytics.getInstance()` may not be initialized if called too early. But since `VoiceNudgeDiagnostics` is only called from the messaging/playback services (which run after Firebase is initialized by `VoiceNudgeMessagingService`), this should be fine.

---

## B4 — Nudge Vibration Pattern + Hardware Button Interruption

**Risk area:** `VoiceNudgePlaybackService.kt` — `triggerReceiptHaptics()`, `interruptActivePlayback()`, volume receiver.

**Test cases:**
1. **Vibration sequence timing:** Send a ring nudge (3s) or voice nudge. Feel for: two short taps → sustained buzz → two short taps. The total envelope should cover the audio duration.
2. **Very short nudge (< 1s):** The `sustainedMs.coerceAtLeast(400L)` should ensure some buzz even for short nudges.
3. **Volume button during playback:** While a nudge is playing, press volume up or down. Audio should stop immediately, vibration should cancel, notification should change to "Interrupted — tap to re-play ▶️".
4. **Volume button after interruption:** After interruption, press volume again. Should NOT re-interrupt (already stopped).
5. **Receiver not destroyed on service stop:** The `volumeReceiver` is unregistered in `onDestroy()`. Verify no "receiver not registered" exception.
6. **API < O (26):** The `VibrationEffect.createWaveform` path has a fallback to deprecated `vibrator.vibrate(timing, repeat)`.

**⚠️ Most likely break:** The `VOLUME_CHANGED_ACTION` broadcast fires on EVERY volume change system-wide, not just this app. If the user adjusts volume for another reason during nudge playback, the nudge will be interrupted. This is intentional per the spec but could feel aggressive.

**⚠️ Most likely break #2:** The sustained vibration uses index `0` (repeat forever). A `postDelayed` cancels it after `sustainedMs`. If `mainHandler` callbacks are cleared before the postDelayed fires (e.g., in `onDestroy`), the vibration could run indefinitely. The `cancelHaptics()` in `onDestroy` mitigates this.

---

## B5 — Local 10-Minute Nudge Expiry

**Risk area:** `VoiceNudgeMessagingService.kt` (NudgeExpiryTracker, NudgeExpiryReceiver), `MainActivity.kt`, `nudge_screen.dart`

**Test cases:**
1. **Receiver expiry fires:** Send a nudge to a device. Wait 10 minutes without accepting. The receiver should see "Nudge from [Sender] has expired." notification.
2. **Accept cancels expiry:** Send a nudge. Accept it within 10 minutes. No expiry notification should appear.
3. **Decline/Snooze cancels expiry:** Send a nudge. Decline or snooze it. No expiry notification.
4. **Sender expiry fires:** Send a nudge from device A to device B. Close the nudge sheet. Wait 10 minutes without B accepting. Device A should see "Your nudge to [Recipient] was not accepted in time."
5. **Delivery result cancels sender expiry:** Send a ring nudge. When delivery confirmation arrives (played/failed), the sender expiry should be cancelled.
6. **Device reboot:** Send a nudge, then reboot the device. The `AlarmManager` alarm should NOT survive reboot (we use `ELAPSED_REALTIME_WAKEUP`). This is acceptable — the nudge notification remains visible.
7. **Duplicate eventId:** Send two nudges with the same eventId (shouldn't happen in production, but test). The second `scheduleExpiry` should overwrite the first alarm via `FLAG_UPDATE_CURRENT`.

**⚠️ Most likely break:** The `PendingIntent.requestCode = eventId.hashCode()` can collide. If two nudges hash to the same code, one alarm overwrites the other. `FLAG_UPDATE_CURRENT` means the last one wins.

**⚠️ Most likely break #2:** The sender-side expiry depends on the Flutter code calling `scheduleSenderNudgeExpiry` via the platform channel. If the nudge sheet is dismissed before the call completes (e.g., pop before async finishes), the alarm is never scheduled. The `unawaited` call means we don't await it, but if the sheet is popped, the timer is gone.

---

## B6 — LiveKit Auto-Reconnect

**Risk area:** `VoiceNudgeMessagingService.kt` — starts `VoiceSessionService` on accept.

**Test cases:**
1. **Sender foreground:** Sender has app open. Receiver accepts nudge. `NudgeActionDispatcher.signal()` fires → Flutter `_takePendingNudgeAction` → `_processNudgeAction` → `_goOnline()` → LiveKit reconnects.
2. **Sender background (Flutter alive):** Sender app is in recent apps but not focused. Receiver accepts. `signal()` should trigger the same flow. `VoiceSessionService` start keeps the process alive.
3. **Sender killed:** Force-kill sender app. Receiver accepts. `VoiceSessionService` start should show a notification. When sender opens the app (tap notification or launch), `_takePendingNudgeAction` picks up the stored action and reconnects.
4. **Receiver already accepted — sender reconnects correctly:** After reconnect, verify both parties see each other online in LiveKit, voice works both ways.

**⚠️ Most likely break:** `VoiceSessionService.start()` on accept may fail silently if `RECORD_AUDIO` is not granted (B1 check now guards this). If the service fails to start, the only fallback is the notification.

---

## B7 — Ambient Noise Detection

**Risk area:** `VoiceNudgePlaybackService.kt` — `sampleAmbientNoise()`, delivery ack JSON.

**Test cases:**
1. **Loud environment:** Play loud music near receiver device. Send a nudge. Sender should see "🔊 surroundings are loud" in delivery confirmation.
2. **Quiet environment:** In a quiet room. Send a nudge. Sender should see "🔈 quiet surroundings".
3. **Mic permission denied:** Revoke mic permission. Send a nudge. `ContextCompat.checkSelfPermission` returns denied → `sampleAmbientNoise()` returns null → no noise label shown (graceful degradation).
4. **AudioRecord init failure:** On some devices `AudioRecord` may fail to initialize. The try-catch returns null gracefully.
5. **Concurrent mic access:** If nudge plays while B9 noise filter is active on LiveKit, both try to access the mic. The nudge's `AudioRecord` is a separate short-lived session. Verify no crash or audio glitch.

**⚠️ Most likely break:** The RMS thresholds (`800` and `2000`) are estimates. On very sensitive mics, normal conversation might classify as "high"; on insensitive mics, loud music might classify as "low". This needs real-device calibration.

**⚠️ Most likely break #2:** The ambient noise sample runs on the main thread (`sampleAmbientNoise()` is called from `sendPlayedAckOnce` which runs on the main handler). The `AudioRecord.read()` blocks for up to 500ms. This could cause a visible pause in the UI. Consider moving to a background thread.

---

## B8 — Emoji Burst Transport + Clipping

**Risk area:** `chat_message_repository.dart` (send/write emoji), `identity_home_screen.dart` (listen), `chat_bubble_bar.dart` (fade)

**Test cases:**
1. **Emoji appears on remote device:** Two devices in same group, both online. Device A taps ❤️ emoji. Device B should see the ❤️ burst animation with A's name.
2. **Self-burst not duplicated:** Device A taps emoji. A should see ONLY the local burst, not a duplicate from the RTDB listener (filtered by `senderUserId == _session.userId`).
3. **Offline group:** Both offline. Tap emoji. Burst shows locally only — `_isOnline` guard prevents RTDB write.
4. **Rapid taps:** Tap 5 emojis quickly. Cap at 2 concurrent bursts (existing behavior). RTDB should write all 5, but remote should overwrite with latest 2.
5. **Clipping on narrow device:** On a device with ~360dp width, open the emoji row with 10 emojis. Scroll to the end. The last emoji should have a visible fade gradient at the right edge, not a hard clip.
6. **Clipping on wide device:** On a tablet, all 10 emojis should fit without overflow. The fade should NOT appear (no scroll).
7. **Expired bursts cleaned up:** The `expiresAt` is set to 3 seconds after creation. RTDB data should expire (but Firebase doesn't auto-delete). The client ignores expired data via `isExpired`.

**⚠️ Most likely break:** `watchEmojiBursts` uses `onChildAdded` with `limitToLast(3)`. When a subscriber first connects, it receives the last 3 children that were added. If those 3 are from a previous session and are stale, they'll trigger burst animations on connect. The `senderUserId` filter prevents self-replay, but may show other stale bursts.

**⚠️ Most likely break #2:** The RTDB `emojiBursts` node has no cleanup mechanism. After millions of bursts, the node grows unbounded. Need a server-side cleanup (e.g., Firebase Cloud Function triggered on write to delete after 5 seconds).

---

## B9 — LiveKit Noise Cancellation

**Risk area:** `identity_home_screen.dart` — `LiveKitNoiseFilter` integration, `pubspec.yaml` new dependency.

**Test cases:**
1. **Filter active on voice session:** Start a walkie-talkie session. Speak with background noise (fan, keyboard). Remote participant should hear reduced background noise compared to before.
2. **Call mode:** Switch to call mode. Noise filter should remain active (applied once per room connect, not per mic enable/disable).
3. **Filter setup failure:** If `livekit_noise_filter` package is unavailable or `setAudioProcessor` throws, the error is caught and logged non-fatally. Voice session should still work without noise cancellation.
4. **No audio regression:** Verify audio quality (latency, clipping, volume) is identical to before. The filter should not add perceptible latency.
5. **Reconnect after disconnect:** Disconnect and reconnect to LiveKit. Filter should be re-applied on the new connection.
6. **Package resolution:** Run `flutter pub get`. If `livekit_noise_filter` doesn't exist on pub.dev, this will fail at resolution. Verify the package name is correct.

**⚠️ Most likely break:** `livekit_noise_filter` may not exist on pub.dev, or may have a different API than `LiveKitNoiseFilter()` / `setAudioProcessor()`. If the package doesn't exist, the import will fail at build time. If the API differs, `setAudioProcessor` will throw. Both cases are handled with try-catch, so the app won't crash — but the feature won't work.

**⚠️ Most likely break #2:** If the noise filter and ambient noise sampling (B7) both access the microphone simultaneously during nudge playback while a LiveKit session is active, there could be an `AudioRecord` conflict. B7 opens a separate `AudioRecord` for ≤500ms. This may fail if LiveKit holds the mic exclusively. Test with both features active.