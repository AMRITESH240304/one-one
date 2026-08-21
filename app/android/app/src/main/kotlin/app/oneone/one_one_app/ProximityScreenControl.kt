package app.oneone.one_one_app

import android.content.Context
import android.os.PowerManager
import android.util.Log

/**
 * Turns the screen off via the proximity sensor while the phone is held to
 * the ear (earpiece call mode). Matches native in-call behavior.
 *
 * Uses [PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK], which the platform
 * releases automatically when the sensor clears.
 */
class ProximityScreenControl(private val context: Context) {
    private var wakeLock: PowerManager.WakeLock? = null

    fun setEnabled(enabled: Boolean) {
        if (enabled) {
            acquire()
        } else {
            release()
        }
    }

    private fun acquire() {
        val existing = wakeLock
        if (existing?.isHeld == true) return
        try {
            val powerManager = context.getSystemService(PowerManager::class.java)
            @Suppress("DEPRECATION")
            val lock = existing ?: powerManager.newWakeLock(
                PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                "oneone:proximity",
            ).also { wakeLock = it }
            if (!lock.isHeld) {
                lock.acquire()
            }
        } catch (error: Exception) {
            Log.w(TAG, "Failed to acquire proximity wake lock: ${error.message}")
        }
    }

    private fun release() {
        try {
            wakeLock?.takeIf { it.isHeld }?.release()
        } catch (error: Exception) {
            Log.w(TAG, "Failed to release proximity wake lock: ${error.message}")
        }
    }

    companion object {
        private const val TAG = "ProximityScreen"
    }
}
