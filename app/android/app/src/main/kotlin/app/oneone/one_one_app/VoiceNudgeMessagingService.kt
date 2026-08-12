package app.oneone.one_one_app

import android.app.AlarmManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

// ── B5: Local nudge expiry (10-minute timeout, on-device) ──
//
// When a nudge arrives on the receiver's device we record its timestamp and
// schedule an AlarmManager broadcast 10 minutes later.  If the broadcast
// fires and the nudge hasn't been accepted yet, we show a local expiry
// notification to both the receiver and (via FCM) the sender.  Accepting
// the nudge cancels the alarm so the expiry never fires spuriously.

object NudgeExpiryTracker {
    private const val prefsName = "one_one_nudge_expiry"
    private const val keyPrefix = "nudge_arrival_"
    const val expiryMinutes = 10L
    const val actionExpiry = "app.oneone.action.NUDGE_EXPIRED"

    /** Record a nudge arrival and schedule its expiry alarm. */
    fun scheduleExpiry(
        context: Context,
        eventId: String,
        senderName: String,
        recipientUserId: String,
        groupId: String?,
        recipientName: String?,
        isSenderSide: Boolean = false,
    ) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        prefs.edit()
            .putLong("${keyPrefix}$eventId", System.currentTimeMillis())
            .apply()

        val alarmManager = context.getSystemService(AlarmManager::class.java)
        val intent = Intent(context, NudgeExpiryReceiver::class.java).apply {
            action = actionExpiry
            putExtra("eventId", eventId)
            putExtra("senderName", senderName)
            putExtra("recipientUserId", recipientUserId)
            putExtra("groupId", groupId)
            putExtra("recipientName", recipientName)
            putExtra("isSenderSide", isSenderSide)
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            eventId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val triggerAt = SystemClock.elapsedRealtime() + expiryMinutes * 60_000L
        alarmManager.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, triggerAt, pendingIntent)
    }

    /** Cancel the expiry alarm — called when the user accepts the nudge. */
    fun cancelExpiry(context: Context, eventId: String) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        prefs.edit().remove("${keyPrefix}$eventId").apply()

        val alarmManager = context.getSystemService(AlarmManager::class.java)
        val intent = Intent(context, NudgeExpiryReceiver::class.java).apply {
            action = actionExpiry
        }
        val pendingIntent = PendingIntent.getBroadcast(
            context,
            eventId.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        alarmManager.cancel(pendingIntent)
    }

    /** Check if a nudge has been stored (hasn't expired and hasn't been accepted). */
    fun hasArrived(context: Context, eventId: String): Boolean {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        return prefs.contains("${keyPrefix}$eventId")
    }
}

class NudgeExpiryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != NudgeExpiryTracker.actionExpiry) return
        val eventId = intent.getStringExtra("eventId") ?: return
        val senderName = intent.getStringExtra("senderName") ?: "Someone"
        val recipientUserId = intent.getStringExtra("recipientUserId") ?: return
        val groupId = intent.getStringExtra("groupId")
        val recipientName = intent.getStringExtra("recipientName") ?: "You"
        val isSenderSide = intent.getBooleanExtra("isSenderSide", false)

        // Only fire if the nudge is still pending (not already accepted).
        if (!NudgeExpiryTracker.hasArrived(context, eventId)) return
        NudgeExpiryTracker.cancelExpiry(context, eventId)

        val manager = context.getSystemService(NotificationManager::class.java)

        if (isSenderSide) {
            // Notify sender: "Your nudge to [Recipient] was not accepted in time."
            manager.notify(
                VoiceNudgeNotifications.idFor("expiry_sender_$eventId"),
                VoiceNudgeNotifications.buildGeneral(
                    context,
                    "Nudge expired ⏰",
                    "Your nudge to $senderName was not accepted in time.",
                    groupId,
                ),
            )
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[NUDGE-EXPIRY-02] Sender nudge expired eventId=${eventId.takeLast(6)} recipient=$senderName",
            )
        } else {
            // Notify receiver: "Nudge from [Sender] has expired."
            manager.notify(
                VoiceNudgeNotifications.idFor("expiry_recv_$eventId"),
                VoiceNudgeNotifications.buildGeneral(
                    context,
                    "Nudge expired ⏰",
                    "Nudge from $senderName has expired.",
                    groupId,
                ),
            )
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[NUDGE-EXPIRY-01] Receiver nudge expired eventId=${eventId.takeLast(6)} sender=$senderName",
            )
        }
    }
}

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
                // B5: Schedule 10-min expiry for push nudges.
                scheduleNudgeExpiry(data)
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
            VoiceNudgeContract.kindAmbientNoise -> {
                // Still forward it in case the sender's nudge sheet happens
                // to be open, then show a real notification as the primary
                // channel since that's the common case.
                forwardDeliveryResult(message)
                showAmbientNoiseNotification(message)
                return
            }
            VoiceNudgeContract.kindVoice,
            VoiceNudgeContract.kindRing -> Unit
            else -> {
                Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W2] Ignored unknown message type=$kind")
                return
            }
        }

        // B5: Schedule 10-min expiry for voice + ring nudges.
        scheduleNudgeExpiry(data)

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
        val senderAvatarAsset = data["senderAvatarAsset"]?.takeIf { it.isNotBlank() }
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
            putExtra(VoiceNudgeContract.extraSenderAvatarAsset, senderAvatarAsset)
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
            val failureReason =
                if (error is SecurityException) "permission_denied_foreground_service" else "playback_service_start_error"
            VoiceNudgeDiagnostics.recordNudgeFailure(
                reason = failureReason,
                eventId = eventId,
                kind = kind,
                extras = mapOf(
                    "error" to (error.message ?: "unknown"),
                    "error_class" to error.javaClass.simpleName,
                ),
            )
            // The playback service never got a chance to run (and therefore
            // never got to POST its own ack) — report the specific reason
            // directly so the sender doesn't just see a generic timeout.
            VoiceNudgeDeliveryAck.postFailure(
                data["ackUrl"],
                data["deliveryToken"],
                failureReason,
            )
            val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
            val notificationId = VoiceNudgeNotifications.idFor(eventId)
            NotificationAvatarHelper.applyLargeIcon(
                this,
                data["senderPhotoUrl"],
                senderName,
                data["senderAvatarAsset"],
            ) { largeIcon ->
                try {
                    manager.notify(
                        notificationId,
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
                } catch (error: SecurityException) {
                    VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
                }
            }
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

    // B7: shown as a genuine OS notification because it arrives ~10s after
    // playback, well after the sender's in-app nudge sheet has likely closed.
    private fun showAmbientNoiseNotification(message: RemoteMessage) {
        val data = message.data
        val eventId = data["eventId"] ?: "ambient_${message.sentTime}"
        val recipientName = data["recipientName"]?.take(80).orEmpty().ifBlank { "They" }
        val manager = getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager
        try {
            manager.notify(
                VoiceNudgeNotifications.idFor("ambient_$eventId"),
                VoiceNudgeNotifications.buildGeneral(
                    this,
                    message.notification?.title ?: "It sounds noisy over there \uD83D\uDD0A",
                    message.notification?.body
                        ?: "$recipientName may not have heard your nudge clearly.",
                    data["groupId"],
                ),
            )
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[NUDGE-AMBIENT-01] Ambient-noise notification displayed " +
                    "eventSuffix=${eventId.takeLast(6)}",
            )
        } catch (error: SecurityException) {
            VoiceNudgeDiagnostics.logFailure("[NUDGE-AMBIENT-E01] Notification permission", error)
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
            val notificationId = VoiceNudgeNotifications.idFor(eventId)
            NotificationAvatarHelper.applyLargeIcon(
                this,
                data["senderPhotoUrl"],
                senderName,
                data["senderAvatarAsset"],
            ) { largeIcon ->
                try {
                    manager.notify(
                        notificationId,
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
                } catch (error: SecurityException) {
                    VoiceNudgeDiagnostics.logFailure("[FCM-E10] Notification permission", error)
                }
            }
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
        // B5: Nudge response arrived — cancel sender's expiry alarm.
        NudgeExpiryTracker.cancelExpiry(this, eventId)
        if (responseAction == "accept") {
            NudgeActionStore.save(
                this,
                PendingNudgeAction("connect", eventId, groupId),
            )
            NudgeActionDispatcher.signal()

            // B6: Attempt to wake the sender's app / keep it alive so Flutter
            // can reconnect to LiveKit automatically.  If the app is backgrounded
            // but Flutter is still alive, the signal above will trigger the
            // reconnect.  If the app is killed, the notification below gives
            // the user a tap-to-join fallback.
            try {
                val serviceIntent = Intent(this, VoiceSessionService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(serviceIntent)
                } else {
                    startService(serviceIntent)
                }
            } catch (error: RuntimeException) {
                Log.w(
                    VoiceNudgeDiagnostics.tag,
                    "[NUDGE-ACTION-04] Could not start foreground service " +
                        "for auto-reconnect: ${error.message}",
                )
            }
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
        // B5: Delivery result arrived — cancel the sender's expiry alarm.
        NudgeExpiryTracker.cancelExpiry(this, eventId)
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
                // B7: ambient noise reading, if this delivery result came
                // from the ~10s post-playback follow-up ack.
                "ambientNoiseLevel" to data["ambientNoiseLevel"]?.takeIf { it.isNotBlank() },
            ),
        )
    }

    private fun isExpired(rawExpiry: String?): Boolean {
        val expiresAtSeconds = rawExpiry?.toLongOrNull() ?: return true
        return System.currentTimeMillis() / 1000 >= expiresAtSeconds
    }

    /** B5: Schedule a 10-minute expiry alarm for a received nudge. */
    private fun scheduleNudgeExpiry(data: Map<String, String>) {
        val eventId = data["eventId"] ?: return
        val senderName = data["senderName"]?.take(80).orEmpty().ifBlank { "Someone" }
        val recipientUserId = data["recipientUserId"] ?: return
        val groupId = data["groupId"]
        val recipientName = data["recipientName"]
        NudgeExpiryTracker.scheduleExpiry(
            this,
            eventId,
            senderName,
            recipientUserId,
            groupId,
            recipientName,
        )
    }
}
