package app.oneone.one_one_app

import android.app.Notification
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes as PlatformAudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.ArrayDeque
import java.util.concurrent.Executors
import kotlin.math.PI
import kotlin.math.sin

class VoiceNudgePlaybackService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val networkExecutor = Executors.newSingleThreadExecutor()
    private val queue = ArrayDeque<NudgeRequest>()
    private var active: NudgeRequest? = null
    private var player: ExoPlayer? = null
    private var ringTrack: AudioTrack? = null
    private var playbackWakeLock: PowerManager.WakeLock? = null

    // Nudge reliability checklist (#5): the receiver-side health snapshot for
    // whichever nudge is currently active, and a dedupe guard so a nudge is
    // ever only acknowledged once (played or failed), no matter how many
    // playback-state callbacks fire.
    private var activeHealth: NudgeHealthSnapshot? = null
    private var ackedEventId: String? = null
    private var lastPosted: PostedNotification? = null
    private var activeTimeout: Runnable? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        Log.d(VoiceNudgeDiagnostics.tag, "[FCM-D] Playback service created")
        VoiceNudgeAudioCache.deleteOrphans(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] onStartCommand action=${intent?.action ?: "null"} " +
                "startId=$startId flags=$flags",
        )
        val cachedRequest = intent?.toCachedRequest()
        when (intent?.action) {
            VoiceNudgeContract.actionStopGroupNudges -> {
                val groupId = intent.getStringExtra(VoiceNudgeContract.extraGroupId)
                Log.d(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-D] onStartCommand -> stopGroupNudges groupId=${groupId ?: "null"}",
                )
                stopGroupNudges(groupId ?: return START_NOT_STICKY)
                return START_NOT_STICKY
            }
            VoiceNudgeContract.actionPlayCachedAudio -> {
                if (cachedRequest == null) {
                    Log.w(
                        VoiceNudgeDiagnostics.tag,
                        "[FCM-D] playCachedAudio ignored: invalid cached request",
                    )
                    return START_NOT_STICKY
                }
                Log.d(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-D] onStartCommand -> playCachedAudio " +
                        "eventSuffix=${cachedRequest.eventId.takeLast(6)}",
                )
                if (
                    active?.eventId != cachedRequest.eventId &&
                    queue.none { it.eventId == cachedRequest.eventId }
                ) {
                    Log.d(
                        VoiceNudgeDiagnostics.tag,
                        "[FCM-D] playCachedAudio: adding to front of queue " +
                            "queueDepth=${queue.size + 1}",
                    )
                    queue.addFirst(cachedRequest)
                } else {
                    Log.d(
                        VoiceNudgeDiagnostics.tag,
                        "[FCM-D] playCachedAudio: already active/queued, skipping queue add",
                    )
                }
                processNext()
                return START_NOT_STICKY
            }
            VoiceNudgeContract.actionPauseCachedAudio -> {
                Log.d(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-D] onStartCommand -> pauseCachedAudio " +
                        "eventSuffix=${cachedRequest?.eventId?.takeLast(6) ?: "null"}",
                )
                if (cachedRequest != null) pauseCachedAudio(cachedRequest)
                return START_NOT_STICKY
            }
        }
        val request = intent?.toRequest()
        if (request == null) {
            Log.w(VoiceNudgeDiagnostics.tag, "[FCM-W6] Playback service received invalid intent")
            return START_NOT_STICKY
        }
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[FCM-10] Playback service accepted kind=${request.kind} " +
                "eventSuffix=${request.eventId.takeLast(6)}",
        )

        val isDuplicate =
            active?.eventId == request.eventId || queue.any { it.eventId == request.eventId }

        if (isDuplicate) {
            // The same nudge is already playing or already queued — don't
            // requeue it and don't repost its notification.
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] Duplicate nudge ignored kind=${request.kind} " +
                    "eventSuffix=${request.eventId.takeLast(6)}",
            )
            processNext()
            return START_NOT_STICKY
        }

        queue.add(request)
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] Nudge enqueued kind=${request.kind} " +
                "eventSuffix=${request.eventId.takeLast(6)} queueDepth=${queue.size} " +
                "active=${active?.eventId?.takeLast(6) ?: "none"}",
        )

        if (active == null) {
            // This nudge is about to be processed immediately, so promote the
            // service to the foreground with a "Preparing…" notification.
            startForegroundMediaPlayback(
                VoiceNudgeNotifications.idFor(request.eventId),
                notification(
                    request,
                    "Preparing nudge… 🎙️",
                    ongoing = true,
                    cachedAudioAvailable = false,
                ),
            )
            NotificationAvatarHelper.loadAsync(
                this,
                request.senderPhotoUrl,
                request.senderName,
                request.senderAvatarAsset,
            ) {
                refreshPostedNotification()
            }
        } else {
            // Another nudge is still active. Queue this one WITHOUT posting a
            // "Preparing…" foreground notification: doing so used to replace
            // the active nudge's notification, hide its play/pause controls,
            // and leave the queued nudge stuck on "Preparing nudge…" with no
            // Play button. processNext() posts the correct notification the
            // moment this nudge actually starts.
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-10A] Nudge queued behind active nudge " +
                    "kind=${request.kind} eventSuffix=${request.eventId.takeLast(6)} " +
                    "queueDepth=${queue.size}",
            )
            NotificationAvatarHelper.loadAsync(
                this,
                request.senderPhotoUrl,
                request.senderName,
                request.senderAvatarAsset,
            ) {
                // Warm the avatar cache only; the queued nudge has no posted
                // notification yet, so there is nothing to refresh.
            }
        }

        processNext()
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] Playback service destroyed queueDepth=${queue.size} " +
                "active=${active?.eventId?.takeLast(6) ?: "none"}",
        )
        mainHandler.removeCallbacksAndMessages(null)
        releasePlayback()
        releaseWakeLock()
        // Use shutdown() (not shutdownNow()) so in-flight download and ack
        // tasks can complete gracefully instead of being interrupted mid-IO.
        // The executor guard in acknowledge() prevents new submissions from
        // racing with teardown.
        networkExecutor.shutdown()
        super.onDestroy()
    }

    /**
     * Starts the playback foreground service as media playback only.
     *
     * This service's real job is playing nudge audio, so it must not request
     * the "microphone" foreground-service type. Starting a microphone FGS
     * (which Android 14+ infers from the manifest when using the two-argument
     * `startForeground`) requires both the runtime `RECORD_AUDIO` permission
     * and, on Android 15+ (targetSdk 36), that the app be in an eligible
     * foreground state. A nudge arrives via FCM while the app is backgrounded,
     * so a microphone FGS can never satisfy those checks and crashes the
     * process with a SecurityException. Playback itself only needs
     * `mediaPlayback`.
     */
    private fun startForegroundMediaPlayback(notificationId: Int, notification: Notification) {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] startForeground notificationId=$notificationId sdk=${Build.VERSION.SDK_INT}",
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                notificationId,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(notificationId, notification)
        }
    }

    private fun stopGroupNudges(groupId: String) {
        val removed = queue.count { it.groupId == groupId }
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] stopGroupNudges groupId=$groupId queueDepth=${queue.size} " +
                "removing=$removed activeGroupId=${active?.groupId ?: "none"}",
        )
        queue.removeAll { it.groupId == groupId }
        val current = active
        if (current?.groupId == groupId) {
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] stopGroupNudges: active nudge matches group, tearing down " +
                    "eventSuffix=${current.eventId.takeLast(6)}",
            )
            releasePlayback()
            releaseWakeLock()
            active = null
            clearActiveTimeout()
            VoiceNudgeAudioCache.delete(this, current.eventId)
            getSystemService(NotificationManager::class.java).cancel(
                VoiceNudgeNotifications.idFor(current.eventId),
            )
        }
        if (active == null && queue.isEmpty()) {
            Log.d(VoiceNudgeDiagnostics.tag, "[FCM-D] stopGroupNudges: queue empty, stopping self")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
        } else if (active == null) {
            processNext()
        }
    }

    private fun processNext() {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] processNext active=${active?.eventId?.takeLast(6) ?: "none"} " +
                "queueDepth=${queue.size}",
        )
        if (active != null || queue.isEmpty()) return
        val request = queue.removeFirst()
        active = request
        ackedEventId = null
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] processNext: activating kind=${request.kind} " +
                "eventSuffix=${request.eventId.takeLast(6)} cachedReplay=${request.cachedReplay} " +
                "durationMs=${request.durationMs}",
        )
        activeHealth = captureHealthSnapshot(
            if (request.kind == VoiceNudgeContract.kindRing) {
                AudioManager.STREAM_ALARM
            } else {
                AudioManager.STREAM_MUSIC
            },
        )
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[FCM-11] Processing queued nudge kind=${request.kind}",
        )
        holdWakeLock()
        scheduleActiveTimeout(request)
        val initialStatus = when {
            request.kind == VoiceNudgeContract.kindRing -> "Ringing… 🔔"
            request.cachedReplay -> "Preparing replay… ▶️"
            else -> "Downloading voice nudge… 🎙️"
        }
        startForegroundMediaPlayback(
            VoiceNudgeNotifications.idFor(request.eventId),
            notification(
                request,
                initialStatus,
                ongoing = true,
                cachedAudioAvailable = request.cachedReplay,
            ),
        )
        if (request.kind == VoiceNudgeContract.kindRing) {
            Log.d(VoiceNudgeDiagnostics.tag, "[FCM-D] processNext -> playRing")
            playRing(request)
        } else if (request.cachedReplay) {
            val file = VoiceNudgeAudioCache.file(this, request.eventId)
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] processNext -> cachedReplay file=${file.path} " +
                    "exists=${file.isFile} bytes=${if (file.isFile) file.length() else -1}",
            )
            if (file.isFile && file.length() > 0) {
                startPlayer(request, file)
            } else {
                Log.w(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-D] cachedReplay file missing/empty, failing nudge",
                )
                finishActive(success = false)
            }
        } else {
            Log.d(VoiceNudgeDiagnostics.tag, "[FCM-D] processNext -> downloadAndPlay")
            downloadAndPlay(request)
        }
    }

    private fun playRing(request: NudgeRequest) {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] playRing entry durationMs=${request.durationMs}",
        )
        try {
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-12] Starting ring durationMs=${request.durationMs}",
            )
            val samples = buildNudgeRing(request.durationMs)
            val attributes = PlatformAudioAttributes.Builder()
                .setUsage(PlatformAudioAttributes.USAGE_ALARM)
                .setContentType(PlatformAudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setSampleRate(ringSampleRate)
                .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .build()
            @Suppress("DEPRECATION")
            ringTrack = AudioTrack(
                attributes,
                format,
                samples.size * 2,
                AudioTrack.MODE_STATIC,
                AudioManager.AUDIO_SESSION_ID_GENERATE,
            ).also { track ->
                val written = track.write(samples, 0, samples.size)
                check(written == samples.size) {
                    "Nudge ring buffer write failed: $written/${samples.size} samples"
                }
                track.setVolume(0.86f)
                track.play()
            }
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] playRing: AudioTrack playing samples=${samples.size}",
            )
            // Ring audio is a static buffer that starts outputting the instant
            // play() returns, so this is genuinely "playing now" — fire the
            // delivery ack + haptics immediately rather than waiting for the
            // buffer to finish.
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] playRing: sending played ack + scheduling finish in ${request.durationMs}ms",
            )
            sendPlayedAckOnce(request)
            // The PCM buffer itself is exactly the requested length. This
            // callback owns service and notification cleanup at that boundary.
            mainHandler.postDelayed(
                { finishActive(success = true) },
                request.durationMs,
            )
        } catch (error: RuntimeException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E4] Ring playback", error)
            VoiceNudgeDiagnostics.recordNudgeFailure(
                reason = "playback_error",
                eventId = request.eventId,
                kind = request.kind,
                extras = mapOf("error" to (error.message ?: "unknown")),
                groupId = request.groupId,
                senderUserId = request.senderUserId,
                senderName = request.senderName,
                health = activeHealth?.toCrashlyticsMap().orEmpty(),
            )
            acknowledge(request, "failed", "playback_error", activeHealth) {
                finishActive(success = false)
            }
        }
    }

    /**
     * Builds Duo's own ring instead of delegating to the phone ringtone.
     * Each phrase is two short rising chimes followed by breathing space.
     */
    private fun buildNudgeRing(durationMs: Long): ShortArray {
        val sampleCount = ((durationMs * ringSampleRate) / 1_000L).toInt()
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] buildNudgeRing durationMs=$durationMs sampleCount=$sampleCount",
        )
        return ShortArray(sampleCount) { sampleIndex ->
            val elapsedMs = sampleIndex * 1_000.0 / ringSampleRate
            val phraseMs = elapsedMs % ringPhraseMs
            val pulse = when {
                phraseMs < 190.0 -> RingPulse(phraseMs, 190.0, 784.0, 1_176.0)
                phraseMs >= 250.0 && phraseMs < 520.0 ->
                    RingPulse(phraseMs - 250.0, 270.0, 988.0, 1_482.0)
                else -> null
            }
            if (pulse == null) {
                0
            } else {
                val phraseEnvelope = pulseEnvelope(pulse.elapsedMs, pulse.durationMs)
                val finalFade = ((durationMs - elapsedMs) / 45.0).coerceIn(0.0, 1.0)
                val envelope = phraseEnvelope * finalFade
                val seconds = elapsedMs / 1_000.0
                val fundamental = sin(2.0 * PI * pulse.frequencyHz * seconds)
                val harmonic = sin(2.0 * PI * pulse.harmonicHz * seconds) * 0.24
                ((fundamental + harmonic) * envelope * Short.MAX_VALUE * 0.56)
                    .toInt()
                    .coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
                    .toShort()
            }
        }
    }

    private fun pulseEnvelope(elapsedMs: Double, durationMs: Double): Double {
        val attack = (elapsedMs / 18.0).coerceIn(0.0, 1.0)
        val release = ((durationMs - elapsedMs) / 55.0).coerceIn(0.0, 1.0)
        return attack * release
    }

    private fun downloadAndPlay(request: NudgeRequest) {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] downloadAndPlay scheduling download eventSuffix=${request.eventId.takeLast(6)}",
        )
        networkExecutor.execute {
            try {
                val file = downloadAudio(request)
                Log.i(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-13] Voice audio downloaded bytes=${file.length()}",
                )
                Log.d(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-D] downloadAndPlay: download complete, posting startPlayer to main",
                )
                mainHandler.post { startPlayer(request, file) }
            } catch (error: Exception) {
                VoiceNudgeDiagnostics.logFailure("[FCM-E5] Voice audio download", error)
                VoiceNudgeDiagnostics.recordNudgeFailure(
                    reason = "download_error",
                    eventId = request.eventId,
                    kind = request.kind,
                    extras = mapOf("error" to (error.message ?: "unknown")),
                    groupId = request.groupId,
                    senderUserId = request.senderUserId,
                    senderName = request.senderName,
                    health = activeHealth?.toCrashlyticsMap().orEmpty(),
                )
                acknowledge(request, "failed", "download_error", activeHealth) {
                    finishActive(success = false)
                }
            }
        }
    }

    private fun downloadAudio(request: NudgeRequest): File {
        val output = VoiceNudgeAudioCache.file(this, request.eventId)
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] downloadAudio target=${output.path} " +
                "url=${request.audioUrl?.substringAfterLast('/')?.take(24) ?: "null"}",
        )
        if (output.isFile && output.length() > 0) {
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] downloadAudio: cache hit bytes=${output.length()}, reusing file",
            )
            VoiceNudgeAudioCache.register(this, request.eventId)
            return output
        }

        var currentUrl = requireNotNull(request.audioUrl) { "Missing audio URL" }
        var redirects = 0
        while (true) {
            val connection = URL(currentUrl).openConnection() as HttpURLConnection
            // Manual redirects so the delivery-token header is never forwarded
            // to Cloud Storage signed URLs (would break V4 signature checks).
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 8_000
            connection.readTimeout = 8_000
            connection.requestMethod = "GET"
            connection.setRequestProperty("accept", "audio/mp4")
            if (isBackendAudioProxyUrl(currentUrl)) {
                val deliveryToken = requireNotNull(request.deliveryToken) {
                    "Missing delivery token"
                }
                connection.setRequestProperty("x-one-one-delivery-token", deliveryToken)
            }
            try {
                val responseCode = connection.responseCode
                Log.i(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-13A] Voice audio HTTP response=$responseCode",
                )
                if (responseCode in 300..399) {
                    val location = connection.getHeaderField("Location")
                        ?: throw IllegalStateException("Audio redirect missing Location")
                    if (redirects >= 3) {
                        throw IllegalStateException("Too many audio download redirects")
                    }
                    Log.d(
                        VoiceNudgeDiagnostics.tag,
                        "[FCM-D] downloadAudio: redirect #${redirects + 1} to " +
                            "${location.substringAfterLast('/').take(24)}",
                    )
                    currentUrl = location
                    redirects += 1
                    continue
                }
                if (responseCode !in 200..299) {
                    throw IllegalStateException("Audio download failed with HTTP $responseCode")
                }
                val partial = File(output.path + ".part")
                try {
                    connection.inputStream.use { input ->
                        FileOutputStream(partial).use { sink ->
                        val buffer = ByteArray(8 * 1024)
                        var total = 0
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            total += count
                            if (total > maxAudioBytes) {
                                throw IllegalStateException("Voice nudge is too large")
                            }
                            sink.write(buffer, 0, count)
                        }
                        if (total == 0) throw IllegalStateException("Voice nudge is empty")
                        }
                    }
                    check(partial.renameTo(output)) { "Could not finalize voice nudge cache" }
                    VoiceNudgeAudioCache.register(this, request.eventId)
                    Log.d(
                        VoiceNudgeDiagnostics.tag,
                        "[FCM-D] downloadAudio: finalized cache bytes=${output.length()}",
                    )
                } catch (error: Exception) {
                    partial.delete()
                    throw error
                }
                return output
            } finally {
                connection.disconnect()
            }
        }
    }

    private fun isBackendAudioProxyUrl(url: String): Boolean {
        return url.contains("/v1/voice-nudges/") && url.contains("/audio")
    }

    private fun startPlayer(request: NudgeRequest, file: File) {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] startPlayer entry eventSuffix=${request.eventId.takeLast(6)} " +
                "file=${file.path} bytes=${file.length()} cachedReplay=${request.cachedReplay}",
        )
        if (active?.eventId != request.eventId) {
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] startPlayer: stale request, active is " +
                    "${active?.eventId?.takeLast(6) ?: "none"}, aborting",
            )
            return
        }
        notify(
            request,
            "Playing voice nudge…",
            cachedAudioAvailable = true,
            isPlaying = true,
        )
        Log.i(VoiceNudgeDiagnostics.tag, "[FCM-14] Preparing voice audio player")
        player = ExoPlayer.Builder(this).build().apply {
            // handleAudioFocus = false: play through regardless of audio-focus
            // state, matching how ring nudges play via AudioTrack. On some
            // Android 15 devices (e.g. Moto g64 5G / MediaTek), ExoPlayer's
            // default focus handling pauses playback on focus loss/denial and
            // never resumes, leaving the nudge stalled with no STATE_ENDED and
            // no playback error — so the watchdog times it out instead of the
            // nudge playing. A short voice nudge should just play like a ring.
            setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(C.USAGE_MEDIA)
                    .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
                    .build(),
                false,
            )
            setWakeMode(C.WAKE_MODE_LOCAL)
            addListener(object : Player.Listener {
                override fun onIsPlayingChanged(isPlaying: Boolean) {
                    Log.d(
                        VoiceNudgeDiagnostics.tag,
                        "[FCM-D] ExoPlayer onIsPlayingChanged isPlaying=$isPlaying",
                    )
                    // "Genuinely played" means audio has actually started
                    // outputting — not merely delivered/downloaded — so the ack
                    // fires here, the moment ExoPlayer's isPlaying flips true,
                    // rather than waiting for playback to finish.
                    if (isPlaying && !request.cachedReplay) {
                        sendPlayedAckOnce(request)
                    }
                    if (isPlaying) {
                        // Playback has genuinely started, so the clip must end
                        // within its duration plus a short grace. Re-arming the
                        // watchdog here recovers quickly from an audio-focus /
                        // codec stall that otherwise never fires STATE_ENDED.
                        schedulePlaybackEndTimeout(request)
                    }
                }

                override fun onPlaybackStateChanged(playbackState: Int) {
                    Log.d(
                        VoiceNudgeDiagnostics.tag,
                        "[FCM-D] ExoPlayer onPlaybackStateChanged state=${playbackStateName(playbackState)}",
                    )
                    when (playbackState) {
                        Player.STATE_READY -> {
                            // Prepared and about to play. Arm the tight end-timeout
                            // here as well so a decoder stall that never flips
                            // isPlaying (or never reaches STATE_ENDED) still
                            // recovers quickly rather than waiting out the 60s
                            // download window.
                            schedulePlaybackEndTimeout(request)
                        }
                        Player.STATE_ENDED -> {
                            Log.i(VoiceNudgeDiagnostics.tag, "[FCM-15] Voice playback completed")
                            VoiceNudgeAudioCache.clearPosition(
                                this@VoiceNudgePlaybackService,
                                request.eventId,
                            )
                            finishActive(success = true)
                        }
                    }
                }

                override fun onPlayerError(error: PlaybackException) {
                    Log.d(
                        VoiceNudgeDiagnostics.tag,
                        "[FCM-D] ExoPlayer onPlayerError errorCode=${error.errorCodeName} " +
                            "message=${error.message}",
                    )
                    VoiceNudgeDiagnostics.logFailure("[FCM-E6] Voice playback", error)
                    VoiceNudgeDiagnostics.recordNudgeFailure(
                        reason = "playback_error",
                        eventId = request.eventId,
                        kind = request.kind,
                        extras = mapOf(
                            "error" to (error.errorCodeName),
                            "cached_replay" to request.cachedReplay.toString(),
                        ),
                        groupId = request.groupId,
                        senderUserId = request.senderUserId,
                        senderName = request.senderName,
                        health = activeHealth?.toCrashlyticsMap().orEmpty(),
                    )
                    VoiceNudgeAudioCache.delete(
                        this@VoiceNudgePlaybackService,
                        request.eventId,
                    )
                    if (request.cachedReplay || ackedEventId == request.eventId) {
                        finishActive(success = false)
                    } else {
                        acknowledge(request, "failed", "playback_error", activeHealth) {
                            finishActive(success = false)
                        }
                    }
                }
            })
            setMediaItem(MediaItem.fromUri(Uri.fromFile(file)))
            prepare()
            if (request.cachedReplay) {
                seekTo(
                    VoiceNudgeAudioCache.position(
                        this@VoiceNudgePlaybackService,
                        request.eventId,
                    ),
                )
            }
            play()
        }
    }

    private fun pauseCachedAudio(request: NudgeRequest) {
        val current = active
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] pauseCachedAudio eventSuffix=${request.eventId.takeLast(6)} " +
                "active=${current?.eventId?.takeLast(6) ?: "none"} " +
                "position=${player?.currentPosition ?: -1}ms",
        )
        if (current?.eventId == request.eventId) {
            val position = player?.currentPosition ?: 0
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] pauseCachedAudio: saving position ${position}ms and releasing playback",
            )
            VoiceNudgeAudioCache.savePosition(this, request.eventId, position)
            releasePlayback()
            active = null
            clearActiveTimeout()
            releaseWakeLock()
            if (!current.cachedReplay && ackedEventId != current.eventId) {
                ackedEventId = current.eventId
                Log.d(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-D] pauseCachedAudio: acking played before finishing pause",
                )
                acknowledge(current, "played", null, activeHealth) { finishPause(request) }
                return
            }
        }
        finishPause(request)
    }

    private fun finishPause(request: NudgeRequest) {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] finishPause eventSuffix=${request.eventId.takeLast(6)} " +
                "queueDepth=${queue.size}",
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_DETACH)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(false)
        }
        getSystemService(NotificationManager::class.java).notify(
            VoiceNudgeNotifications.idFor(request.eventId),
            notification(
                request,
                "Paused ⏸️",
                ongoing = false,
                cachedAudioAvailable = true,
            ),
        )
        if (queue.isEmpty()) {
            stopSelf()
        } else {
            processNext()
        }
    }

    private fun acknowledge(
        request: NudgeRequest,
        status: String,
        reason: String?,
        health: NudgeHealthSnapshot?,
        attention: String? = null,
        after: () -> Unit,
    ) {
        val ackUrl = request.ackUrl
        val deliveryToken = request.deliveryToken
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] acknowledge status=$status reason=${reason ?: "none"} " +
                "eventSuffix=${request.eventId.takeLast(6)} " +
                "hasAckUrl=${ackUrl != null} hasToken=${deliveryToken != null}",
        )
        if (ackUrl == null || deliveryToken == null) {
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] acknowledge: missing ack URL/token, skipping network ack",
            )
            mainHandler.post(after)
            return
        }
        // Guard: if the service is shutting down and the executor has already
        // been terminated, log a warning and bail out rather than throwing a
        // RejectedExecutionException.
        if (networkExecutor.isShutdown || networkExecutor.isTerminated) {
            Log.w(
                VoiceNudgeDiagnostics.tag,
                "[FCM-W9] Delivery ack skipped — executor is shut down " +
                    "eventSuffix=${request.eventId.takeLast(6)}",
            )
            mainHandler.post(after)
            return
        }
        networkExecutor.execute {
            var connection: HttpURLConnection? = null
            try {
                Log.d(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-D] acknowledge: posting ack to ${ackUrl.substringAfterLast('/').take(24)}",
                )
                val opened = URL(ackUrl).openConnection() as HttpURLConnection
                connection = opened
                opened.connectTimeout = 5_000
                opened.readTimeout = 5_000
                opened.requestMethod = "POST"
                opened.doOutput = true
                opened.setRequestProperty("content-type", "application/json")
                opened.setRequestProperty("x-one-one-delivery-token", deliveryToken)
                val body = JSONObject().apply {
                    put("status", status)
                    if (reason != null) put("reason", reason)
                    if (health != null) put("health", health.toJson())
                    // Audibility concern for an otherwise-successful playback
                    // (mute / very-low volume). Distinct from `reason`, which
                    // only accompanies a genuine `failed`.
                    if (attention != null) put("attention", attention)
                }
                opened.outputStream.use { it.write(body.toString().toByteArray()) }
                val responseCode = opened.responseCode
                Log.i(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-16] Delivery acknowledgement status=$status " +
                        "reason=${reason ?: "none"} HTTP=$responseCode",
                )
            } catch (error: Exception) {
                VoiceNudgeDiagnostics.logFailure("[FCM-E7] Delivery acknowledgement", error)
            } finally {
                connection?.disconnect()
                mainHandler.post(after)
            }
        }
    }

    /**
     * Fires the delivery ack the instant a nudge genuinely starts producing
     * audio, and triggers matching haptic feedback. Guarded so a single
     * nudge only ever acks once, however many playback-state callbacks fire.
     *
     * Delivery status is a pure reflection of whether playback genuinely
     * started (ring buffer began outputting, or ExoPlayer's isPlaying flipped
     * true). Audibility concerns — mute, very-low volume — are NOT delivery
     * failures; they are reported as a separate `attention` flag so the sender
     * can tell "never received" apart from "received but probably not heard".
     */
    private fun sendPlayedAckOnce(request: NudgeRequest) {
        if (ackedEventId == request.eventId) {
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] sendPlayedAckOnce: already acked, skipping " +
                    "eventSuffix=${request.eventId.takeLast(6)}",
            )
            return
        }
        ackedEventId = request.eventId
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] sendPlayedAckOnce: marking played eventSuffix=${request.eventId.takeLast(6)}",
        )

        val health = activeHealth
        val attention = health?.attentionReason()
        if (attention != null && health != null) {
            Log.i(
                VoiceNudgeDiagnostics.tag,
                "[FCM-14A] Playback started with audibility concern=$attention " +
                    "streamVolume=${health.streamVolume}/${health.streamMaxVolume} " +
                    "eventSuffix=${request.eventId.takeLast(6)}",
            )
        }
        acknowledge(request, "played", null, health, attention) {}
        triggerReceiptHaptics(durationMsForHaptics(request))
    }

    private fun durationMsForHaptics(request: NudgeRequest): Long {
        if (request.kind == VoiceNudgeContract.kindRing) return request.durationMs
        val playerDuration = player?.duration ?: C.TIME_UNSET
        return (if (playerDuration > 0) playerDuration else request.durationMs.takeIf { it > 0 } ?: 6_000L)
            .also {
                Log.d(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-D] durationMsForHaptics playerDuration=$playerDuration -> $it",
                )
            }
    }

    /**
     * Haptic feedback: one long vibration when the nudge starts playing,
     * and one long vibration when it finishes.  No vibration in between
     * so the buzz does not interfere with listening to the voice message.
     *
     * Timing:
     *   - opening burst: ~600 ms (two taps: 150 ms on / 100 ms off / 150 ms on,
     *     repeated twice for a longer-feeling single pulse)
     *   - closing burst: same pattern, scheduled after the audio duration
     */
    private fun triggerReceiptHaptics(durationMs: Long) {
        Log.d(VoiceNudgeDiagnostics.tag, "[FCM-D] triggerReceiptHaptics durationMs=$durationMs")
        val vibrator = (
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                getSystemService(VibratorManager::class.java)?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Vibrator::class.java)
            }
            ) ?: return
        if (!vibrator.hasVibrator()) return

        // A longer-feeling opening burst: two quick taps repeated so the
        // user unmistakably feels "something started playing".  Total ~600 ms.
        val openBurst = longArrayOf(0, 150, 100, 150, 100, 150) // wait, buzz, pause, buzz, pause, buzz

        // Closing burst: identical pattern so the user feels "playback is done".
        val closeBurst = longArrayOf(0, 150, 100, 150, 100, 150)

        // With no sustained middle phase, the closing burst delay is simply
        // the audio duration (minus the tiny opening overhead so timing feels
        // exact).  Floor of 500 ms so very short nudges still get a distinct
        // closing pulse.
        val openDurationMs = openBurst.fold(0L) { acc, v -> acc + v }
        val closeDelayMs = (durationMs - openDurationMs).coerceAtLeast(500L)

        try {
            // Phase 1 — Opening long burst
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator.vibrate(
                    VibrationEffect.createWaveform(openBurst, -1),
                )
            } else {
                @Suppress("DEPRECATION")
                vibrator.vibrate(openBurst, -1)
            }

            // Phase 2 — Closing long burst (fires after audio finishes)
            mainHandler.postDelayed({
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        vibrator.vibrate(
                            VibrationEffect.createWaveform(closeBurst, -1),
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        vibrator.vibrate(closeBurst, -1)
                    }
                } catch (error: RuntimeException) {
                    VoiceNudgeDiagnostics.logFailure(
                        "[FCM-E12B] Closing haptics",
                        error,
                    )
                }
            }, closeDelayMs)

            // Cancel any leftover haptics after the full envelope.
            val totalEnvelopeMs = openDurationMs + closeDelayMs + closeBurst.fold(0L) { acc, v -> acc + v }
            mainHandler.postDelayed(
                { vibrator.cancel() },
                totalEnvelopeMs.coerceAtMost(30_000L),
            )
        } catch (error: RuntimeException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E12] Opening haptics", error)
        }
    }

    private fun cancelHaptics() {
        try {
            val vibrator = (
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    getSystemService(VibratorManager::class.java)?.defaultVibrator
                } else {
                    @Suppress("DEPRECATION")
                    getSystemService(Vibrator::class.java)
                }
            )
            vibrator?.cancel()
        } catch (_: RuntimeException) {
            // Best-effort cancel.
        }
    }

    /**
     * Nudge reliability checklist (#5): conditions on the receiver's device,
     * checked right as a nudge starts processing, that determine whether it
     * is actually likely to be heard. Only checks that are reliably readable
     * without extra runtime permissions are included here. Notably NOT
     * detectable from inside the app: whether this app process itself was
     * force-stopped/killed before this service ever got a chance to run —
     * Android gives a killed process no code path to report its own death,
     * so that case can only ever be inferred indirectly (e.g. no ack ever
     * arriving, which the backend already treats as "unknown" outcome).
     */
    private data class NudgeHealthSnapshot(
        val streamVolume: Int,
        val streamMaxVolume: Int,
        val streamMuted: Boolean,
        val ringerMode: Int,
        val notificationsEnabled: Boolean,
    ) {
        /**
         * Coarse audibility band, kept deliberately separate from whether
         * playback genuinely started. A muted/very-low receiver still
         * "received" the nudge — the audio pipeline ran — so these must never
         * be reported as a delivery failure. They are surfaced as an
         * attention flag the sender can act on instead.
         */
        val volumeLevel: String
            get() = when {
                streamMuted || streamVolume <= 0 -> "muted"
                streamVolume <= lowVolumeStep() -> "very_low"
                else -> "ok"
            }

        /**
         * Primary listening concern for an otherwise-successful playback.
         * Reported separately from a delivery failure so a muted/very-low
         * device is never mislabeled as "did not receive".
         */
        fun attentionReason(): String? = when {
            streamMuted || streamVolume <= 0 -> "volume_muted"
            streamVolume <= lowVolumeStep() -> "volume_low"
            else -> null
        }

        /** Bottom ~20% of the volume range counts as "very low", minimum one step. */
        private fun lowVolumeStep(): Int =
            (streamMaxVolume * 0.20).toInt().coerceAtLeast(1)

        fun toJson(): JSONObject = JSONObject().apply {
            put("streamVolume", streamVolume)
            put("streamMaxVolume", streamMaxVolume)
            put("streamMuted", streamMuted)
            put("ringerMode", ringerMode)
            put("notificationsEnabled", notificationsEnabled)
            put("volumeLevel", volumeLevel)
        }

        /** Flat string map for Crashlytics custom keys (prefixed `health_`). */
        fun toCrashlyticsMap(): Map<String, String> = mapOf(
            "streamVolume" to streamVolume.toString(),
            "streamMaxVolume" to streamMaxVolume.toString(),
            "streamMuted" to streamMuted.toString(),
            "ringerMode" to ringerMode.toString(),
            "notificationsEnabled" to notificationsEnabled.toString(),
            "volumeLevel" to volumeLevel,
        )
    }

    private fun captureHealthSnapshot(streamType: Int): NudgeHealthSnapshot {
        val audioManager = getSystemService(AudioManager::class.java)
        val notificationManager = getSystemService(NotificationManager::class.java)
        val muted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.isStreamMute(streamType)
        } else {
            audioManager.getStreamVolume(streamType) == 0
        }
        val notificationsEnabled = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            notificationManager.areNotificationsEnabled()
        } else {
            true
        }
        val snapshot = NudgeHealthSnapshot(
            streamVolume = audioManager.getStreamVolume(streamType),
            streamMaxVolume = audioManager.getStreamMaxVolume(streamType),
            streamMuted = muted,
            ringerMode = audioManager.ringerMode,
            notificationsEnabled = notificationsEnabled,
        )
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] captureHealthSnapshot streamType=$streamType " +
                "volume=${snapshot.streamVolume}/${snapshot.streamMaxVolume} " +
                "muted=${snapshot.streamMuted} ringerMode=${snapshot.ringerMode} " +
                "notificationsEnabled=${snapshot.notificationsEnabled} volumeLevel=${snapshot.volumeLevel}",
        )
        return snapshot
    }

    private fun finishActive(success: Boolean) {
        val request = active
        if (request == null) {
            Log.d(VoiceNudgeDiagnostics.tag, "[FCM-D] finishActive: no active nudge, no-op")
            return
        }
        Log.i(
            VoiceNudgeDiagnostics.tag,
            "[FCM-17] Nudge finished kind=${request.kind} success=$success",
        )
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] finishActive: releasing playback queueDepth=${queue.size} " +
                "eventSuffix=${request.eventId.takeLast(6)}",
        )
        releasePlayback()
        active = null
        clearActiveTimeout()
        val manager = getSystemService(NotificationManager::class.java)
        val cachedAudioAvailable = shouldRetainNotificationAudio(
            success = success,
            kind = request.kind,
            fileExists = VoiceNudgeAudioCache.file(this, request.eventId).isFile,
        )
        val finalStatus = when {
            !success -> "Nudge could not be played ⚠️"
            request.kind == VoiceNudgeContract.kindRing ->
                "${request.durationMs / 1000}-second ring received 🔔"
            else -> "Voice nudge received 🎙️"
        }
        if (queue.isEmpty()) {
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] finishActive: queue empty, detaching foreground and stopping self",
            )
            releaseWakeLock()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_DETACH)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(false)
            }
            manager.notify(
                VoiceNudgeNotifications.idFor(request.eventId),
                notification(
                    request,
                    finalStatus,
                    ongoing = false,
                    cachedAudioAvailable = cachedAudioAvailable,
                ),
            )
            stopSelf()
        } else {
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] finishActive: more queued, posting final notification and processing next",
            )
            manager.notify(
                VoiceNudgeNotifications.idFor(request.eventId),
                notification(
                    request,
                    finalStatus,
                    ongoing = false,
                    cachedAudioAvailable = cachedAudioAvailable,
                ),
            )
            processNext()
        }
    }

    private fun releasePlayback() {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] releasePlayback hasPlayer=${player != null} hasRingTrack=${ringTrack != null}",
        )
        player?.release()
        player = null
        try {
            ringTrack?.stop()
        } catch (_: IllegalStateException) {
            // A completed static track may already be stopped.
        }
        ringTrack?.release()
        ringTrack = null
        cancelHaptics()
    }

    private fun holdWakeLock() {
        try {
            val lock = playbackWakeLock ?: run {
                val powerManager = getSystemService(PowerManager::class.java)
                powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "$packageName:VoiceNudgePlayback",
                ).apply {
                    setReferenceCounted(false)
                    playbackWakeLock = this
                }
            }
            Log.d(
                VoiceNudgeDiagnostics.tag,
                "[FCM-D] holdWakeLock: acquiring for ${maxWakeLockDurationMs}ms",
            )
            if (lock.isHeld) lock.release()
            lock.acquire(maxWakeLockDurationMs)
            Log.i(VoiceNudgeDiagnostics.tag, "[FCM-11A] Playback wake lock acquired")
        } catch (error: RuntimeException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E8] Playback wake lock", error)
        }
    }

    private fun releaseWakeLock() {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] releaseWakeLock held=${playbackWakeLock?.isHeld == true}",
        )
        try {
            playbackWakeLock?.takeIf { it.isHeld }?.release()
        } catch (error: RuntimeException) {
            VoiceNudgeDiagnostics.logFailure("[FCM-E9] Playback wake lock release", error)
        }
    }

    /**
     * Guarantees a queued nudge can never be blocked forever behind an active
     * nudge whose finish callback was lost (e.g. a dropped `STATE_ENDED` or a
     * hung download). If the active nudge is still going after a generous,
     * kind-appropriate window, force-finish it so [processNext] drains the
     * queue and the next nudge actually plays.
     */
    private fun scheduleActiveTimeout(request: NudgeRequest) {
        clearActiveTimeout()
        val timeoutMs = when {
            request.kind == VoiceNudgeContract.kindRing -> request.durationMs + 15_000L
            request.cachedReplay -> 45_000L
            // Voice: download (with redirects + connect/read timeouts) + ≤10s playback.
            else -> 60_000L
        }
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] scheduleActiveTimeout kind=${request.kind} timeoutMs=$timeoutMs",
        )
        armTimeout(request, timeoutMs)
    }

    /**
     * Once audio is genuinely outputting, the clip must end within its own
     * duration plus a short grace period. Replacing the (much looser) download
     * window here means an audio-focus / codec stall — where `isPlaying` flips
     * true but `STATE_ENDED` never fires — recovers in ~25s instead of a full
     * minute, so a queued nudge isn't left waiting behind a dead-but-active
     * nudge.
     */
    private fun schedulePlaybackEndTimeout(request: NudgeRequest) {
        clearActiveTimeout()
        // Cached replays carry durationMs = 0; their audio is still capped at
        // 10s, so a 25s window leaves ample headroom.
        val timeoutMs = if (request.durationMs > 0) request.durationMs + 15_000L else 25_000L
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] schedulePlaybackEndTimeout durationMs=${request.durationMs} timeoutMs=$timeoutMs",
        )
        armTimeout(request, timeoutMs)
    }

    private fun armTimeout(request: NudgeRequest, timeoutMs: Long) {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] armTimeout eventSuffix=${request.eventId.takeLast(6)} timeoutMs=$timeoutMs",
        )
        val timeout = Runnable {
            if (active?.eventId == request.eventId) {
                Log.w(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-W11] Active nudge timed out kind=${request.kind} " +
                        "eventSuffix=${request.eventId.takeLast(6)}",
                )
                VoiceNudgeDiagnostics.recordNudgeFailure(
                    reason = "timeout",
                    eventId = request.eventId,
                    kind = request.kind,
                    extras = emptyMap(),
                    groupId = request.groupId,
                    senderUserId = request.senderUserId,
                    senderName = request.senderName,
                    health = activeHealth?.toCrashlyticsMap().orEmpty(),
                )
                finishActive(success = false)
            }
        }
        activeTimeout = timeout
        mainHandler.postDelayed(timeout, timeoutMs)
    }

    private fun clearActiveTimeout() {
        if (activeTimeout != null) {
            Log.d(VoiceNudgeDiagnostics.tag, "[FCM-D] clearActiveTimeout: cancelling pending timeout")
        }
        activeTimeout?.let { mainHandler.removeCallbacks(it) }
        activeTimeout = null
    }

    private fun playbackStateName(state: Int): String = when (state) {
        Player.STATE_IDLE -> "IDLE"
        Player.STATE_BUFFERING -> "BUFFERING"
        Player.STATE_READY -> "READY"
        Player.STATE_ENDED -> "ENDED"
        else -> "UNKNOWN($state)"
    }

    private fun notify(
        request: NudgeRequest,
        status: String,
        cachedAudioAvailable: Boolean = false,
        isPlaying: Boolean = false,
    ) {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] notify status=\"$status\" eventSuffix=${request.eventId.takeLast(6)} " +
                "cachedAudioAvailable=$cachedAudioAvailable isPlaying=$isPlaying",
        )
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(
            VoiceNudgeNotifications.idFor(request.eventId),
            notification(
                request,
                status,
                ongoing = true,
                cachedAudioAvailable = cachedAudioAvailable,
                isPlaying = isPlaying,
            ),
        )
    }

    private fun notification(
        request: NudgeRequest,
        status: String,
        ongoing: Boolean,
        cachedAudioAvailable: Boolean,
        isPlaying: Boolean = false,
    ): Notification {
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] notification status=\"$status\" ongoing=$ongoing " +
                "eventSuffix=${request.eventId.takeLast(6)}",
        )
        lastPosted = PostedNotification(
            request = request,
            status = status,
            ongoing = ongoing,
            cachedAudioAvailable = cachedAudioAvailable,
            isPlaying = isPlaying,
        )
        return VoiceNudgeNotifications.build(
            this,
            request.eventId,
            request.groupId,
            request.responseUrl,
            request.senderName,
            status,
            ongoing,
            cachedAudioAvailable,
            isPlaying,
            largeIcon = NotificationAvatarHelper.largeIcon(
                this,
                request.senderPhotoUrl,
                request.senderName,
                request.senderAvatarAsset,
            ),
        )
    }

    private fun refreshPostedNotification() {
        val posted = lastPosted
        if (posted == null) {
            Log.d(VoiceNudgeDiagnostics.tag, "[FCM-D] refreshPostedNotification: nothing posted yet")
            return
        }
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] refreshPostedNotification eventSuffix=${posted.request.eventId.takeLast(6)}",
        )
        try {
            val manager = getSystemService(NotificationManager::class.java)
            val notificationId = VoiceNudgeNotifications.idFor(posted.request.eventId)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val stillShowing = manager.activeNotifications.any { it.id == notificationId }
                if (!stillShowing) return
            }
            manager.notify(
                notificationId,
                notification(
                    posted.request,
                    posted.status,
                    posted.ongoing,
                    posted.cachedAudioAvailable,
                    posted.isPlaying,
                ),
            )
        } catch (_: Exception) {
            // Service may already have stopped.
        }
    }

    private fun Intent.toRequest(): NudgeRequest? {
        val kind = getStringExtra(VoiceNudgeContract.extraKind) ?: run {
            Log.d(VoiceNudgeDiagnostics.tag, "[FCM-D] toRequest: missing kind, ignoring intent")
            return null
        }
        val eventId = getStringExtra(VoiceNudgeContract.extraEventId) ?: run {
            Log.d(VoiceNudgeDiagnostics.tag, "[FCM-D] toRequest: missing eventId, ignoring intent")
            return null
        }
        val senderName = getStringExtra(VoiceNudgeContract.extraSenderName) ?: "Someone"
        val suppliedDurationMs = getLongExtra(VoiceNudgeContract.extraDurationMs, 0)
        val durationMs = if (kind == VoiceNudgeContract.kindRing) {
            suppliedDurationMs.takeIf { it in supportedRingDurationsMs } ?: run {
                Log.d(
                    VoiceNudgeDiagnostics.tag,
                    "[FCM-D] toRequest: unsupported ring duration $suppliedDurationMs, ignoring",
                )
                return null
            }
        } else {
            suppliedDurationMs.coerceIn(250, 10_000)
        }
        val groupId = getStringExtra(VoiceNudgeContract.extraGroupId) ?: run {
            Log.d(VoiceNudgeDiagnostics.tag, "[FCM-D] toRequest: missing groupId, ignoring intent")
            return null
        }
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] toRequest parsed kind=$kind eventSuffix=${eventId.takeLast(6)} " +
                "durationMs=$durationMs cachedReplay=false",
        )
        return NudgeRequest(
            kind = kind,
            eventId = eventId,
            senderName = senderName,
            senderUserId = getStringExtra(VoiceNudgeContract.extraSenderUserId),
            senderPhotoUrl = getStringExtra(VoiceNudgeContract.extraSenderPhotoUrl),
            senderAvatarAsset = getStringExtra(VoiceNudgeContract.extraSenderAvatarAsset),
            durationMs = durationMs,
            audioUrl = getStringExtra(VoiceNudgeContract.extraAudioUrl),
            ackUrl = getStringExtra(VoiceNudgeContract.extraAckUrl),
            deliveryToken = getStringExtra(VoiceNudgeContract.extraDeliveryToken),
            groupId = groupId,
            responseUrl = getStringExtra(VoiceNudgeContract.extraResponseUrl),
            cachedReplay = false,
        )
    }

    private fun Intent.toCachedRequest(): NudgeRequest? {
        val eventId = getStringExtra(VoiceNudgeContract.extraEventId) ?: return null
        val groupId = getStringExtra(VoiceNudgeContract.extraGroupId) ?: return null
        Log.d(
            VoiceNudgeDiagnostics.tag,
            "[FCM-D] toCachedRequest parsed eventSuffix=${eventId.takeLast(6)} cachedReplay=true",
        )
        return NudgeRequest(
            kind = VoiceNudgeContract.kindVoice,
            eventId = eventId,
            senderName = getStringExtra(VoiceNudgeContract.extraSenderName) ?: "Someone",
            senderUserId = getStringExtra(VoiceNudgeContract.extraSenderUserId),
            senderPhotoUrl = getStringExtra(VoiceNudgeContract.extraSenderPhotoUrl),
            senderAvatarAsset = getStringExtra(VoiceNudgeContract.extraSenderAvatarAsset),
            durationMs = 0,
            audioUrl = null,
            ackUrl = null,
            deliveryToken = null,
            groupId = groupId,
            responseUrl = getStringExtra(VoiceNudgeContract.extraResponseUrl),
            cachedReplay = true,
        )
    }

    private data class PostedNotification(
        val request: NudgeRequest,
        val status: String,
        val ongoing: Boolean,
        val cachedAudioAvailable: Boolean,
        val isPlaying: Boolean,
    )

    private data class NudgeRequest(
        val kind: String,
        val eventId: String,
        val senderName: String,
        val senderUserId: String?,
        val senderPhotoUrl: String?,
        val senderAvatarAsset: String?,
        val durationMs: Long,
        val audioUrl: String?,
        val ackUrl: String?,
        val deliveryToken: String?,
        val groupId: String,
        val responseUrl: String?,
        val cachedReplay: Boolean,
    )

    private data class RingPulse(
        val elapsedMs: Double,
        val durationMs: Double,
        val frequencyHz: Double,
        val harmonicHz: Double,
    )

    companion object {
        private const val ringSampleRate = 44_100
        private const val ringPhraseMs = 900.0
        private val supportedRingDurationsMs = setOf(3_000L, 5_000L, 10_000L)
        private const val maxAudioBytes = 128 * 1024
        private const val maxWakeLockDurationMs = 30_000L
    }
}

