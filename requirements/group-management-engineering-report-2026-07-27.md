# Group Management Engineering Report

Date: 2026-07-27

Validation scope: code-path review only. Per project instruction, no Dart, Java,
Flutter, build, analyzer, test runner, or simulator was executed. A focused
backend permission check was generated but not run.

## 1. Feature Summary

### Group management

- Added one dedicated **Group Management** destination inside Settings for the
  currently viewed group.
- The owner sees active members, per-member removal, Invite Members, and Delete
  Group. A regular member sees active members, Invite Members, and Leave Group.
- Owner-only controls are not built for regular members. The backend still
  validates every action because hidden UI is not an authorization boundary.
- Owners cannot leave. The current product decision is to require group
  deletion; ownership transfer is documented as a future enhancement.

### Membership lifecycle

- Added authenticated endpoints for list groups, remove member, leave group,
  list members, and delete group.
- Added `/userGroups/{userId}/{groupId}` as the real-time membership index.
  Every signed-in device watches the current user's index, so removal, leaving,
  and deletion refresh all devices immediately.
- Removing or leaving marks the historical membership inactive, removes the
  user-group index, clears presence/hand raises/daily usage, closes talk state,
  stops service sessions, revokes token issuances, and removes the participant
  from LiveKit.
- Group deletion first locks the group in `deleting`, terminates LiveKit, then
  performs one atomic multi-path database deletion for group-owned data.

### Invite flow

- Existing HTTPS App Links, custom-scheme fallback, onboarding deferral, and
  authenticated join flow remain the user-facing path.
- Invite codes remain hashed at rest. A new hash-to-invite index removes the
  previous full invite-table scan; legacy invites are backfilled on first use.
- Invite use is reserved transactionally. Membership capacity is also checked
  in a transaction, and a failed/duplicate concurrent join releases its invite
  reservation.
- Duplicate active membership returns success without consuming another use.
  Expired, revoked, exhausted, invalid, full-group, and inactive-group cases
  return stable API errors already handled by the client.

### Notification and voice cleanup

- Removal and deletion send Android data notifications to all affected active
  devices.
- Lifecycle messages cancel notifications belonging to that group and stop
  queued/active native nudge playback for that group.
- Active LiveKit participant identities are evicted with a revocation timestamp.
  Group deletion removes all current participants and deletes the room.

## 2. Root Cause Analysis (RCA)

### Role-aware group management

| Item | Finding |
|---|---|
| Existing limitation | Group settings had no central lifecycle screen or role-specific controls. |
| Root cause | Group ownership existed in data, but no shared management workflow consumed it. |
| User impact | Owners could not administer groups and members could not leave predictably. |
| Resolution | Added one dedicated screen driven by `ownerUserId`, backed by authenticated endpoints. |
| Prevention | Keep group lifecycle actions in this screen and enforce the same matrix in the backend. |

### Member removal

| Item | Finding |
|---|---|
| Existing limitation | There was no owner-authorized removal operation or cleanup contract. |
| Root cause | Membership was created by the invite flow but had no reverse lifecycle service. |
| User impact | Removed access, presence, voice, and notifications could not be synchronized. |
| Resolution | Added an idempotent member-state transaction plus shared member cleanup and LiveKit eviction. |
| Prevention | All removal callers route through `removeGroupMember`; direct membership writes remain denied. |

### Leave group

| Item | Finding |
|---|---|
| Existing limitation | Regular members depended on the owner because no leave endpoint existed. |
| Root cause | The database modeled membership creation only. |
| User impact | Users could not immediately end access, voice, presence, or group notifications. |
| Resolution | Added a self-only authenticated leave endpoint using the token UID and shared cleanup. |
| Prevention | The endpoint ignores client-supplied user IDs and is idempotent across devices. |

### Group deletion

| Item | Finding |
|---|---|
| Existing limitation | No owner-only deletion or cascade existed. |
| Root cause | Group data spans nested and flat collections without a lifecycle coordinator. |
| User impact | A partial deletion could leave invites, sessions, notifications, or LiveKit state active. |
| Resolution | Added an owner-validated `deleting` lock, LiveKit termination, and atomic database cascade. |
| Prevention | Failed preparation restores `groupState` to `active`; retry is safe before the atomic cascade commits. |

### Invite reliability

| Item | Finding |
|---|---|
| Existing limitation | Invite lookup scanned every invite, and use-count updates could race. |
| Root cause | There was no lookup index or transactional reservation. |
| User impact | Scale degraded linearly and simultaneous joins could over-consume a link. |
| Resolution | Added a hashed lookup index, transactional use reservation, atomic capacity check, and duplicate rollback. |
| Prevention | Raw codes are never stored, and all join decisions remain server-side. |

### Permission consistency

| Item | Finding |
|---|---|
| Existing limitation | Several real-time paths were readable by any authenticated user; session and talk writes were too broad. |
| Root cause | Early bootstrap rules treated authentication as equivalent to group membership. |
| User impact | A modified client could observe unrelated group state or attempt hidden actions. |
| Resolution | Reads now require active membership; writes require the authenticated user, matching ownership fields, and active membership. |
| Prevention | Membership mutations stay server-only and the generated owner check requires both group ownership and member role to agree. |

## 3. Security & Permission Validation

### Client-side checks

