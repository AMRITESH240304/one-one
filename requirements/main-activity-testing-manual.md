# Android testing manual

## Automated checks run

```sh
cd app
flutter analyze
flutter test test/features/identity/app_user_profile_test.dart test/app/startup_performance_test.dart

cd ../backend
npm run check
```

The Flutter analyzer has no errors or warnings from this change; it reports 15 pre-existing informational `use_null_aware_elements` notices in Firebase telemetry/analytics files. The targeted Flutter tests and backend TypeScript check pass.

`./gradlew :app:compileDebugKotlin` could not run in this workspace because the installed JDK reports `26.0.1`, which this Gradle/Android toolchain rejects before Kotlin compilation. Run that command with the project's supported JDK (typically 17 or 21) before release.

## Device checks

1. Cold start on a physical Android device. The logo should rise once while fading in over about 600 ms, with no mid-animation reversal or snap.
2. Tap and hold Continue with Google. It should shrink immediately, restore on release, open the native picker, then show the three-dot loader; it must not return to the welcome screen after successful account selection.
3. Use a new account. Deny microphone access: the first onboarding step remains and shows the required-permission snackbar. Grant it; deny notification and background access if desired, then verify Home opens. Relaunch: onboarding must not recur for that user on this device.
4. Complete profile setup. Select avatars from both sets, then verify the selected avatar appears in Settings. In Settings, replace it with a custom photo and verify the Cloudinary upload still works.
5. Use an account with no groups. Verify Create Group and Join with PIN work. Tap Share, bell, hand, and keyboard controls: each should show “Join or create a group first.”
6. Use a group with at least one friend. Verify the bell/hand/keyboard/call controls appear in the dark rounded action bar and the push-to-talk pulse is unchanged.
7. Log out, then press Android Back. No stale Home/Settings route should reappear; the root Google auth screen should be shown. Repeat for account deletion with a disposable account.
8. Capture a cold-start System Trace on a low/mid-tier Android device, then compare launch and first Home frame with the released `1.0.2+2` build.

## Not tested in this change

Invite-link caching, deletion cleanup, and the invite-join loader were deferred pending regression investigation.
