# Android Feature Feasibility

**One One · Technical Feasibility Assessment · Aug 2026**

Two independent assessments: (1) Android home screen widget with voice recording initiation, and (2) real-time vocal avatar voice transformation. Verdicts, constraints, and recommended technical paths only — no implementation code.

---

## Part 1 — Android Home Screen Widget: Mic & Voice Recording

Widget shows the current group name with a Next arrow, a Mic button, and a Ring button. The core question is whether the Mic button can initiate audio capture from the widget context or must launch the app into a recording state.

---

### Q1 — Can an Android App Widget trigger microphone capture without opening the app?

**Verdict: Not Possible**

> **Background mic access is prohibited on Android**
>
> Since Android 9 (API 28), apps cannot access the microphone while in the background unless a foreground service with the explicit microphone type is actively running. App Widgets run in the launcher process and have no foreground service context — direct mic capture from a widget is not possible.

**Widget sandboxing**

Widgets execute in `AppWidgetProvider` context, which is a `BroadcastReceiver`. BroadcastReceivers on Android 8+ (API 26) are subject to background execution limits and cannot start long-running services or access sensors or microphone.

**Android 9+ mic policy**

`RECORD_AUDIO` is restricted to foreground processes — a visible Activity or a foreground service of type microphone. A widget button press fires a `PendingIntent` into a `BroadcastReceiver` context, which does not constitute a foreground context.

**Android 12+ indicator enforcement**

Android 12 added the orange mic indicator dot as both a UX signal and a policy enforcement point. Background mic use without a visible foreground service triggers system suppression on API 31+.

> **Recommended fallback**
>
> Use Option (a): launch the Flutter app into a recording state via a `PendingIntent`. See Q2 for the full intent flow.

---

### Q2 — Can a widget button launch the app directly into a specific recording state?

**Verdict: Possible**

Yes. This is the standard and reliable pattern for widget-to-app deep linking. A widget button creates a `PendingIntent` that fires an Intent with a custom action and extras, which `MainActivity` receives in `onNewIntent()` and routes to the recording UI.

**Intent flow sketch**

Widget button fires `PendingIntent` (`FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE`) with Intent action = `"app.oneone.ACTION_START_VOICE_NUDGE"` and `groupId` extra. `MainActivity.onNewIntent()` receives it, forwards via Dart `MethodChannel`. Flutter opens recording bottom sheet with mic active.

**MainActivity.onNewIntent()**

`MainActivity` must override `onNewIntent()` to forward the intent to Flutter. Set `launchMode=singleTop` in `AndroidManifest` so the existing activity instance receives the intent rather than spawning a new one.

**Mic activation on launch**

Once Flutter receives the `MethodChannel` call, it requests mic permission (if not yet granted) and opens the recording bottom sheet. The mic permission prompt is presented in a foreground Activity context, so it works cleanly.

**Cold start handling**

If the app is not running, the Intent starts the Activity fresh and `onNewIntent()` is not called. Handle the initial intent in `onCreate()` by inspecting `getIntent()`, or in the Flutter engine ready callback.

> **Reliability across Android 12–16**
>
> `PendingIntent`-based widget-to-activity deep linking is reliable across Android 8 through 16. Android 12 requires explicit `FLAG_IMMUTABLE` or `FLAG_MUTABLE` declaration — use `FLAG_IMMUTABLE`. No other version gates beyond this.

---

### Q3 — Flutter-specific concerns: Kotlin-to-Dart bridge for widget actions

**Verdict: Possible with Constraints**

Android widgets must be implemented natively in Kotlin. Widget code cannot directly call Dart. The bridge must go through either a `MethodChannel` or the `home_widget` package — each covers different use cases.

#### home_widget (pub.dev) — Partial fit

Provides SharedPreferences-based data sync from Flutter to widget (ideal for displaying group name), and a `widgetClicked` stream in Dart for receiving widget button taps. Sufficient for Next arrow and Ring button. Does not handle arbitrary Intent extras or custom action routing for the Mic deep link.

#### Custom MethodChannel bridge — Recommended for Mic

Required for the Mic button. `MainActivity.onNewIntent()` fires `MethodChannel.invokeMethod("startVoiceNudge", groupId)` to Dart. Flutter registers a handler that opens the recording sheet. Standard Flutter platform channel usage — no custom plugin required.

**Recommended architecture**

Use `home_widget` for data display (group names, SharedPreferences sync) and a custom `MethodChannel` in `MainActivity` for the Mic deep-link action. The Ring button can use `home_widget`'s `widgetClicked` stream or a separate `BroadcastReceiver` that calls a `MethodChannel` for ring nudge dispatch.

---

### Q4 — LiveKit mic permission in the widget-launched recording context