internal fun shouldRetainNotificationAudio(
    success: Boolean,
    kind: String,
    fileExists: Boolean,
): Boolean = success && kind == VoiceNudgeContract.kindVoice && fileExists

object VoiceNudgeAudioCache {
    private const val filePrefix = "voice_nudge_"
    private const val preferencesName = "one_one_voice_nudge_playback"
    private const val eventIdsKey = "cached_event_ids"
    private const val staleAfterMs = 24 * 60 * 60 * 1_000L

    fun file(context: Context, eventId: String): File =
        File(context.cacheDir, "$filePrefix${eventId.safeFileName()}.m4a")

    fun position(context: Context, eventId: String): Long =
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .getLong(eventId.safeFileName(), 0)

    fun savePosition(context: Context, eventId: String, positionMs: Long) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .putLong(eventId.safeFileName(), positionMs.coerceAtLeast(0))
            .apply()
    }

    fun clearPosition(context: Context, eventId: String) {
        context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)
            .edit()
            .remove(eventId.safeFileName())
            .apply()
    }

    fun register(context: Context, eventId: String) {
        val preferences = context.getSharedPreferences(
            preferencesName,
            Context.MODE_PRIVATE,
        )
        val eventIds = preferences.getStringSet(eventIdsKey, emptySet())
            .orEmpty()
            .toMutableSet()
        eventIds.add(eventId)
        preferences.edit().putStringSet(eventIdsKey, eventIds).apply()
    }

    fun delete(context: Context, eventId: String) {
        val cached = file(context, eventId)
        cached.delete()
        File(cached.path + ".part").delete()
        val preferences = context.getSharedPreferences(
            preferencesName,
            Context.MODE_PRIVATE,
        )
        val eventIds = preferences.getStringSet(eventIdsKey, emptySet())
            .orEmpty()
            .toMutableSet()
        eventIds.remove(eventId)
        preferences.edit()
            .remove(eventId.safeFileName())
            .putStringSet(eventIdsKey, eventIds)
            .apply()
    }

    fun deleteOrphans(context: Context) {
        val preferences = context.getSharedPreferences(
            preferencesName,
            Context.MODE_PRIVATE,
        )
        val eventIds = preferences.getStringSet(eventIdsKey, emptySet()).orEmpty()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val activeNotificationIds = context
                .getSystemService(NotificationManager::class.java)
                .activeNotifications
                .mapTo(mutableSetOf()) { it.id }
            eventIds
                .filter { VoiceNudgeNotifications.idFor(it) !in activeNotificationIds }
                .forEach { delete(context, it) }
            return
        }

        val cutoff = System.currentTimeMillis() - staleAfterMs
        // ponytail: API 22 cannot inspect active notifications; remove stale
        // files after 24 hours instead. Drop API 22 to remove this fallback.
        context.cacheDir.listFiles()
            ?.filter {
                it.name.startsWith(filePrefix) &&
                    it.lastModified() < cutoff
            }
            ?.forEach(File::delete)
    }

    private fun String.safeFileName() = replace(Regex("[^A-Za-z0-9_-]"), "_")
}

class VoiceNudgeCacheDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != VoiceNudgeContract.actionDismissCachedAudio) return
        val eventId = intent.getStringExtra(VoiceNudgeContract.extraEventId) ?: return
        VoiceNudgeAudioCache.delete(context, eventId)
    }
}
