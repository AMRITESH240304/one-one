# Firebase Setup

Phase 3 uses Firebase Authentication, Realtime Database, and Cloud Messaging.
Phase 4/5 add group reads and own-session availability writes.

## Android Config

Place the Firebase Android config file here before building the app:

```txt
app/android/app/google-services.json
```

Use Android package name:

```txt
app.oneone.one_one_app
```

## Realtime Database Rules

Phase 3 rules are in:

```txt
firebase/realtime-database.rules.json
```

They allow each authenticated user to read/write:

- `/users/{ownUserId}`
- `/userDevices/{ownUserId}`
- `/userSettings/{ownUserId}`
- `/memberAvailability/{groupId}/{ownUserId}`
- `/handRaises/{groupId}/{ownUserId}`
- own `/appServiceSessions/{sessionId}`
- own `/livekitSessions/{sessionId}`
- own talk lock/session/status paths while actively in the group

Group, member, availability, talk, and notification reads require active
membership. Other users' profile data is returned by the authenticated group
member API rather than read directly. Group/member/invite/index writes are
backend-owned. `/userGroups/{ownUserId}` is the server-written real-time
membership index used by every signed-in device.

## Service Status Remote Config

Deploy `firebase/remote-config.template.json`, then set `service_status` to one
of `operational`, `maintenance`, `country_restricted`, `slow_network`, or
`backend_failure`. Use Remote Config country conditions for regional rollout.
Set `service_status_updates_url` to the production Reddit page before enabling
maintenance mode.
