package app.oneone.one_one_app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel

object VoicePipContract {
    const val flutterChannel = "app.oneone/voice_pip"
    const val actionToggleMicrophone = "app.oneone.action.PIP_TOGGLE_MICROPHONE"
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

object VoiceSessionTeardownDispatcher {
    private var channel: MethodChannel? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun attach(nextChannel: MethodChannel) {
        channel = nextChannel
    }

    fun detach(targetChannel: MethodChannel) {
        if (channel === targetChannel) channel = null
    }

    fun requestTeardown() {
        val target = channel ?: return
        mainHandler.post {
            try {
                target.invokeMethod("onProcessTeardown", null)
            } catch (_: Exception) {
            }
        }
    }
}

class VoicePipActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            VoicePipContract.actionToggleMicrophone ->
                VoicePipActionDispatcher.dispatch("toggle_microphone")
        }
    }
}

class VoiceSessionService : Service() {
    /** Session ID that was active when this service instance started.
     *  Passed to [ActiveVoiceSessionStore.markAwayBestEffort] so it can
     *  bail out if Flutter saved a newer session before we finish shutting down. */
    private var capturedSessionId: String? = null

    override fun onCreate() {
        super.onCreate()
        // Capture BEFORE any concurrent save() can overwrite the prefs.
        capturedSessionId = ActiveVoiceSessionStore.readServiceSessionId(this)
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
        DeviceLog.init(this)
        DeviceLog.info(
            "VoiceSessionService",
            "onStartCommand called flags=$flags startId=$startId sdk=${Build.VERSION.SDK_INT}",
        )
        // B1: On API 34+ (and especially 36), starting a foreground service of
        // type "microphone" requires android.permission.FOREGROUND_SERVICE_MICROPHONE
        // (declared in the manifest) AND android.permission.RECORD_AUDIO to be
        // granted at runtime. If RECORD_AUDIO is missing, fail gracefully instead
        // of crashing the process.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val recordGranted = ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED
            if (!recordGranted) {
                Log.e(
                    "OneOneVoicePip",
                    "[VOICE-SESSION-ERR] Cannot start foreground service: " +
                        "RECORD_AUDIO not granted at runtime. " +
                        "foregroundServiceMicrophone=${checkSelfPermission(Manifest.permission.FOREGROUND_SERVICE_MICROPHONE) == PackageManager.PERMISSION_GRANTED}",
                )
                DeviceLog.error(
                    "VoiceSessionService",
                    "Nudge not delivered / service not started: permission denied " +
                        "(RECORD_AUDIO missing for microphone foreground service)",
                )
                VoiceNudgeDiagnostics.recordNudgeFailure(
                    reason = "permission_denied_microphone",
                    eventId = null,
                    kind = "voice_session",
                    extras = mapOf("checkpoint" to "VoiceSessionService.onStartCommand"),
                )
                stopSelf()
                return START_NOT_STICKY
            }
        }
        try {
            DeviceLog.info("VoiceSessionService", "startForeground called")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    notificationId,
                    notification(),
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE,
                )
            } else {
                @Suppress("DEPRECATION")
                startForeground(notificationId, notification())
            }
        } catch (error: SecurityException) {
            DeviceLog.log(
                "ERROR",
                "VoiceSessionService",
                "SecurityException caught while calling startForeground",
                throwable = error,
            )
            VoiceNudgeDiagnostics.recordNudgeFailure(
                reason = "background_fg_service_blocked",
                eventId = null,
                kind = "voice_session",
                extras = mapOf(
                    "error" to (error.message ?: "unknown"),
                    "error_class" to error.javaClass.simpleName,
                ),
                throwable = error,
            )
            stopSelf()
            return START_NOT_STICKY
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        DeviceLog.info(
            "VoiceSessionService",
            "task removed — requesting LiveKit disconnect and presence cleanup",
        )
        VoiceSessionTeardownDispatcher.requestTeardown()
        ActiveVoiceSessionStore.markAwayBestEffort(this, capturedSessionId)
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        DeviceLog.info("VoiceSessionService", "service stopped")
        VoiceSessionTeardownDispatcher.requestTeardown()
        ActiveVoiceSessionStore.markAwayBestEffort(this, capturedSessionId)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    private fun notification(): Notification {
        val openApp = BrandedSplashIntents.mainActivity(
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
            .setSmallIcon(R.drawable.ic_notification_app)
            .setLargeIcon(NotificationAvatarHelper.appLogoBitmap(this))
            .setColor(Color.rgb(248, 190, 3))
            .setContentTitle("🎙️ Duo voice session")
            .setContentText("Live and listening 🟢")
            .setContentIntent(openApp)
            .setCategory(Notification.CATEGORY_CALL)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val channelId = "active_voice_session"
        private const val notificationId = 7012

        fun start(context: Context) {
            // B1: Guard against starting when RECORD_AUDIO isn't granted at
            // runtime — API 34+ requires it for foreground service type "microphone".
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                val recordGranted = ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.RECORD_AUDIO,
                ) == PackageManager.PERMISSION_GRANTED
                if (!recordGranted) {
                    Log.w(
                        "OneOneVoicePip",
                        "[VOICE-SESSION] Skipping VoiceSessionService start: " +
                            "RECORD_AUDIO permission not granted at runtime.",
                    )
                    return
                }
            }
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