- The UI uses the group owner's UID to select the owner or member layout.
- Owner-only removal buttons are omitted for members and for the owner row.
- Leave is omitted for owners; delete is omitted for members.
- All destructive actions require explicit confirmation and remain disabled
  while a request is in progress.

### Server-side authorization

- Firebase ID-token middleware supplies the acting UID. Mutation request bodies
  cannot choose another actor.
- Remove and delete require both `groups.ownerUserId == auth.uid` and an active
  membership with role `owner`.
- Leave always targets `auth.uid`; an owner receives
  `owner_must_delete_group`.
- Invite creation requires active membership, while join validates the hashed
  code, group state, expiry, revocation, remaining uses, and capacity.

### Data-integrity safeguards

- Member removal, leave, group deletion lock, invite reservation, and capacity
  admission use database transactions where concurrent decisions matter.
- Removal and leave cleanup are idempotent, so interrupted calls can be retried.
- Group cascade deletion is a single multi-path update after preparation.
- A short per-group operation lease prevents invite creation/join from racing
  deletion and recreating group data after the cascade.
- `/userGroups` is server-written and user-readable only. It is the real-time
  source for cross-device membership changes.
- Existing accounts are backfilled once using
  `/userGroupIndexVersion/{userId}`; subsequent reads use the inverse index.

### Protection from alternate entry points

- Realtime Database rules deny all direct writes to groups, memberships,
  invites, invite indexes, and user-group indexes.
- Group/member/availability/talk/notification reads require active membership.
- Other users' profile records are no longer directly readable. The
  authenticated member-list endpoint returns only profiles for a shared group.
- Session, presence, hand raise, talk, status, and daily-usage writes must match
  the authenticated user and an active membership.
- Deep links can request an invite join only; they cannot invoke owner actions.

## 4. Edge Case Testing

These are generated code-path results, not executed runtime results.

| Scenario | Generated handling | Review result |
|---|---|---|
| Member removed during an active call | Membership becomes inactive, user index and presence are removed, talk/session state is closed, LiveKit identity is removed with token revocation, and every device refreshes. | Covered by one shared cleanup path. |
| Owner deletes an active group | Group enters `deleting`, participants are revoked, room is deleted, group data/invites/sessions/notifications/media are cascaded, then members are notified. | Concurrent delete receives `group_not_active`; failed preparation restores `active`. |
| Member leaves while offline | No optimistic destructive write occurs. The request fails visibly and membership remains authoritative until the user reconnects and retries. | Fails closed; no split-brain offline state. |
| Concurrent updates from multiple devices | Removal and invite admission are transactional; removal/leave cleanup is idempotent; `/userGroups` updates all devices. | Duplicate remove/leave cannot restore access or consume extra invite uses. |
| Invalid or expired invite | Hash index lookup rejects unknown hashes; expiry, revocation, maximum uses, group state, and capacity are validated on the server. | Client clears terminal links and shows the backend message. |

Additional reviewed cases:

- Removing the last regular member leaves the owner as the sole active member.
  The owner cannot remove themselves.
- A removed or leaving user loses notification eligibility immediately because
  recipient collection reads active memberships only.
- A second device leaving after the first receives idempotent success and is
  refreshed by the same user-group index.
- A deleted group's invite index and legacy invite rows are removed together.

## 5. Risk Assessment

- **LiveKit cached-token window:** active participant tokens are revoked during
  eviction, and the backend refuses future issuance. A token issued to a device
  that never connected cannot be centrally found in an active room; its
  remaining JWT lifetime is the residual platform risk.
- **Best-effort push:** database membership updates are authoritative. FCM
  delivery can fail or be delayed, so clients also rely on `/userGroups`.
- **Legacy Android versions:** before Android 6, group-specific active
  notification enumeration is unavailable, so lifecycle cleanup falls back to
  clearing One One notifications.
- **Offline leave:** deliberately not queued. A secure queued command would need
  durable local state, retry UX, and conflict rules; the current implementation
  preserves server truth and asks the user to retry online.
- **Deployment order:** backend and app should deploy before the stricter
  database rules, otherwise old clients that scan all memberships will lose
  their group-list read.
- **Operation lease ceiling:** group invite/join operations use a 60-second
  crash-safe lease. If a legitimate mutation ever exceeds that duration, the
  lease should become renewable.

## 6. Future Recommendations

| Priority | Enhancement | Effort | Reason |
|---|---|---:|---|
| High | Ownership transfer | Medium | Lets an owner leave without deleting a healthy group. |
| High | Short-lived renewable LiveKit tokens | Medium | Narrows the residual cached-token window while preserving long sessions. |
| Medium | Admin/moderator roles | Medium | Supports larger groups without transferring full ownership. |
| Medium | Immutable administrative audit log | Medium | Preserves who removed, left, invited, or deleted after operational data is cleaned. |
| Medium | Invite approval and revocation UI | Medium | Gives owners visibility and control over outstanding links. |
| Low | Configurable group limits/moderation tools | Large | Add only when real group size or abuse metrics justify the complexity. |

## Implemented Flow

```text
Group Management UI
        |
        v
Firebase-authenticated API
        |
        +--> role + membership validation
        |
        +--> transaction / deletion lock
        |
        +--> presence + talk + session + LiveKit cleanup
        |
        +--> /userGroups real-time update
                    |
                    v
             every signed-in device refreshes
```