**Verdict: Possible**

When the widget launches the app via `PendingIntent`, the Flutter Activity is in a foreground context. Mic permission requests and LiveKit's internal mic acquisition both operate normally.

**First launch — permission not granted**

Flutter's `permission_handler` presents the standard Android `RECORD_AUDIO` permission dialog. This works identically to any other in-app permission request because the Activity is foreground. The recording bottom sheet should wait for the permission result before activating the mic.

**Permission already granted**

`LocalAudioTrack.create()` succeeds immediately. The app can activate the mic in the bottom sheet's `initState` or equivalent without any additional prompt.

**LiveKit foreground service**

If the voice nudge recording uses a LiveKit room session requiring a foreground service, ensure it is started from the Activity context after the widget launches — not from the widget's `BroadcastReceiver` context. Starting a foreground service from a `BroadcastReceiver` is restricted on Android 12+.

---

### Android Version Flags — Test Matrix (12 through 16)

| Android Version | Widget / PendingIntent | Mic / Background Policy | LiveKit / FG Service | Risk |
|---|---|---|---|---|
| **Android 12 (API 31–32)** | `FLAG_MUTABLE` / `FLAG_IMMUTABLE` required on all PendingIntents. | Orange mic indicator dot enforced. Background mic blocked. Foreground service type microphone required. | Foreground service type `microphone` must be declared in manifest (enforced from API 30). | Medium |
| **Android 13 (API 33)** | No major widget changes. `POST_NOTIFICATIONS` permission required for FCM nudge delivery. | Same as 12. Notification permission gate affects nudge receipt. | No change to mic foreground service rules. | Low |
| **Android 14 (API 34)** | Pinned widget prompts configurable at install time — UX improvement only. | `SCHEDULE_EXACT_ALARM` now requires explicit declaration. No new mic restrictions. | Foreground service restrictions tightened — must declare foreground service type explicitly in manifest. | Medium |
| **Android 15 (API 35)** | Predictive back gesture may intercept widget-launched activity transitions. Test on Pixel. | No new mic policy beyond Android 14. | Media Projection and FG service audits. Test mic FG service launch from background carefully. | Medium |
| **Android 16 (API 36)** | Pixel adaptive widget refresh. No PendingIntent policy changes. | No confirmed additional mic restrictions at time of writing. Monitor release notes. | Same rules as 35 expected. Monitor for changes. | Low–Unknown |

---

### Implementation sketch — widget intent flow (5 steps)

**1. AppWidgetProvider (Kotlin)**

In `onUpdate()`, build `RemoteViews` and set a `PendingIntent` on the mic button using `PendingIntent.getActivity()` with Intent action = `"app.oneone.ACTION_START_VOICE_NUDGE"` and `groupId` extra. Use `FLAG_UPDATE_CURRENT | FLAG_IMMUTABLE`.

**2. AndroidManifest.xml**

Declare `MainActivity` with `android:launchMode="singleTop"`. Add an intent-filter for the custom action. Declare `uses-permission` for `RECORD_AUDIO` and foreground service type `microphone`.

**3. MainActivity.kt**

Override `onNewIntent()`. Extract the action and `groupId`. Invoke `MethodChannel("app.oneone/widget").invokeMethod("startVoiceNudge", mapOf("groupId" to groupId))`.

**4. Flutter — Dart side**

Register `MethodChannel` handler in `main.dart` or the relevant controller. On `"startVoiceNudge"`, navigate to the recording bottom sheet, request `RECORD_AUDIO` permission if needed via `permission_handler`, then activate the LiveKit mic track.

**5. home_widget (for data display)**

Use `HomeWidget.saveWidgetData()` to write the current group list from Flutter to SharedPreferences. `AppWidgetProvider` reads this to render the group name in the widget UI. Update on every group change event.

---

## Part 2 — Vocal Avatars: Voice Transformation Feasibility

Evaluation of real-time and pre-send voice transformation for a premium One One feature. Covers DSP effects, LiveKit pipeline compatibility, on-device ML, and privacy flags. No implementation code — assessment only.

---

### Q1 — Real-time voice transformation on Android: is it feasible?

**Verdict: Feasible with Constraints**

Real-time DSP-based voice transformation (pitch shift, formant shift, robot effect, reverb) is feasible on Android with native audio libraries. Latency is manageable on mid-range devices for pure DSP. ML-based transformation in real time requires significantly more compute than mid-range devices sustain.

#### Pure DSP transformation

Algorithms: PSOLA (pitch without formant change), phase vocoder (pitch + time stretch), ring modulation (robot), delay lines (reverb/echo). These operate on raw PCM buffers at 30–60 ms added latency on a Snapdragon 600-tier device.

#### Recommended libraries

