package app.oneone.one_one_app

fun main() {
    check(containsInternalFcmIdentifier("FCM-BE-W1"))
    check(containsInternalFcmIdentifier("[FCM-W1] Ignored data message"))
    check(containsInternalFcmIdentifier("[FCM-W2] unknown type"))
    check(containsInternalFcmIdentifier("W1 and W2 notification handling"))
    check(containsInternalFcmIdentifier("walkie_alerts_v2"))
    check(containsInternalFcmIdentifier("voice_nudges"))
    check(!containsInternalFcmIdentifier(FCM_USER_DELIVERY_FAILURE))
    check(!containsInternalFcmIdentifier("Tap to open this nudge"))

    check(
        sanitizeNotificationCopy(
            "Check the backend FCM-BE-W1 error code.",
            FCM_USER_DELIVERY_FAILURE,
        ) == FCM_USER_DELIVERY_FAILURE,
    )
    check(
        sanitizeNotificationCopy("Come online on Duo", FCM_USER_DELIVERY_FAILURE) ==
            "Come online on Duo",
    )

    val information = fcmHandlingInformation(
        worker = "W1",
        groupId = "group-1",
        eventId = "event-9",
        kind = "voice_nudge",
        inBackground = true,
        timestamp = "2026-08-18T17:20:00Z",
    )
    check(information[0] == "worker: W1")
    check(information[1] == "groupId: group-1")
    check(information[2] == "eventId: event-9")
    check(information[3] == "kind: voice_nudge")
    check(information[4] == "timestamp: 2026-08-18T17:20:00Z")
    check(information[5] == "appState: background")
    check(FCM_HANDLING_FAILURE_REASON == "fcm_notification_handling_failure")
}
