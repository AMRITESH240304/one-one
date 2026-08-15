package app.oneone.one_one_app

import java.util.ArrayDeque

/**
 * Rolling in-memory buffer of the structured log lines emitted through the
 * [Log] facade. Bounded so a long-lived foreground-service process (which
 * keeps the same PID alive between nudges) can't grow memory without limit —
 * the oldest lines are dropped first.
 */
object NudgeLogBuffer {
    private const val capacity = 256
    private val buffer = ArrayDeque<String>()

    @Synchronized
    fun append(level: Char, message: String) {
        if (buffer.size >= capacity) buffer.removeFirst()
        buffer.add("[$level] $message")
    }

    @Synchronized
    fun snapshot(): List<String> = buffer.toList()

    @Synchronized
    fun clear() = buffer.clear()
}

/**
 * Log facade that mirrors `android.util.Log` for the nudge/FCM code paths.
 * Every call forwards to the platform logger AND appends to [NudgeLogBuffer],
 * so a nudge failure can ship the receiver's recent structured trace along
 * with its Crashlytics non-fatal report.
 *
 * Files that route nudge/FCM logs through this facade simply drop their
 * `import android.util.Log` (same package resolves `Log` to this object).
 */
object Log {
    fun d(tag: String, message: String): Int {
        NudgeLogBuffer.append('D', message)
        return android.util.Log.d(tag, message)
    }

    fun i(tag: String, message: String): Int {
        NudgeLogBuffer.append('I', message)
        return android.util.Log.i(tag, message)
    }

    fun w(tag: String, message: String): Int {
        NudgeLogBuffer.append('W', message)
        return android.util.Log.w(tag, message)
    }

    fun w(tag: String, message: String, tr: Throwable): Int {
        NudgeLogBuffer.append('W', message)
        return android.util.Log.w(tag, message, tr)
    }

    fun e(tag: String, message: String): Int {
        NudgeLogBuffer.append('E', message)
        return android.util.Log.e(tag, message)
    }

    fun e(tag: String, message: String, tr: Throwable): Int {
        NudgeLogBuffer.append('E', message)
        return android.util.Log.e(tag, message, tr)
    }
}
