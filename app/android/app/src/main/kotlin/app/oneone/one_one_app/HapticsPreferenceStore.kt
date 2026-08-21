package app.oneone.one_one_app

import android.content.Context

/**
 * Device-local haptic intensity for incoming nudge playback.
 *
 * Flutter writes this whenever Settings (or a session load) changes the
 * user's 3-tier haptics choice so [VoiceNudgePlaybackService] can apply
 * the same pattern even when the Dart VM is not running.
 */
object HapticsPreferenceStore {
    private const val preferencesName = "one_one_haptics"
    private const val intensityKey = "intensity"

    const val light = "light"
    const val medium = "medium"
    const val wild = "wild"

    fun save(context: Context, intensity: String) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putString(intensityKey, normalize(intensity))
            .apply()
    }

    fun read(context: Context): String {
        val raw = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getString(intensityKey, light)
        return normalize(raw)
    }

    fun normalize(value: String?): String {
        return when (value?.lowercase()) {
            medium -> medium
            wild -> wild
            else -> light
        }
    }
}

/** Waveform timings for the three haptic tiers. Timings are milliseconds. */
object NudgeHapticsWaveforms {
    /** Current default: two (plus a trailing tap) at start and the same at end. */
    val lightBurst: LongArray = longArrayOf(0, 150, 100, 150, 100, 150)

    /** Double-double: two quick pairs with a slightly longer gap between them. */
    val mediumBurst: LongArray = longArrayOf(0, 80, 50, 80, 180, 80, 50, 80)

    /** Repeating pulse used for Wild (repeat index 0, cancel after duration). */
    val wildLoop: LongArray = longArrayOf(0, 140, 70)

    fun totalMs(pattern: LongArray): Long = pattern.sum()
}
