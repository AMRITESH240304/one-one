package app.oneone.one_one_app

import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.os.Build
import android.content.Intent
import android.util.Log
import android.util.Rational
import com.google.firebase.FirebaseApp
import com.google.firebase.installations.FirebaseInstallations
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class MainActivity : FlutterFragmentActivity() {
    private lateinit var voiceNudgeChannel: MethodChannel
    private lateinit var inviteLinkChannel: MethodChannel
    private lateinit var voicePipChannel: MethodChannel
    private var voiceSessionActive = false
    private var voiceSessionTalking = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        VoiceNudgeNotifications.ensureChannels(this)
        if (BuildConfig.DEBUG) logFirebaseRuntimeConfiguration()
        voiceNudgeChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VoiceNudgeContract.flutterChannel,
        )
        NudgeActionDispatcher.attach(voiceNudgeChannel)
        captureNudgeAction(intent)
        inviteLinkChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            InviteLinkContract.flutterChannel,
        )
        captureInviteLink(intent)
        voicePipChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            VoicePipContract.flutterChannel,
        )
        VoicePipActionDispatcher.attach(voicePipChannel)
        voicePipChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "setSessionState" -> {
                    val arguments = call.arguments as? Map<*, *>
                    val wasActive = voiceSessionActive
                    voiceSessionActive = arguments?.get("active") == true
                    voiceSessionTalking = arguments?.get("isTalking") == true
                    if (voiceSessionActive && !wasActive) {
                        VoiceSessionService.start(this)
                    } else if (!voiceSessionActive && wasActive) {
                        VoiceSessionService.stop(this)
                    }
                    updatePictureInPictureParams()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        voiceNudgeChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Keep the channel name for compatibility with existing Dart and
                // database records. New SDKs return the registered Firebase
                // Installation ID rather than a legacy registration token.
                "getFcmToken" -> {
                    Log.i(
                        VoiceNudgeDiagnostics.tag,
                        "[FCM-02] Flutter requested FCM installation registration",
                    )
                    FirebaseMessaging.getInstance().register()
                        .addOnCompleteListener registration@{ registrationTask ->
                            if (!registrationTask.isSuccessful) {
                                VoiceNudgeDiagnostics.logFailure(
                                    "[FCM-E1] FCM installation registration",
                                    registrationTask.exception,
                                )
                                result.error(
                                    "fcm_registration_failed",
                                    registrationTask.exception?.message
                                        ?: "FCM installation registration failed.",
                                    null,
                                )
                                return@registration
                            }

                            Log.i(
                                VoiceNudgeDiagnostics.tag,
                                "[FCM-03] FCM backend registration completed",
                            )
                            FirebaseInstallations.getInstance().id
                                .addOnCompleteListener idLookup@{ idTask ->
                                    val installationId =
                                        if (idTask.isSuccessful) idTask.result else null
                                    if (idTask.isSuccessful && !installationId.isNullOrBlank()) {
                                        Log.i(
                                            VoiceNudgeDiagnostics.tag,
                                            "[FCM-04] Firebase Installation ID resolved " +
                                                VoiceNudgeDiagnostics.describeIdentifier(
                                                    installationId,
                                                ),
                                        )
                                        VoiceNudgeTokenStore.save(this, installationId)
                                        result.success(installationId)
                                        return@idLookup
                                    }

                                    VoiceNudgeDiagnostics.logFailure(
                                        "[FCM-E2] Firebase Installation ID lookup",
                                        idTask.exception,
                                    )
                                    result.error(
                                        "fcm_installation_id_unavailable",
                                        idTask.exception?.message
                                            ?: "Firebase Installation ID is unavailable.",
                                        null,
                                    )
                                }
                        }
                }

                "takePendingNudgeAction" -> {
                    result.success(NudgeActionStore.take(this)?.toMap())
                }

                else -> result.notImplemented()
            }
        }
        inviteLinkChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "peekPendingInviteCode" -> {
                    result.success(InviteLinkContract.peekPendingCode(this))
                }
                "clearPendingInviteCode" -> {
                    val code = call.arguments as? String
                    if (code.isNullOrBlank()) {
                        result.error("invalid_invite_code", "Invite code is required.", null)
                    } else {
                        InviteLinkContract.clearPendingCode(this, code)
                        result.success(null)
                    }
                }
                "shareInviteLink" -> {
                    val inviteUrl = call.arguments as? String
                    if (inviteUrl.isNullOrBlank()) {
                        result.error("invalid_invite_url", "Invite URL is required.", null)
                    } else {
                        val shareIntent = Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_SUBJECT, "Join my One One group")
                            putExtra(
                                Intent.EXTRA_TEXT,
                                "Join my group on One One: $inviteUrl",
                            )
                        }
                        startActivity(Intent.createChooser(shareIntent, "Share group invite"))
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureNudgeAction(intent)
        captureInviteLink(intent)
    }

    override fun onUserLeaveHint() {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            Build.VERSION.SDK_INT < Build.VERSION_CODES.S &&
            voiceSessionActive &&
            !isInPictureInPictureMode
        ) {
            enterPictureInPictureMode(buildPictureInPictureParams())
        }
        super.onUserLeaveHint()
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        if (::voicePipChannel.isInitialized) {
            voicePipChannel.invokeMethod(
                "onPipModeChanged",
                isInPictureInPictureMode,
            )
        }
    }

    override fun onDestroy() {
        if (isFinishing && voiceSessionActive) {
            VoiceSessionService.stop(this)
            voiceSessionActive = false
        }
        if (::voiceNudgeChannel.isInitialized) {
            NudgeActionDispatcher.detach(voiceNudgeChannel)
        }
        if (::voicePipChannel.isInitialized) {
            VoicePipActionDispatcher.detach(voicePipChannel)
        }
        super.onDestroy()
    }

    private fun updatePictureInPictureParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setPictureInPictureParams(buildPictureInPictureParams())
        }
    }

    private fun buildPictureInPictureParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
            .setAspectRatio(Rational(1, 1))
            .setActions(pictureInPictureActions())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder
                .setAutoEnterEnabled(voiceSessionActive)
                .setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    private fun pictureInPictureActions(): List<RemoteAction> {
        val toggleAction = RemoteAction(
            Icon.createWithResource(
                this,
                if (voiceSessionTalking) R.drawable.ic_mic_off else R.drawable.ic_voice_nudge,
            ),
            if (voiceSessionTalking) "Stop talking" else "Talk",
            if (voiceSessionTalking) "Stop talking" else "Talk",
            pipActionIntent(VoicePipContract.actionToggleMicrophone, 1),
        )
        return listOf(toggleAction)
    }

    private fun pipActionIntent(action: String, requestCode: Int): PendingIntent {
        return PendingIntent.getBroadcast(
            this,
            requestCode,
            Intent(this, VoicePipActionReceiver::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun captureNudgeAction(intent: Intent?) {
        val action = when (intent?.action) {
            VoiceNudgeContract.actionAccept -> "accept"
            VoiceNudgeContract.actionConnect -> "connect"
            else -> return
        }
        val eventId = intent.getStringExtra(VoiceNudgeContract.extraEventId) ?: return
        val groupId = intent.getStringExtra(VoiceNudgeContract.extraGroupId) ?: return
        val notificationId = intent.getIntExtra(
            VoiceNudgeContract.extraNotificationId,
            VoiceNudgeNotifications.idFor(eventId),
        )
        (getSystemService(NOTIFICATION_SERVICE) as android.app.NotificationManager)
            .cancel(notificationId)
        VoiceNudgeAudioCache.delete(this, eventId)
        NudgeActionStore.save(this, PendingNudgeAction(action, eventId, groupId))
        NudgeActionDispatcher.signal()
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[NUDGE-ACTION-02] queued action=$action eventSuffix=${eventId.takeLast(6)}",
        )
    }

    private fun captureInviteLink(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        val isCustomInvite =
            uri.scheme.equals(InviteLinkContract.customScheme, ignoreCase = true) &&
                uri.host.equals(InviteLinkContract.inviteHost, ignoreCase = true)
        val isHttpsInvite =
            uri.scheme.equals("https", ignoreCase = true) &&
                uri.host.equals(InviteLinkContract.httpsHost, ignoreCase = true) &&
                uri.pathSegments.firstOrNull().equals("invite", ignoreCase = true)
        if (!isCustomInvite && !isHttpsInvite) return
        val codeIndex = if (isCustomInvite) 0 else 1
        val code = uri.pathSegments.getOrNull(codeIndex)
            ?.trim()
            ?.uppercase()
            ?.takeIf { it.matches(Regex("[A-Z0-9_-]{4,64}")) }
            ?: return
        InviteLinkContract.savePendingCode(this, code)
        if (::inviteLinkChannel.isInitialized) {
            inviteLinkChannel.invokeMethod("onInviteLinkAvailable", null)
        }
        Log.i("OneOneInvite", "Invite link captured codeSuffix=${code.takeLast(4)}")
    }

    @Suppress("DEPRECATION")
    private fun logFirebaseRuntimeConfiguration() {
        try {
            val firebaseApp = FirebaseApp.getInstance()
            val options = firebaseApp.options
            val applicationInfo = packageManager.getApplicationInfo(
                packageName,
                PackageManager.GET_META_DATA,
            )
            val installationIdEnabled = applicationInfo.metaData?.getBoolean(
                "firebase_messaging_installation_id_enabled",
                false,
            ) ?: false
            val buildType = if (
                applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0
            ) {
                "debug"
            } else {
                "release"
            }
            val googlePlayServicesVersion = try {
                packageManager.getPackageInfo("com.google.android.gms", 0).versionName
            } catch (_: PackageManager.NameNotFoundException) {
                "missing"
            }

            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-01] runtime configuration " +
                    "package=$packageName " +
                    "build=$buildType " +
                    "signingSha1=${signingCertificateSha1() ?: "unavailable"} " +
                    "firebaseAppId=${options.applicationId} " +
                    "projectId=${options.projectId} " +
                    "senderId=${options.gcmSenderId} " +
                    "installationIdEnabled=$installationIdEnabled " +
                    "autoInit=${FirebaseMessaging.getInstance().isAutoInitEnabled} " +
                    "googlePlayServices=$googlePlayServicesVersion",
            )
        } catch (error: RuntimeException) {
            VoiceNudgeDiagnostics.logFailure(
                "[FCM-E0] Firebase runtime configuration",
                error,
            )
        }
    }

    @Suppress("DEPRECATION")
    private fun signingCertificateSha1(): String? {
        val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.GET_SIGNING_CERTIFICATES,
            )
        } else {
            packageManager.getPackageInfo(packageName, PackageManager.GET_SIGNATURES)
        }
        val signature = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            packageInfo.signingInfo?.apkContentsSigners?.firstOrNull()
        } else {
            packageInfo.signatures?.firstOrNull()
        } ?: return null
        return MessageDigest.getInstance("SHA-1")
            .digest(signature.toByteArray())
            .joinToString(":") { byte -> "%02X".format(byte) }
    }
}
