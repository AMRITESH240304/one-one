package app.oneone.one_one_app

import android.content.Context
import android.os.Build
import android.util.Log
import com.google.firebase.crashlytics.FirebaseCrashlytics
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

object VoiceNudgeContract {
    const val flutterChannel = "app.oneone/voice_nudge"
    const val notificationChannelId = "voice_nudges"
    const val notificationChannelName = "Voice nudges"
    const val generalNotificationChannelId = "walkie_alerts_v2"
    const val generalNotificationChannelName = "Duo alerts"

    const val extraKind = "kind"
    const val extraEventId = "eventId"
    const val extraSenderName = "senderName"
    const val extraSenderPhotoUrl = "senderPhotoUrl"
    const val extraSenderAvatarAsset = "senderAvatarAsset"
    const val extraDurationMs = "durationMs"
    const val extraAudioUrl = "audioUrl"
    const val extraAckUrl = "ackUrl"
    const val extraDeliveryToken = "deliveryToken"
    const val extraGroupId = "groupId"
    const val extraResponseUrl = "responseUrl"
    const val extraAction = "nudgeAction"
    const val extraNotificationId = "notificationId"
    const val extraSnoozeMinutes = "snoozeMinutes"

    const val kindVoice = "voice_nudge"
    const val kindRing = "ring_nudge"
    const val kindPush = "nudge"
    const val kindFriendLive = "friend_live"
    const val kindGoneOffline = "gone_offline"
    const val kindResponse = "nudge_response"
    const val kindDeliveryResult = "nudge_delivery_result"

    const val actionAccept = "app.oneone.action.ACCEPT_NUDGE"
    const val actionConnect = "app.oneone.action.CONNECT_NUDGE"
    const val actionDecline = "app.oneone.action.DECLINE_NUDGE"
    const val actionSnooze = "app.oneone.action.SNOOZE_NUDGE"
    const val actionPlayCachedAudio = "app.oneone.action.PLAY_CACHED_NUDGE"
    const val actionPauseCachedAudio = "app.oneone.action.PAUSE_CACHED_NUDGE"
    const val actionDismissCachedAudio = "app.oneone.action.DISMISS_CACHED_NUDGE"
    const val actionStopGroupNudges = "app.oneone.action.STOP_GROUP_NUDGES"
}

object VoiceNudgeTokenStore {
    private const val preferencesName = "one_one_voice_nudge"
    private const val tokenKey = "fcm_token"

    fun save(context: Context, token: String) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putString(tokenKey, token)
            .apply()
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[FCM-05] Registered identifier saved locally " +
                VoiceNudgeDiagnostics.describeIdentifier(token),
        )
    }
}

// ── Delivery ack for failures that happen before VoiceNudgePlaybackService
// ever gets a chance to run (e.g. the OS rejects the foreground-service
// launch) ──
//
// VoiceNudgePlaybackService.acknowledge() already POSTs a rich ack (with
// health data) once the service is running. But when the
// service never starts at all, nothing ever calls that, so the sender was
// previously left with no signal beyond a generic ~12s client-side timeout
// with no specific reason. This lightweight, fire-and-forget helper lets the
// FCM receiver (which always has the ackUrl/deliveryToken from the payload)
// report a specific failure reason immediately in that case.
object VoiceNudgeDeliveryAck {
    private val executor = Executors.newSingleThreadExecutor()

    fun postFailure(ackUrl: String?, deliveryToken: String?, reason: String) {
        if (ackUrl.isNullOrBlank() || deliveryToken.isNullOrBlank()) return
        executor.execute {
            var connection: HttpURLConnection? = null
            try {
                val opened = URL(ackUrl).openConnection() as HttpURLConnection
                connection = opened
                opened.connectTimeout = 5_000
                opened.readTimeout = 5_000
                opened.requestMethod = "POST"
                opened.doOutput = true
                opened.setRequestProperty("content-type", "application/json")
                opened.setRequestProperty("x-one-one-delivery-token", deliveryToken)
                val body = JSONObject().apply {
                    put("status", "failed")
                    put("reason", reason)
                }
                opened.outputStream.use { it.write(body.toString().toByteArray()) }
                val responseCode = opened.responseCode
                Log.i(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-E3-ACK] Reported failure before playback started " +
                        "reason=$reason HTTP=$responseCode",
                )
            } catch (error: Exception) {
                VoiceNudgeDiagnostics.logFailure(
                    "[FCM-E3-ACK] Reporting failure before playback started",
                    error,
                )
            } finally {
                connection?.disconnect()
            }
        }
    }
}

object VoiceNudgeDiagnostics {
    const val tag = "OneOneFCM"

    fun describeIdentifier(value: String): String =
        "length=${value.length} suffix=${value.takeLast(6)}"

    fun logFailure(checkpoint: String, error: Throwable?) {
        if (error == null) {
            Log.e(tag, "$checkpoint failed without an exception")
            return
        }

        Log.e(tag, "$checkpoint ${error.javaClass.name}: ${error.message}", error)
        var cause = error.cause
        var depth = 1
        while (cause != null && cause !== error && depth <= 6) {
            Log.e(
                tag,
                "$checkpoint cause[$depth]=${cause.javaClass.name}: ${cause.message}",
            )
            cause = cause.cause
            depth += 1
        }
    }

    // ── B3: Comprehensive nudge failure logging to Crashlytics ──
    //
    // Every nudge failure is recorded as a non-fatal Crashlytics event with
    // enough metadata to debug without manual reproduction.  All events use
    // the custom key "nudge_failure_event" so they are filterable in the
    // dashboard.

    /** Generic nudge-failure record with a required reason code. */
    fun recordNudgeFailure(
        reason: String,
        eventId: String?,
        kind: String?,
        extras: Map<String, String> = emptyMap(),
    ) {
        val crashlytics = FirebaseCrashlytics.getInstance()
        crashlytics.setCustomKey("nudge_failure_event", reason)
        crashlytics.setCustomKey("nudge_failure_kind", kind ?: "unknown")
        crashlytics.setCustomKey("device_model", Build.MODEL)
        crashlytics.setCustomKey("android_sdk", Build.VERSION.SDK_INT.toString())
        eventId?.let {
            crashlytics.setCustomKey(
                "nudge_event_suffix",
                it.takeLast(8),
            )
        }
        for ((key, value) in extras) {
            crashlytics.setCustomKey(key, value)
        }
        crashlytics.recordException(
            RuntimeException("Nudge failure: $reason (kind=$kind eventSuffix=${eventId?.takeLast(6) ?: "none"})"),
        )
        Log.w(tag, "[NUDGE-FAIL] reason=$reason kind=$kind ${extras}")
    }
}
