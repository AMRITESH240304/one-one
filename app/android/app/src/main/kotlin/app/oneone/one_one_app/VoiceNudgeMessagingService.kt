package app.oneone.one_one_app

import android.content.Intent
import android.os.Build
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

class VoiceNudgeMessagingService : FirebaseMessagingService() {
    override fun onRegistered(installationId: String) {
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[FCM-06] onRegistered callback " +
                VoiceNudgeDiagnostics.describeIdentifier(installationId),
        )
        VoiceNudgeTokenStore.save(this, installationId)
        NudgeActionDispatcher.signalRegistrationRenewed()
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[FCM-07] Message received id=${message.messageId ?: "none"} " +
                "keys=${data.keys.sorted().joinToString(",")}",
        )
        val kind = data["type"]
        if (kind == null) {
            if (message.notification != null) {
                Log.w(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-W1] Legacy notification has no type; displaying foreground fallback",
                )
                showForegroundNotification(message, "legacy_notification")
                return
            }
            Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W1] Ignored data message without type")
            return
        }
        when (kind) {
            "group_removed",
            "group_deleted" -> {
                showGroupLifecycleNotification(message)
                return
            }
            VoiceNudgeContract.kindGoneOffline -> {
                showGoneOfflineNotification(message)
                return
            }
            VoiceNudgeContract.kindPush -> {
                showActionableNotification(message)
                return
            }
            VoiceNudgeContract.kindFriendLive -> {
                showForegroundNotification(message, kind)
                return
            }
            VoiceNudgeContract.kindResponse -> {
                showNudgeResponse(message)
                return
            }
            VoiceNudgeContract.kindDeliveryResult -> {
                forwardDeliveryResult(message)
                return
            }
            VoiceNudgeContract.kindVoice,
            VoiceNudgeContract.kindRing -> Unit
            else -> {
                Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W2] Ignored unknown message type=$kind")
                return
            }
        }

        val eventId = data["eventId"]
        if (eventId == null) {
            Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W3] Ignored $kind without eventId")
            return
        }
        val groupId = data["groupId"]?.takeIf { it.isNotBlank() }
        if (groupId == null) {
            Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W10] Ignored $kind without groupId")
            return
        }
        val senderName = data["senderName"]?.take(80).orEmpty().ifBlank { "Someone" }
        val senderPhotoUrl = data["senderPhotoUrl"]?.takeIf { it.isNotBlank() }
        val durationMs = data["durationMs"]?.toLongOrNull()?.coerceIn(250L, 10_000L)
        if (durationMs == null) {
            Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W4] Ignored $kind with invalid duration")
            return
        }
        if (kind == VoiceNudgeContract.kindVoice && isExpired(data["expiresAt"])) {
            Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W5] Ignored expired voice nudge")
            return
        }

        val intent = Intent(this, VoiceNudgePlaybackService::class.java).apply {
            putExtra(VoiceNudgeContract.extraKind, kind)
            putExtra(VoiceNudgeContract.extraEventId, eventId)
            putExtra(VoiceNudgeContract.extraSenderName, senderName)
            putExtra(VoiceNudgeContract.extraSenderPhotoUrl, senderPhotoUrl)
            putExtra(VoiceNudgeContract.extraDurationMs, durationMs)
            putExtra(VoiceNudgeContract.extraAudioUrl, data["audioUrl"])
            putExtra(VoiceNudgeContract.extraAckUrl, data["ackUrl"])
            putExtra(VoiceNudgeContract.extraDeliveryToken, data["deliveryToken"])
            putExtra(VoiceNudgeContract.extraGroupId, groupId)
            putExtra(VoiceNudgeContract.extraResponseUrl, data["responseUrl"])
        }

        try {
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-09] Starting native playback kind=$kind eventSuffix=${eventId.takeLast(6)}",
            )
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (error: RuntimeException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E3] Native playback start", error)
            val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
            val largeIcon = NotificationAvatarHelper.largeIcon(this, data["senderPhotoUrl"], senderName)
            manager.notify(
                VoiceNudgeNotifications.idFor(eventId),
                VoiceNudgeNotifications.build(
                    this,
                    eventId,
                    groupId,
                    data["responseUrl"],
                    senderName,
                    "Tap to open this nudge 👋",
                    ongoing = false,
                    largeIcon = largeIcon,
                ),
            )
        }
    }

    override fun onDeletedMessages() {
        Log.w(
            VoiceNudgeDiagnostics.tag,
            "[FCM-W7] FCM deleted pending messages before delivery",
        )
    }

    private fun showGroupLifecycleNotification(message: RemoteMessage) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        val groupId = message.data["groupId"] ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            manager.activeNotifications
                .filter { it.notification.group == VoiceNudgeNotifications.groupKey(groupId) }
                .forEach { manager.cancel(it.id) }
        } else {
            manager.cancelAll()
        }
        try {
            startService(
                Intent(this, VoiceNudgePlaybackService::class.java).apply {
                    action = VoiceNudgeContract.actionStopGroupNudges
                    putExtra(VoiceNudgeContract.extraGroupId, groupId)
                },
            )
        } catch (error: RuntimeException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E11] Group nudge cleanup", error)
        }
        try {
            manager.notify(
                VoiceNudgeNotifications.idFor(message.messageId ?: "group_lifecycle"),
                VoiceNudgeNotifications.buildGeneral(
                    this,
                    message.data["title"] ?: "👥 Group updated",
                    message.data["body"] ?: "Your group membership changed.",
                    groupId,
                ),
            )
        } catch (error: SecurityException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
        }
    }

    private fun showGoneOfflineNotification(message: RemoteMessage) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        val groupId = message.data["groupId"]
        try {
            manager.notify(
                VoiceNudgeNotifications.idFor(
                    message.messageId ?: "gone_offline_${message.sentTime}",
                ),
                VoiceNudgeNotifications.buildGeneral(
                    this,
                    message.data["title"] ?: "😴 You're offline",
                    message.data["body"] ?: "You are now offline.",
                    groupId,
                ),
            )
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-08] Gone-offline notification displayed reason=${message.data["reason"]}",
            )
        } catch (error: SecurityException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
        }
    }

    private fun showForegroundNotification(message: RemoteMessage, kind: String) {
        val senderName = message.data["senderName"]?.take(80).orEmpty().ifBlank { "Someone" }
        val fallbackTitle = if (kind == VoiceNudgeContract.kindFriendLive) {
            "🟢 $senderName is live"
        } else {
            "👋 $senderName nudged you"
        }
        val fallbackBody = if (kind == VoiceNudgeContract.kindFriendLive) {
            "Tap to open One One 🎙️"
        } else {
            "Come online on One One ✨"
        }
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        val notificationKey = message.messageId ?: "${kind}_${message.sentTime}"
        try {
            manager.notify(
                VoiceNudgeNotifications.idFor(notificationKey),
                VoiceNudgeNotifications.buildGeneral(
                    this,
                    message.notification?.title ?: fallbackTitle,
                    message.notification?.body ?: fallbackBody,
                    message.data["groupId"],
                ),
            )
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-08] Foreground notification displayed type=$kind",
            )
        } catch (error: SecurityException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
        }
    }

    private fun showActionableNotification(message: RemoteMessage) {
        val data = message.data
        val eventId = data["eventId"] ?: run {
            Log.w(
                VoiceNudgeDiagnostics.tag,
                "[FCM-W8] Legacy Push has no eventId; displaying non-actionable fallback",
            )
            showForegroundNotification(message, VoiceNudgeContract.kindPush)
            return
        }
        val groupId = data["groupId"] ?: run {
            Log.w(
                VoiceNudgeDiagnostics.tag,
                "[FCM-W9] Legacy Push has no groupId; displaying non-actionable fallback",
            )
            showForegroundNotification(message, VoiceNudgeContract.kindPush)
            return
        }
        val senderName = data["senderName"]?.take(80).orEmpty().ifBlank { "Someone" }
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        val notificationsEnabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            manager.areNotificationsEnabled()
        } else {
            true
        }
        val channelImportance = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.getNotificationChannel(
                VoiceNudgeContract.generalNotificationChannelId,
            )?.importance
        } else {
            null
        }
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[FCM-08A] Foreground display readiness " +
                "notificationsEnabled=$notificationsEnabled " +
                "channel=${VoiceNudgeContract.generalNotificationChannelId} " +
                "importance=${channelImportance ?: "legacy"}",
        )
        try {
            val largeIcon = NotificationAvatarHelper.largeIcon(
                this,
                data["senderPhotoUrl"],
                senderName,
            )
            manager.notify(
                VoiceNudgeNotifications.idFor(eventId),
                VoiceNudgeNotifications.buildActionable(
                    this,
                    eventId,
                    groupId,
                    data["responseUrl"],
                    senderName,
                    "👋 $senderName nudged you",
                    "Accept, snooze, or decline ✨",
                    largeIcon = largeIcon,
                ),
            )
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-08] Actionable push notification displayed",
            )
        } catch (error: SecurityException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
        }
    }

    private fun showNudgeResponse(message: RemoteMessage) {
        val data = message.data
        val eventId = data["eventId"] ?: return
        val groupId = data["groupId"] ?: return
        val responseAction = data["responseAction"] ?: return
        val snoozeMinutes = data["snoozeMinutes"]?.toIntOrNull()
        val responderName = data["responderName"]?.take(80).orEmpty().ifBlank { "Your friend" }
        if (responseAction == "accept") {
            NudgeActionStore.save(
                this,
                PendingNudgeAction("connect", eventId, groupId),
            )
            NudgeActionDispatcher.signal()
        }
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        manager.notify(
            VoiceNudgeNotifications.idFor(eventId),
            VoiceNudgeNotifications.buildResponse(
                this,
                eventId,
                groupId,
                responderName,
                responseAction,
                snoozeMinutes,
            ),
        )
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[NUDGE-ACTION-03] sender received response=$responseAction " +
                "snoozeMinutes=${snoozeMinutes ?: "none"}",
        )
    }

    /**
     * Real-time delivery confirmation (#5): only meaningful while the
     * sender's send-nudge bottom sheet is open, so it's forwarded straight
     * to Flutter with no persistent notification of its own.
     */
    private fun forwardDeliveryResult(message: RemoteMessage) {
        val data = message.data
        val eventId = data["eventId"] ?: return
        val status = data["status"] ?: return
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[NUDGE-DELIVERY-02] sender received status=$status " +
                "eventSuffix=${eventId.takeLast(6)} reason=${data["reason"].orEmpty()}",
        )
        NudgeDeliveryResultDispatcher.signal(
            mapOf(
                "eventId" to eventId,
                "groupId" to data["groupId"],
                "kind" to data["kind"],
                "status" to status,
                "reason" to data["reason"]?.takeIf { it.isNotBlank() },
                "recipientUserId" to data["recipientUserId"],
                "recipientName" to data["recipientName"],
            ),
        )
    }

    private fun isExpired(rawExpiry: String?): Boolean {
        val expiresAtSeconds = rawExpiry?.toLongOrNull() ?: return true
        return System.currentTimeMillis() / 1000 >= expiresAtSeconds
    }
}