- **Oboe** (Google) — low-latency Android audio I/O, ideal for real-time processing loop.
- **TarsosDSP** (Java/Android) — pitch detection, WSOLA, PSOLA. Easy Flutter integration via platform channel.
- **Superpowered SDK** — commercial, low-latency, includes pitch and FX DSP chain. Licensed per-app.

**Latency overhead on mid-range device**

Pure DSP: 20–60 ms additional processing per buffer (typically 10–20 ms buffer at 48 kHz). Total end-to-end latency with Oboe: 40–100 ms. Acceptable for voice nudge recording (not a live call). Real-time ML: 200–2000 ms added latency — generally not acceptable for user-facing recording.

---

### Q2 — LiveKit pipeline compatibility — can we inject a custom audio source?

**Verdict: Feasible with Constraints**

LiveKit's Flutter SDK supports custom audio sources, allowing injection of processed PCM frames instead of raw mic input. Integration depth varies by approach.

**LiveKit custom audio track**

Use `LocalAudioTrack.createAudioTrack()` with a custom `AudioSource`. On Android, this internally uses WebRTC's `JavaAudioDeviceModule`. Recommended path: capture audio via `AudioRecord` (Oboe for low latency), apply DSP transforms in a native processing thread, push transformed PCM buffers into LiveKit's audio track via `pushFrame()` or equivalent.

**Flutter SDK entry point**

`livekit_client` exposes `LocalAudioTrack` and `AudioCaptureOptions`. For custom processing, a native (Kotlin) plugin intercepts the raw mic stream, applies transforms, and feeds back audio via a custom `AudioProcessingModule` registered with LiveKit's WebRTC engine at `PeerConnectionFactory` level.

**Complexity assessment**

Integrating at the `AudioProcessingModule` level requires direct WebRTC native configuration, which is non-trivial from Flutter. An alternative: capture audio separately (`AudioRecord` / Oboe), process, feed processed PCM to a LiveKit `CustomAudioSource` — avoids WebRTC internals entirely.

> **Voice nudge path is simpler**
>
> For voice nudges (not live streams), audio does not need to go through LiveKit at all. Record locally, transform, upload to Firebase Storage. See Q3.

---

### Q3 — Pre-send transformation (non-real-time, for voice nudges)

**Verdict: Feasible**

For voice nudges uploaded to Firebase Storage / GCS, transformation can be applied post-record and pre-upload. This is the simplest and most reliable path for an MVP.

**Processing time for a 3–5 second clip**

Pure DSP (pitch shift, formant, reverb): under 200 ms on a mid-range Android device — imperceptible if shown behind a "Sending..." indicator. ML-based (RVC with ONNX): 1–10 seconds per clip on-device. Cloud offload preferred for ML transforms at MVP stage.

**Implementation path**

Record raw PCM via `MediaRecorder` or `AudioRecord` to a temp file. Apply DSP transform (TarsosDSP or native Kotlin/JNI) to produce a transformed WAV/AAC. Encode to target format (Opus/AAC). Upload the transformed file as the voice nudge. No changes needed to the existing upload or playback pipeline.

**User experience**

Show a brief "Applying effect..." state between recording stop and send confirmation. Total added delay for DSP: under 500 ms. For ML cloud processing: 3–8 s with a warm GPU instance — show a loading indicator with progress messaging.

---

### Q4 — Preset voice styles: what is achievable without an AI model?

**Verdict: Feasible**

The following effects are achievable with pure DSP. All are practical for pre-send transformation on voice nudges and can be offered as named presets in the recording UI.

| Effect / Preset | DSP Approach | Library / Method | Time (3–5 s clip) | ML Required |
|---|---|---|---|---|
| Pitch Shift (chipmunk / deep) | PSOLA or phase vocoder | TarsosDSP, Oboe + custom | < 30 ms | No |
| Formant Shift (age / gender) | All-pass filter chain | TarsosDSP | < 40 ms | No |
| Robot / Ring Modulator | Amplitude modulation with carrier sine | Custom PCM processing | < 20 ms | No |
| Reverb / Echo / Space | Convolution reverb or delay line | Oboe + Superpowered | < 30 ms | No |
| Whisper Effect | Spectral subtraction + noise addition | TarsosDSP | < 40 ms | No |
| Alien / Vocoder Effect | LPC analysis + synthesis | Custom native (JNI) | 40–80 ms | No |
| Celebrity Voice Clone | ML — voice style transfer (RVC, XTTS) | RVC v2 / XTTS / ONNX | 5–30 s on-device or cloud | Yes |
| Emotional Style Transfer | ML — prosody model | StyleTTS2 (research) | ~500 ms (cloud GPU) | Yes |

---

