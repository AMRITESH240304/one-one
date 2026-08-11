# MainActivity performance and flow summary

Date: 2026-08-02

Implemented for Android:

- A single 600 ms `easeOutCubic` logo entrance drives opacity and vertical movement together.
- Google sign-in has immediate ink feedback and a 0.96 press scale. Auth state routes directly into the three-dot loading gate.
- The one-time onboarding requests mic, notification, and Android background activity in sequence. Mic denial keeps the user on the first step with an explanatory snackbar.
- Profile setup uses bundled avatars from both existing avatar folders. The chosen asset path is stored in RTDB; Cloudinary is used only from Settings after login.
- The no-group view has Create Group, Join with PIN, an invite prompt, and visibly disabled voice controls that explain the prerequisite when tapped.
- The bell, hand, keyboard, and call controls now sit in a themed pill action bar above the existing pulsing push-to-talk control.
- Logout and account deletion replace the navigation stack with a new root auth gate.
- Startup removes the awaited member-photo precache, defers optional telemetry initialization, and limits the native Firebase configuration scan to debug builds.

Deferred:

- Invite-link caching, server cleanup, and invite-join loading UX were explicitly deferred for regression investigation.
