package app.oneone.one_one_app

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.FirebaseDatabase

/**
 * Mirrors the Dart [ActiveOnlineSessionStore] so a process kill can still
 * mark RTDB presence away after Flutter is gone.
 */
object ActiveVoiceSessionStore {
    private const val prefsName = "one_one_active_voice_session"
    private const val groupIdKey = "groupId"
    private const val userIdKey = "userId"
    private const val deviceIdKey = "deviceId"
    private const val serviceSessionIdKey = "serviceSessionId"
    private const val livekitSessionIdKey = "livekitSessionId"

    fun save(
        context: Context,
        groupId: String?,
        userId: String?,
        deviceId: String?,
        serviceSessionId: String?,
        livekitSessionId: String?,
    ) {
        if (groupId.isNullOrBlank() ||
            userId.isNullOrBlank() ||
            serviceSessionId.isNullOrBlank() ||
            livekitSessionId.isNullOrBlank()
        ) {
            return
        }
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE).edit()
            .putString(groupIdKey, groupId)
            .putString(userIdKey, userId)
            .putString(deviceIdKey, deviceId ?: "")
            .putString(serviceSessionIdKey, serviceSessionId)
            .putString(livekitSessionIdKey, livekitSessionId)
            .apply()
    }

    fun clear(context: Context) {
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .edit()
            .clear()
            .apply()
    }

    /** Returns the serviceSessionId currently stored, or null if none. Used by
     *  [VoiceSessionService] to detect whether a newer session was saved before
     *  it shuts down, in which case [markAwayBestEffort] must not fire. */
    fun readServiceSessionId(context: Context): String? =
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
            .getString(serviceSessionIdKey, null)
            ?.takeIf { it.isNotBlank() }

    /**
     * Writes away state to RTDB for the stored session.
     *
     * Only proceeds if [capturedSessionId] (the session ID captured by the
     * service at start time) still matches the currently-stored session ID.
     * This guards against a scenario where Flutter has already saved a NEW
     * session (via [save]) before the previous [VoiceSessionService] instance
     * finishes shutting down — without this check, the service's [onDestroy]
     * would overwrite the live new session with away.
     */
    fun markAwayBestEffort(context: Context, capturedSessionId: String? = null) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val groupId = prefs.getString(groupIdKey, null)?.takeIf { it.isNotBlank() } ?: return
        val userId = prefs.getString(userIdKey, null)?.takeIf { it.isNotBlank() } ?: return
        val serviceSessionId =
            prefs.getString(serviceSessionIdKey, null)?.takeIf { it.isNotBlank() } ?: return
        val livekitSessionId =
            prefs.getString(livekitSessionIdKey, null)?.takeIf { it.isNotBlank() } ?: return

        // If the service was started for a specific session, refuse to write
        // away if a newer session has been saved since (Flutter reconnected
        // before this service instance finished shutting down).
        if (capturedSessionId != null && capturedSessionId != serviceSessionId) {
            DeviceLog.warn(
                "VoiceSessionService",
                "markAwayBestEffort skipped — session changed since service started " +
                    "capturedSuffix=${capturedSessionId.takeLast(6)} " +
                    "currentSuffix=${serviceSessionId.takeLast(6)}",
            )
            return
        }

        val authUid = FirebaseAuth.getInstance().currentUser?.uid
        if (authUid != null && authUid != userId) return

        val now = System.currentTimeMillis() / 1000
        val away = mapOf(
            "activeDeviceId" to null,
            "activeServiceSessionId" to null,
            "activeLivekitSessionId" to null,
            "desiredState" to "away",
            "effectiveState" to "away",
            "serviceState" to "stopped",
            "livekitConnectionState" to "disconnected",
            "canReceiveLiveAudio" to false,
            "connectionMode" to "walkieTalkie",
            "lastHeartbeatAt" to now,
            "staleAfterAt" to now,
            "updatedAt" to now,
        )
        val updates = mapOf<String, Any?>(
            "appServiceSessions/$serviceSessionId/serviceState" to "stopped",
            "appServiceSessions/$serviceSessionId/stopReason" to "process_killed",
            "appServiceSessions/$serviceSessionId/stoppedAt" to now,
            "appServiceSessions/$serviceSessionId/lastHeartbeatAt" to now,
            "livekitSessions/$livekitSessionId/connectionState" to "disconnected",
            "livekitSessions/$livekitSessionId/disconnectedAt" to now,
            "livekitSessions/$livekitSessionId/lastStateChangedAt" to now,
            "memberAvailability/$groupId/$userId" to away,
        )
        try {
            FirebaseDatabase.getInstance(FirebaseApp.getInstance(), mediaVolumeDatabaseUrl)
                .reference
                .updateChildren(updates)
            DeviceLog.info(
                "VoiceSessionService",
                "Queued RTDB away write after process teardown groupId=$groupId",
            )
        } catch (error: Exception) {
            DeviceLog.warn(
                "VoiceSessionService",
                "Failed to queue RTDB away write: ${error.message}",
            )
        } finally {
            clear(context)
        }
    }
}
