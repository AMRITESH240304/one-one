package app.oneone.one_one_app

import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.util.Log
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.FirebaseDatabase

/**
 * Local STREAM_MUSIC helpers and a one-shot RTDB self-report.
 *
 * Android cannot read another device's media volume — [AudioManager] state is
 * local to this process. Receivers therefore write `{ userId, groupId,
 * volumeLevel: 0–100, timestamp }` to `mediaVolume/{groupId}/{userId}` so the
 * sender can warn after a nudge. Never attempt a remote volume query.
 */
const val mediaVolumeDatabaseUrl =
    "https://oneone-3adb5-default-rtdb.asia-southeast1.firebasedatabase.app"

fun mediaVolumePercent(
    streamMuted: Boolean,
    streamVolume: Int,
    streamMaxVolume: Int,
): Int {
    if (streamMuted || streamVolume <= 0 || streamMaxVolume <= 0) return 0
    return ((streamVolume * 100) / streamMaxVolume).coerceIn(0, 100)
}

fun mediaVolumeBand(percent: Int): String = when {
    percent <= 0 -> "muted"
    percent < 25 -> "very_low"
    percent < 50 -> "low"
    else -> "ok"
}

fun mediaVolumeAttention(percent: Int): String? = when {
    percent <= 0 -> "volume_muted"
    percent < 25 -> "volume_very_low"
    percent < 50 -> "volume_low"
    else -> null
}

fun isMediaMuted(streamMuted: Boolean, streamVolume: Int): Boolean =
    streamMuted || streamVolume <= 0

object MediaVolume {
    private var lastUnmutedVolume = -1

    fun isMuted(context: Context): Boolean {
        val audioManager = context.getSystemService(AudioManager::class.java)
        return isMediaMuted(
            streamMuted = isStreamMuted(audioManager),
            streamVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC),
        )
    }

    fun setMuted(context: Context, muted: Boolean, showUi: Boolean = true) {
        val audioManager = context.getSystemService(AudioManager::class.java)
        val flags = if (showUi) AudioManager.FLAG_SHOW_UI else 0
        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        if (muted) {
            if (current > 0) lastUnmutedVolume = current
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                audioManager.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    AudioManager.ADJUST_MUTE,
                    flags,
                )
            } else {
                @Suppress("DEPRECATION")
                audioManager.setStreamMute(AudioManager.STREAM_MUSIC, true)
            }
            if (audioManager.getStreamVolume(AudioManager.STREAM_MUSIC) > 0) {
                audioManager.setStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    0,
                    flags,
                )
            }
            return
        }
        if (!isMuted(context)) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.adjustStreamVolume(
                AudioManager.STREAM_MUSIC,
                AudioManager.ADJUST_UNMUTE,
                flags,
            )
        } else {
            @Suppress("DEPRECATION")
            audioManager.setStreamMute(AudioManager.STREAM_MUSIC, false)
        }
        if (audioManager.getStreamVolume(AudioManager.STREAM_MUSIC) <= 0) {
            val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val restored = lastUnmutedVolume.takeIf { it > 0 }
                ?: (max * 2 / 5).coerceAtLeast(1)
            audioManager.setStreamVolume(
                AudioManager.STREAM_MUSIC,
                restored.coerceAtMost(max),
                flags,
            )
        }
    }

    fun readPercent(context: Context): Int {
        val audioManager = context.getSystemService(AudioManager::class.java)
        return mediaVolumePercent(
            streamMuted = isStreamMuted(audioManager),
            streamVolume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC),
            streamMaxVolume = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
        )
    }

    private fun isStreamMuted(audioManager: AudioManager): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.isStreamMute(AudioManager.STREAM_MUSIC)
        } else {
            audioManager.getStreamVolume(AudioManager.STREAM_MUSIC) == 0
        }
    }

    /** Best-effort write used from the FCM handler (runs in background). */
    fun report(context: Context, groupId: String?) {
        val gid = groupId?.takeIf { it.isNotBlank() } ?: return
        DeviceLog.init(context)
        val uid = FirebaseAuth.getInstance().currentUser?.uid
            ?: DeviceLog.currentUserId()
            ?: return
        val level = readPercent(context)
        val payload = mapOf(
            "userId" to uid,
            "groupId" to gid,
            "volumeLevel" to level,
            "timestamp" to System.currentTimeMillis(),
        )
        try {
            FirebaseDatabase.getInstance(FirebaseApp.getInstance(), mediaVolumeDatabaseUrl)
                .getReference("mediaVolume/$gid/$uid")
                .setValue(payload)
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[VOL-01] Reported media volume=$level groupSuffix=${gid.takeLast(6)}",
            )
        } catch (error: Exception) {
            Log.w(
                VoiceNudgeDiagnostics.tag,
                "[VOL-W1] Media volume report failed: ${error.message}",
            )
        }
    }
}
