# MainActivity performance RCA

## Observed regression

Firebase Performance reported 2.44% frozen frames and 95.12% slow frames for `MainActivity` in Android version `1.0.2+2` during Jul 27–Aug 2. The spike began around Jul 31/Aug 1.

## Most likely contributors

1. The startup gate awaited `precacheImage` for every selected group-member photo before it showed Home. Image fetch/decode and cache pressure occur on the rendering path, making this a high-confidence source of slow or frozen startup frames.
2. `main()` awaited Crashlytics, Analytics, and Performance plugin initialization before `runApp`. These services are useful but not required for the first interactive frame.
3. `MainActivity.configureFlutterEngine()` synchronously performed diagnostic package-manager, signing-certificate SHA-1, and Google Play Services lookup work in every release launch. That work belongs only in debug diagnostics.

## Fixes

- Home renders without waiting for photo precaching; images load through their normal cached image widgets.
- Optional telemetry begins after `runApp`; Firebase initialization remains blocking because authentication needs it.
- Native Firebase runtime diagnostics now run only in debug builds.

## Verification required after release

Compare the next release against `1.0.2+2` in Firebase Performance after enough production samples. Target: restore frozen frames toward the previous ~0% baseline and materially reduce slow rendering. Use a physical low/mid-tier Android device and an Android Studio System Trace to confirm there is no long main-thread work during cold start.

This is a code-path RCA, not proof of the production spike's single cause; Firebase's aggregated trace does not identify a specific method without a captured device trace.
