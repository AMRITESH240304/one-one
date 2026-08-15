package app.oneone.one_one_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build

object VoiceNudgeNotifications {
    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(VoiceNudgeContract.notificationChannelId) == null) {
            val channel = NotificationChannel(
                VoiceNudgeContract.notificationChannelId,
                VoiceNudgeContract.notificationChannelName,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Urgent rings and short voice messages from your groups"
                enableVibration(true)
                setSound(null, null)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            manager.createNotificationChannel(channel)
        }
        if (
            manager.getNotificationChannel(VoiceNudgeContract.generalNotificationChannelId) == null
        ) {
            val channel = NotificationChannel(
                VoiceNudgeContract.generalNotificationChannelId,
                VoiceNudgeContract.generalNotificationChannelName,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Nudges and activity from your Duo groups"
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            manager.createNotificationChannel(channel)
        }
    }

    /** Mic glyph — used only for ring / voice / push nudge notifications. */
    private val nudgeSmallIcon = R.drawable.ic_voice_nudge

    /**
     * Status-bar / title-row small icon. Android only draws the alpha of
     * this asset (white silhouette), generated from [assets/logo.png].
     */
    private val appSmallIcon = R.drawable.ic_notification_app

    fun build(
        context: Context,
        eventId: String,
        groupId: String,
        responseUrl: String?,
        senderName: String,
        status: String,
        ongoing: Boolean,
        cachedAudioAvailable: Boolean = false,
        isPlaying: Boolean = false,
        largeIcon: Bitmap? = null,
    ): Notification {
        ensureChannels(context)
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            7001,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, VoiceNudgeContract.notificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val configured = builder
            .setSmallIcon(nudgeSmallIcon)
            .setContentTitle("🎙️ $senderName nudged you")
            .setContentText(status)
            .setColor(Color.rgb(248, 190, 3))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setGroup(groupKey(groupId))
            .setOngoing(ongoing)
            .setAutoCancel(!ongoing)
        if (largeIcon != null) {
            configured.setLargeIcon(largeIcon)
        }
        if (cachedAudioAvailable) {
            configured
                .addAction(
                    Notification.Action.Builder(
                        if (isPlaying) {
                            android.R.drawable.ic_media_pause
                        } else {
                            android.R.drawable.ic_media_play
                        },
                        if (isPlaying) "Pause" else "Play",
                        playbackIntent(
                            context,
                            eventId,
                            groupId,
                            responseUrl,
                            senderName,
                            isPlaying,
                        ),
                    ).build(),
                )
                .setDeleteIntent(cacheDeleteIntent(context, eventId))
        }
        return configured
            .addNudgeActions(
                context = context,
                eventId = eventId,
                groupId = groupId,
                responseUrl = responseUrl,
                senderName = senderName,
            )
            .build()
    }

    fun buildActionable(
        context: Context,
        eventId: String,
        groupId: String,
        responseUrl: String?,
        senderName: String,
        title: String,
        body: String,
        largeIcon: Bitmap? = null,
    ): Notification {
        ensureChannels(context)
        val notificationId = idFor(eventId)
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            requestCode(eventId, "open"),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, VoiceNudgeContract.generalNotificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        val configured = builder
            .setSmallIcon(nudgeSmallIcon)
            .setContentTitle(title)
            .setContentText(body)
            .setColor(Color.rgb(248, 190, 3))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setGroup(groupKey(groupId))
            .setAutoCancel(true)
        if (largeIcon != null) {
            configured.setLargeIcon(largeIcon)
        }
        return configured
            .addNudgeActions(
                context = context,
                eventId = eventId,
                groupId = groupId,
                responseUrl = responseUrl,
                senderName = senderName,
            )
            .build()
    }

    fun buildResponse(
        context: Context,
        eventId: String,
        groupId: String,
        responderName: String,
        responseAction: String,
        snoozeMinutes: Int? = null,
    ): Notification {
        ensureChannels(context)
        val accepted = responseAction == "accept"
        val body = when (responseAction) {
            "accept" -> "Tap to join together 🤝"
            "snooze" -> "They asked you to wait ${snoozeMinutes ?: 5} minutes ⏳"
            else -> "They can’t join right now 💤"
        }
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            if (accepted) {
                action = VoiceNudgeContract.actionConnect
                putExtra(VoiceNudgeContract.extraEventId, eventId)
                putExtra(VoiceNudgeContract.extraGroupId, groupId)
                putExtra(VoiceNudgeContract.extraNotificationId, idFor(eventId))
            }
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            requestCode(eventId, "response"),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, VoiceNudgeContract.generalNotificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        return builder
            .setSmallIcon(appSmallIcon)
            .setLargeIcon(NotificationAvatarHelper.appLogoBitmap(context))
            .setContentTitle("💬 $responderName answered your nudge")
            .setContentText(body)
            .setColor(Color.rgb(248, 190, 3))
            .setCategory(Notification.CATEGORY_SOCIAL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setGroup(groupKey(groupId))
            .setAutoCancel(true)
            .build()
    }

    fun buildGeneral(
        context: Context,
        title: String,
        body: String,
        groupId: String? = null,
    ): Notification {
        ensureChannels(context)
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            7002,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, VoiceNudgeContract.generalNotificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        if (groupId != null) builder.setGroup(groupKey(groupId))
        return builder
            .setSmallIcon(appSmallIcon)
            .setLargeIcon(NotificationAvatarHelper.appLogoBitmap(context))
            .setContentTitle(title)
            .setContentText(body)
            .setColor(Color.rgb(248, 190, 3))
            .setCategory(Notification.CATEGORY_SOCIAL)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .build()
    }

    /**
     * WhatsApp-style pile: one notification per group that updates in place
     * ("7 new messages") instead of a new alert per bubble.
     */
    fun buildChatPile(
        context: Context,
        groupId: String,
        title: String,
        body: String,
        unreadCount: Int,
    ): Notification {
        ensureChannels(context)
        val openIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            requestCode("chat_$groupId", "open"),
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, VoiceNudgeContract.generalNotificationChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
        return builder
            .setSmallIcon(appSmallIcon)
            .setLargeIcon(NotificationAvatarHelper.appLogoBitmap(context))
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setNumber(unreadCount.coerceAtLeast(1))
            .setOnlyAlertOnce(unreadCount > 1)
            .setColor(Color.rgb(248, 190, 3))
            .setCategory(Notification.CATEGORY_MESSAGE)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setPriority(Notification.PRIORITY_HIGH)
            .setContentIntent(contentIntent)
            .setGroup(groupKey(groupId))
            .setAutoCancel(true)
            .build()
    }

    fun chatPileId(groupId: String): Int = idFor("chat_pile_$groupId")

    fun cancelChatPile(context: Context, groupId: String) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.cancel(chatPileId(groupId))
        ChatPileStore.reset(context, groupId)
    }

    fun idFor(eventId: String): Int = eventId.hashCode() and 0x7fffffff

    fun groupKey(groupId: String): String = "oneone_group_$groupId"

    private fun Notification.Builder.addNudgeActions(
        context: Context,
        eventId: String,
        groupId: String,
        responseUrl: String?,
        senderName: String,
    ): Notification.Builder {
        if (responseUrl.isNullOrBlank()) return this
        val notificationId = idFor(eventId)
        val acceptPendingIntent = PendingIntent.getActivity(
            context,
            requestCode(eventId, "accept"),
            acceptIntent(context, eventId, groupId, notificationId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val declinePendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode(eventId, "decline"),
            responseIntent(
                context,
                VoiceNudgeContract.actionDecline,
                eventId,
                responseUrl,
                senderName,
                notificationId,
            ),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val snoozePendingIntentFlags = PendingIntent.FLAG_UPDATE_CURRENT or if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        ) {
            PendingIntent.FLAG_MUTABLE
        } else {
            0
        }
        val snoozePendingIntent = PendingIntent.getBroadcast(
            context,
            requestCode(eventId, "snooze"),
            responseIntent(
                context,
                VoiceNudgeContract.actionSnooze,
                eventId,
                responseUrl,
                senderName,
                notificationId,
            ),
            snoozePendingIntentFlags,
        )
        val snoozeDuration = RemoteInput.Builder(VoiceNudgeContract.extraSnoozeMinutes)
            .setLabel("Snooze for")
            .setChoices(arrayOf("5 minutes", "15 minutes"))
            .setAllowFreeFormInput(false)
            .build()
        val snoozeAction = Notification.Action.Builder(
            0,
            "Snooze",
            snoozePendingIntent,
        ).addRemoteInput(snoozeDuration).build()
        return addAction(Notification.Action.Builder(0, "Accept", acceptPendingIntent).build())
            .addAction(snoozeAction)
            .addAction(Notification.Action.Builder(0, "Decline", declinePendingIntent).build())
    }

    private fun acceptIntent(
        context: Context,
        eventId: String,
        groupId: String,
        notificationId: Int,
    ) = Intent(context, MainActivity::class.java).apply {
        action = VoiceNudgeContract.actionAccept
        flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        putExtra(VoiceNudgeContract.extraEventId, eventId)
        putExtra(VoiceNudgeContract.extraGroupId, groupId)
        putExtra(VoiceNudgeContract.extraNotificationId, notificationId)
    }

    private fun responseIntent(
        context: Context,
        actionName: String,
        eventId: String,
        responseUrl: String,
        senderName: String,
        notificationId: Int,
    ) = Intent(context, NudgeNotificationActionReceiver::class.java).apply {
        action = actionName
        putExtra(VoiceNudgeContract.extraEventId, eventId)
        putExtra(VoiceNudgeContract.extraResponseUrl, responseUrl)
        putExtra(VoiceNudgeContract.extraSenderName, senderName)
        putExtra(VoiceNudgeContract.extraNotificationId, notificationId)
    }

    private fun playbackIntent(
        context: Context,
        eventId: String,
        groupId: String,
        responseUrl: String?,
        senderName: String,
        isPlaying: Boolean,
    ): PendingIntent {
        val action = if (isPlaying) {
            VoiceNudgeContract.actionPauseCachedAudio
        } else {
            VoiceNudgeContract.actionPlayCachedAudio
        }
        val intent = Intent(context, VoiceNudgePlaybackService::class.java).apply {
            this.action = action
            putExtra(VoiceNudgeContract.extraKind, VoiceNudgeContract.kindVoice)
            putExtra(VoiceNudgeContract.extraEventId, eventId)
            putExtra(VoiceNudgeContract.extraGroupId, groupId)
            putExtra(VoiceNudgeContract.extraResponseUrl, responseUrl)
            putExtra(VoiceNudgeContract.extraSenderName, senderName)
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        return if (
            !isPlaying &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ) {
            PendingIntent.getForegroundService(
                context,
                requestCode(eventId, action),
                intent,
                flags,
            )
        } else {
            PendingIntent.getService(
                context,
                requestCode(eventId, action),
                intent,
                flags,
            )
        }
    }

    private fun cacheDeleteIntent(context: Context, eventId: String): PendingIntent {
        val intent = Intent(context, VoiceNudgeCacheDismissReceiver::class.java).apply {
            action = VoiceNudgeContract.actionDismissCachedAudio
            putExtra(VoiceNudgeContract.extraEventId, eventId)
        }
        return PendingIntent.getBroadcast(
            context,
            requestCode(eventId, "dismiss_audio"),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun requestCode(eventId: String, action: String): Int =
        "$eventId:$action".hashCode() and 0x7fffffff
}

object ChatPileStore {
    private const val prefsName = "one_one_chat_pile"

    fun resolveCount(context: Context, groupId: String, serverCount: Int?): Int {
        if (serverCount != null && serverCount > 0) {
            context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
                .edit()
                .putInt(groupId, serverCount)
                .apply()
            return serverCount
        }
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val next = prefs.getInt(groupId, 0) + 1
        prefs.edit().putInt(groupId, next).apply()
        return next
    }

    fun reset(context: Context, groupId: String) {
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .edit()
            .remove(groupId)
            .apply()
    }
}
