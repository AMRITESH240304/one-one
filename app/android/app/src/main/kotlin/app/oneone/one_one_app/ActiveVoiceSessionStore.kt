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

    fun markAwayBestEffort(context: Context) {
        val prefs = context.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        val groupId = prefs.getString(groupIdKey, null)?.takeIf { it.isNotBlank() } ?: return
        val userId = prefs.getString(userIdKey, null)?.takeIf { it.isNotBlank() } ?: return
        val serviceSessionId =
            prefs.getString(serviceSessionIdKey, null)?.takeIf { it.isNotBlank() } ?: return
        val livekitSessionId =
            prefs.getString(livekitSessionIdKey, null)?.takeIf { it.isNotBlank() } ?: return
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
