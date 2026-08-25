package app.oneone.one_one_app

import android.app.ActivityOptions
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.window.SplashScreen

/**
 * PendingIntents that open [MainActivity] from a notification (or other
 * non-launcher start) must opt into the branded splash. Android 12+ skips
 * the splash icon for those launches by default, which leaves a white /
 * launcher-icon preview up until [MainActivity.installSplashScreen] runs.
 */
object BrandedSplashIntents {
    fun mainActivity(
        context: Context,
        requestCode: Int,
        intent: Intent,
        flags: Int,
    ): PendingIntent {
        val options = splashOptionsBundle()
        return if (options != null) {
            PendingIntent.getActivity(context, requestCode, intent, flags, options)
        } else {
            PendingIntent.getActivity(context, requestCode, intent, flags)
        }
    }

    private fun splashOptionsBundle(): Bundle? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return null
        return ActivityOptions.makeBasic()
            .setSplashScreenStyle(SplashScreen.SPLASH_SCREEN_STYLE_ICON)
            .toBundle()
    }
}