### Q5 — On-device ML for celebrity voice impressions (e.g. Trump-style)

**Verdict: Not Feasible On-Device**

> **Not feasible on-device in real time for mid-range hardware**
>
> State-of-the-art voice style transfer models (RVC v2, XTTS, SoundStorm, StyleTTS2) require 2–8 GB RAM and GPU inference. Mid-range Android devices (4–6 GB RAM, no dedicated AI accelerator) cannot run these models in real time. Pre-send on-device for a 3–5 s clip: 5–30 s — unacceptable UX.

**Available open-source models**

RVC (Retrieval-based Voice Conversion): ~200 MB model, requires GPU for real time. XTTS v2 (Coqui): 1.8 GB — not feasible on-device. Koe Recast: commercial API. StyleTTS2: 200 MB research model with quality tradeoff.

**Constrained on-device option**

A heavily quantized ONNX model (INT8) for simple speaker embedding shift may run in 1–3 s for a 3–5 s clip on high-end Android (Snapdragon 8 Gen 2+). Covers basic voice deepening or lightening — not celebrity impressions.

**Recommended path for ML effects**

Cloud inference: upload raw audio, apply RVC / XTTS on a GPU backend (Firebase Cloud Functions or dedicated inference service), download transformed clip. Round-trip for a 5 s clip: approximately 3–8 s with a warm GPU instance. Present as an async premium effect with a wait state.

---

### Q6 — Privacy and legal considerations

**Verdict: Possible with Constraints**

**Voice cloning (general)**

Generating a synthetic voice that sounds like a real person without consent may violate their right of publicity in many jurisdictions (US, EU). Google Play policy prohibits apps that facilitate harassment, which could include voice messages impersonating others.

**Celebrity impressions**

Using a named celebrity's vocal likeness in a commercial product without a license is legally high-risk in the US (Lanham Act, right of publicity) and EU (GDPR personality rights). Even parody has limits in commercial contexts. Legal review required before naming any preset after a real individual.

**Recommended safe approach**

Offer named DSP presets — "Robot", "Deep", "Chipmunk", "Alien" — that are clearly stylistic and do not impersonate real people. Include a disclosure in the recording UI ("Voice effect applied") so recipients know the voice is altered.

**Google Play data safety**

Ensure the app's data safety section discloses audio processing and any cloud upload of voice data. If ML cloud processing is used, update the privacy policy to include audio data handling and retention policies.

---

### Recommended Technical Paths

#### MVP Path — DSP Pre-Send *(Start here)*

Record raw audio via existing pipeline. After the user stops recording, apply a selected DSP preset (pitch shift, robot, deep voice) using TarsosDSP via a Kotlin platform channel. Processing time under 300 ms for a 5 s clip. Upload transformed audio as the voice nudge. No changes to LiveKit or the delivery pipeline.

- No new backend infrastructure
- Works on all Android 8+ devices
- Imperceptible processing delay
- Limited to DSP-only effects

#### Full Version — Cloud ML Transform *(Phase 2)*

Record and upload raw audio to a signed GCS URL. Trigger a Cloud Run / GKE inference job running RVC v2 or a fine-tuned XTTS model. Return the transformed audio URL. Flutter downloads and sends as the nudge. Round-trip: 5–15 s, shown as an "Applying premium effect..." state. Voice model presets are server-side.

- High-quality voice transformation
- Supports stylized voices (with legal care)
- Requires cloud inference infrastructure
- Per-transform GPU compute cost
- Legal review required for named voices

---

### Flutter / LiveKit Integration Flags

**Platform channel overhead**

DSP processing in a Kotlin JNI thread adds no Flutter UI blocking. Use a Kotlin coroutine (`Dispatchers.Default`) for transform, return result via `MethodChannel.Result` on completion. The Flutter UI remains fully responsive.

**LiveKit audio track for real-time effects**

If vocal avatars are added to live voice (future scope), the custom audio source approach requires WebRTC `AudioProcessingModule` integration. This is not exposed by the `livekit_client` Flutter SDK surface and requires a forked or custom native plugin. Factor this into scoping for any live-voice avatar work.

**Audio format compatibility**

TarsosDSP outputs PCM (16-bit, 44.1 kHz by default). Ensure output is re-encoded to the nudge format (Opus/AAC/M4A) before upload, consistent with the existing voice nudge pipeline in `android_voice_nudge_bridge.dart`.

**Battery and thermal**

On-device DSP for pre-send (non-real-time) has negligible battery impact. On-device ML inference for 3–5 s clips may cause brief thermal load on low-end devices. Gate ML features to high-end device tiers if on-device ML is pursued.

---

*One One · Feasibility Assessment · Aug 2026 · Android 12–16*

*Assessment only — no implementation code*
