# Nudge delivery icon state dictionary (B1)

Definitive mapping of sender-side avatar overlays for ring/voice nudge delivery
outcomes. Icons appear on recipient avatars in the nudge bottom sheet after a
send finalizes (or when the sheet is reopened while the last-send memory is
still fresh, ≤10 minutes).

## Icon meanings

| Icon | Meaning |
|------|---------|
| **Lock** (`LucideIcons.lock`) | Delivery failed because the **recipient’s device/OS** blocked it |
| **Skull** (`💀`) | Delivery failed for a **Duo-side** or **unknown** reason |
| *(no overlay)* | Delivery succeeded (`played`), or badges not shown yet |

Corner badges (volume / decline / snooze) are separate and never replace
lock/skull — they only appear when delivery did **not** fail.

## State key → icon

State key is derived from the delivery result for that recipient:

`status` + `failureSource` (+ optional `attention` / reply).

| State key | Condition | Icon / badge |
|-----------|-----------|--------------|
| `played.ok` | `status=played`, no attention, no reply | No overlay; green volume badge on voice only |
| `played.volume_low` | `status=played`, `attention=volume_low` | No overlay; low-volume corner badge (voice) |
| `played.volume_very_low` | `status=played`, `attention=volume_very_low` | No overlay; very-low volume badge (voice) |
| `played.volume_muted` | `status=played`, `attention=volume_muted` | No overlay; muted volume badge (voice) |
| `played.declined` | Delivered, recipient declined | No overlay; decline (moon) badge |
| `played.snoozed` | Delivered, recipient snoozed | No overlay; snooze (timer) badge |
| `failed.receiver_device` | `status=failed` and reason ∈ receiver-device set | **Lock** |
| `failed.duo` | `status=failed` and reason is Duo-side (`playback_error`, `download_error`, …) | **Skull** |
| `failed.unknown` | `status=failed` and reason missing / unrecognized | **Skull** |
| `waiting` | Send accepted; awaiting ack (timeout window 12s) | No lock/skull yet |
| `push.received` | Push/notify posted on the recipient device (`status=played`) | No overlay; confirmation text “received” |
| `push.failed.receiver_device` | Push/notify never posted (permissions / timeout) | **Lock** |

## Receiver-device reasons → lock

Canonical reasons classified as `failureSource=receiver_device` (lock):

- `permission_denied_foreground_service` (normalized → `background_fg_service_blocked`)
- `background_fg_service_blocked`
- `permission_denied_notifications`
- `permission_denied_microphone`
- `fcm_not_delivered`
- `app_force_stopped`
- `battery_optimization_active`
- `timeout` (sender-side 12s no-ack synthesis)

## Duo-side reasons → skull

- `playback_error` (includes normalized `playback_service_start_error`)
- `download_error` / `download_failed` (canonical form is `download_failed`)
- Any other failed reason not in the receiver-device set → `unknown` → skull

## Persistence / reopen contract

On finalize, each recipient is snapshotted into `NudgeStatusMemory` as:

- `failed`
- `deviceBlocked` (`isReceiverDeviceBlocked`)
- `failureReason` (raw/canonical reason string)

On sheet reopen, results are rebuilt from that snapshot so **lock vs skull cannot
flip** unless a new delivery result (or response) actually changes state.

### Bug fixed (Aug 2026)

Finalize previously called `_isDeviceLockedFailure` while `_showDeliveryBadges`
was still `false`, so every snapshot stored `deviceBlocked=false`. Live UI still
showed lock from in-memory results; reopen restored skull. Snapshot now reads
`NudgeDeliveryResult` directly and persists `failureReason`.

## Code anchors

- Render: `app/lib/features/nudges/ui/nudge_screen.dart` → `_buildFriendAvatar`
- Classification: `app/lib/features/nudges/data/android_voice_nudge_bridge.dart` → `NudgeDeliveryResult.failureSource`
- Memory: `app/lib/features/nudges/nudge_status_memory.dart` → `LastNudgeRecipientSignifier`
