package app.oneone.one_one_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import io.flutter.plugin.common.MethodChannel

object VoicePipContract {
    const val flutterChannel = "app.oneone/voice_pip"
    const val actionToggleMicrophone = "app.oneone.action.PIP_TOGGLE_MICROPHONE"
    const val actionMute = "app.oneone.action.PIP_MUTE"
}

object VoicePipActionDispatcher {
    private var channel: MethodChannel? = null
    private var pendingAction: String? = null

    fun attach(nextChannel: MethodChannel) {
        channel = nextChannel
        pendingAction?.let {
            nextChannel.invokeMethod("onPipAction", it)
            pendingAction = null
        }
    }

    fun detach(targetChannel: MethodChannel) {
        if (channel === targetChannel) channel = null
    }

    fun dispatch(action: String) {
        val target = channel
        if (target == null) {
            pendingAction = action
        } else {
            target.invokeMethod("onPipAction", action)
        }
    }
}

class VoicePipActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            VoicePipContract.actionToggleMicrophone ->
                VoicePipActionDispatcher.dispatch("toggle_microphone")
            VoicePipContract.actionMute ->
                VoicePipActionDispatcher.dispatch("mute")
        }
    }
}

class VoiceSessionService : Service() {
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Active voice session",
                NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(notificationId, notification())
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    private fun notification(): Notification {
        val openApp = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_voice_nudge)
            .setContentTitle("One One voice session")
            .setContentText("Live and listening")
            .setContentIntent(openApp)
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val channelId = "active_voice_session"
        private const val notificationId = 7012

        fun start(context: Context) {
            val intent = Intent(context, VoiceSessionService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, VoiceSessionService::class.java))
        }
    }
}
