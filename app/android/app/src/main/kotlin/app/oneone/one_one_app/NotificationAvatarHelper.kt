package app.oneone.one_one_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Builds the large notification icon for nudge notifications: circular
 * sender profile photo when [photoUrl] is reachable, otherwise a monogram
 * circle from the sender's display name.
 */
object NotificationAvatarHelper {
    private val cache = ConcurrentHashMap<String, Bitmap>()
    private val executor = Executors.newSingleThreadExecutor()

    fun monogram(context: Context, senderName: String): Bitmap {
        val size = (64 * context.resources.displayMetrics.density).toInt().coerceAtLeast(96)
        val key = "mono:${senderName.trim().lowercase()}:$size"
        cache[key]?.let { return it }
        val letter = senderName.trim().firstOrNull()?.uppercaseChar()?.toString() ?: "?"
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(48, 48, 48)
            style = Paint.Style.FILL
        }
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        paint.color = Color.WHITE
        paint.textAlign = Paint.Align.CENTER
        paint.textSize = size * 0.42f
        paint.isFakeBoldText = true
        val textY = size / 2f - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText(letter, size / 2f, textY, paint)
        cache[key] = bitmap
        return bitmap
    }

    fun largeIcon(
        context: Context,
        photoUrl: String?,
        senderName: String,
    ): Bitmap {
        val url = photoUrl?.trim().orEmpty()
        if (url.isNotEmpty()) {
            cache[url]?.let { return it }
            val downloaded = downloadCircular(url, context)
            if (downloaded != null) {
                cache[url] = downloaded
                return downloaded
            }
        }
        return monogram(context, senderName)
    }

    /**
     * Loads [photoUrl] off the main thread and delivers a circular bitmap.
     * Falls back to a monogram if download fails.
     */
    fun loadAsync(
        context: Context,
        photoUrl: String?,
        senderName: String,
        onReady: (Bitmap) -> Unit,
    ) {
        executor.execute {
            val bitmap = largeIcon(context.applicationContext, photoUrl, senderName)
            onReady(bitmap)
        }
    }

    private fun downloadCircular(url: String, context: Context): Bitmap? {
        var connection: HttpURLConnection? = null
        return try {
            connection = (URL(url).openConnection() as HttpURLConnection).apply {
                connectTimeout = 2_500
                readTimeout = 2_500
                instanceFollowRedirects = true
            }
            if (connection.responseCode !in 200..299) return null
            val bytes = connection.inputStream.use { it.readBytes() }
            if (bytes.isEmpty() || bytes.size > 1_500_000) return null
            val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
            toCircular(decoded, context)
        } catch (_: Exception) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    private fun toCircular(source: Bitmap, context: Context): Bitmap {
        val size = (64 * context.resources.displayMetrics.density).toInt().coerceAtLeast(96)
        val scaled = Bitmap.createScaledBitmap(source, size, size, true)
        val output = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(output)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val rect = Rect(0, 0, size, size)
        canvas.drawARGB(0, 0, 0, 0)
        canvas.drawCircle(size / 2f, size / 2f, size / 2f, paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        canvas.drawBitmap(scaled, rect, RectF(rect), paint)
        if (scaled != source) scaled.recycle()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT) {
            // keep output
        }
        return output
    }
}
