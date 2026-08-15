package app.oneone.one_one_app

import android.app.ActivityManager
import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.telephony.TelephonyManager
import java.io.File
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors

/**
 * On-device rolling text logs shared with Flutter [LogManager].
 * Writes to getExternalFilesDir()/logs/oneone_logs_YYYYMMDD.txt so FCM and
 * foreground services can persist lines even when Dart is not running.
 */
object DeviceLog {
    private const val prefsName = "one_one_device_log"
    private const val retainDays = 3
    private val writer = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "oneone-device-log").apply { isDaemon = true }
    }
    private val timestampFormat = DateTimeFormatter.ISO_OFFSET_DATE_TIME

    @Volatile var appContext: Context? = null
        private set
    @Volatile private var userId: String = "-"
    @Volatile private var groupId: String = "-"
    @Volatile private var appVersion: String = "-"

    fun init(context: Context) {
        val app = context.applicationContext
        appContext = app
        val prefs = app.getSharedPreferences(prefsName, Context.MODE_PRIVATE)
        userId = prefs.getString("userId", "-") ?: "-"
        groupId = prefs.getString("groupId", "-") ?: "-"
        appVersion = try {
            val pkg = app.packageManager.getPackageInfo(app.packageName, 0)
            val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pkg.longVersionCode.toString()
            } else {
                @Suppress("DEPRECATION")
                pkg.versionCode.toString()
            }
            "${pkg.versionName}+$code"
        } catch (_: Exception) {
            "-"
        }
        writer.execute { pruneOldFiles(app) }
    }

    fun setIdentity(userId: String?, groupId: String?) {
        if (userId != null) this.userId = userId.ifBlank { "-" }
        if (groupId != null) this.groupId = groupId.ifBlank { "-" }
        val context = appContext ?: return
        context.getSharedPreferences(prefsName, Context.MODE_PRIVATE).edit()
            .putString("userId", this.userId)
            .putString("groupId", this.groupId)
            .apply()
    }

    fun info(tag: String, message: String, groupId: String? = null, userId: String? = null) =
        log("INFO", tag, message, groupId, userId)

    fun warn(tag: String, message: String, groupId: String? = null, userId: String? = null) =
        log("WARN", tag, message, groupId, userId)

    fun error(tag: String, message: String, groupId: String? = null, userId: String? = null) =
        log("ERROR", tag, message, groupId, userId)

    fun fatal(tag: String, message: String, groupId: String? = null, userId: String? = null) =
        log("FATAL", tag, message, groupId, userId)

    fun log(
        level: String,
        tag: String,
        message: String,
        groupId: String? = null,
        userId: String? = null,
        throwable: Throwable? = null,
    ) {
        val context = appContext ?: return
            val network = networkPair(context)
        val line = buildString {
            append(OffsetDateTime.now().format(timestampFormat))
            append(" [").append(level).append("] [")
            append(tag.trim().removePrefix("[").removeSuffix("]")).append("] ")
            append(message)
            if (throwable != null) {
                append(" exception=").append(throwable.javaClass.name)
                append(" detail=").append(throwable.message ?: "-")
                append(" stack=").append(
                    throwable.stackTraceToString().replace(Regex("\\n"), " | "),
                )
            }
            append(" { userId: ").append(userId?.ifBlank { null } ?: this@DeviceLog.userId)
            append(", groupId: ").append(groupId?.ifBlank { null } ?: this@DeviceLog.groupId)
            append(", networkType: ").append(network.first)
            append(", networkStrength: ").append(network.second)
            append(", deviceModel: ").append(deviceModel())
            append(", androidVersion: ").append(Build.VERSION.RELEASE)
            append(", appVersion: ").append(appVersion)
            append(" }")
        }
        android.util.Log.println(
            when (level) {
                "WARN" -> android.util.Log.WARN
                "ERROR", "FATAL" -> android.util.Log.ERROR
                else -> android.util.Log.INFO
            },
            tag,
            message,
        )
        writer.execute {
            try {
                val dir = File(context.getExternalFilesDir(null), "logs")
                if (!dir.exists()) dir.mkdirs()
                val stamp = java.time.LocalDate.now().format(
                    DateTimeFormatter.BASIC_ISO_DATE,
                )
                File(dir, "oneone_logs_$stamp.txt").appendText("$line\n")
            } catch (_: Exception) {
                // Never crash the host service for logging.
            }
        }
    }

    fun currentAppVersion(): String = appVersion

    fun wasAppInBackground(): Boolean {
        val info = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(info)
        return info.importance > ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    fun deviceMeta(): Map<String, String> = mapOf(
        "deviceModel" to deviceModel(),
        "androidVersion" to Build.VERSION.RELEASE,
        "appVersion" to appVersion,
    )

    fun networkMeta(): Map<String, String> {
        val context = appContext ?: return mapOf(
            "networkType" to "Unknown",
            "networkStrength" to "-",
        )
        val pair = networkPair(context)
        return mapOf("networkType" to pair.first, "networkStrength" to pair.second)
    }

    private fun networkPair(context: Context): Pair<String, String> {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return "None" to "-"
        val network = cm.activeNetwork ?: return "None" to "-"
        val caps = cm.getNetworkCapabilities(network) ?: return "None" to "-"
        val type = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "WiFi"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "Mobile"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
            caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "VPN"
            else -> "Unknown"
        }
        val strength = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val signal = caps.signalStrength
            if (signal == Int.MIN_VALUE) bandwidthLabel(caps) else "$signal dBm"
        } else if (type == "Mobile") {
            cellularLabel(context)
        } else {
            bandwidthLabel(caps)
        }
        return type to strength
    }

    private fun bandwidthLabel(caps: NetworkCapabilities): String {
        val kbps = caps.linkDownstreamBandwidthKbps
        return if (kbps > 0) "$kbps kbps" else "-"
    }

    private fun cellularLabel(context: Context): String {
        return try {
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            tm?.networkType?.toString() ?: "-"
        } catch (_: SecurityException) {
            "-"
        }
    }

    private fun deviceModel(): String {
        val manufacturer = Build.MANUFACTURER.orEmpty()
        val model = Build.MODEL.orEmpty()
        return if (model.startsWith(manufacturer, ignoreCase = true)) {
            model.ifBlank { "-" }
        } else {
            "$manufacturer $model".trim().ifBlank { "-" }
        }
    }

    private fun pruneOldFiles(context: Context) {
        val dir = File(context.getExternalFilesDir(null), "logs")
        if (!dir.isDirectory) return
        val cutoff = java.time.LocalDate.now().minusDays(retainDays.toLong())
            .format(DateTimeFormatter.BASIC_ISO_DATE)
        dir.listFiles()?.forEach { file ->
            val name = file.name
            if (!name.startsWith("oneone_logs_") || !name.endsWith(".txt")) return@forEach
            val stamp = name.removePrefix("oneone_logs_").removeSuffix(".txt")
            if (stamp < cutoff) file.delete()
        }
    }
}
