package app.oneone.one_one_app

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

object VoiceOverlayContract {
    const val flutterChannel = "app.oneone/voice_overlay"
    const val methodAnnounceCallModeTimeout = "announceCallModeTimeout"
    const val methodWarmup = "warmup"
    const val callModeTimeoutAnnouncement =
        "Switching back to walkie-talkie mode. It's been fifteen minutes."
}

/** Speak only when the media stream is unmuted and has a non-zero volume. */
fun shouldSpeakVoiceOverlay(streamMuted: Boolean, streamVolume: Int): Boolean =
    !streamMuted && streamVolume > 0

/**
 * Speaks short in-app announcements over [AudioManager.STREAM_MUSIC] at the
 * current media volume. Never raises or lowers volume. Skips playback when
 * media is muted so a silent device stays silent.
 */
class VoiceOverlayAnnouncer(context: Context) {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val initializing = AtomicBoolean(false)
    private var tts: TextToSpeech? = null
    private var ready = false
    private var pendingText: String? = null

    fun warmup() {
        mainHandler.post { ensureEngine() }
    }

    fun announceCallModeTimeout() {
        speak(VoiceOverlayContract.callModeTimeoutAnnouncement)
    }

    fun shutdown() {
        mainHandler.post {
            pendingText = null
            ready = false
            initializing.set(false)
            tts?.stop()
            tts?.shutdown()
            tts = null
        }
    }

    private fun speak(text: String) {
        mainHandler.post {
            if (!mediaVolumeAllowsSpeech()) {
                DeviceLog.info(tag, "Skipping TTS: media volume muted")
                pendingText = null
                return@post
            }
            val engine = tts
            if (ready && engine != null) {
                speakNow(engine, text)
            } else {
                pendingText = text
                ensureEngine()
            }
        }
    }

    private fun mediaVolumeAllowsSpeech(): Boolean {
        val audioManager = appContext.getSystemService(AudioManager::class.java)
            ?: return false
        val muted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            audioManager.isStreamMute(AudioManager.STREAM_MUSIC)
        } else {
            false
        }
        val volume = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return shouldSpeakVoiceOverlay(muted, volume)
    }

    private fun ensureEngine() {
        if (tts != null || !initializing.compareAndSet(false, true)) return
        tts = TextToSpeech(appContext) { status ->
            mainHandler.post {
                initializing.set(false)
                val engine = tts
                if (status != TextToSpeech.SUCCESS || engine == null) {
                    DeviceLog.warn(tag, "TTS engine failed to initialize status=$status")
                    tts?.shutdown()
                    tts = null
                    ready = false
                    pendingText = null
                    return@post
                }
                applyLanguage(engine)
                engine.setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                    override fun onStart(utteranceId: String?) = Unit
                    override fun onDone(utteranceId: String?) = Unit
                    override fun onError(utteranceId: String?) {
                        DeviceLog.warn(tag, "TTS utterance error id=$utteranceId")
                    }
                })
                ready = true
                val pending = pendingText
                pendingText = null
                if (pending != null) {
                    if (!mediaVolumeAllowsSpeech()) {
                        DeviceLog.info(tag, "Skipping TTS after init: media volume muted")
                    } else {
                        speakNow(engine, pending)
                    }
                }
            }
        }
    }

    private fun applyLanguage(engine: TextToSpeech) {
        val result = engine.setLanguage(Locale.US)
        if (result == TextToSpeech.LANG_MISSING_DATA ||
            result == TextToSpeech.LANG_NOT_SUPPORTED
        ) {
            engine.language = Locale.getDefault()
        }
    }

    private fun speakNow(engine: TextToSpeech, text: String) {
        val params = Bundle().apply {
            putInt(TextToSpeech.Engine.KEY_PARAM_STREAM, AudioManager.STREAM_MUSIC)
        }
        val result = engine.speak(
            text,
            TextToSpeech.QUEUE_FLUSH,
            params,
            utteranceId,
        )
        if (result != TextToSpeech.SUCCESS) {
            DeviceLog.warn(tag, "TTS speak() failed result=$result")
        } else {
            DeviceLog.info(tag, "Playing call-mode timeout overlay")
        }
    }

    companion object {
        private const val tag = "VoiceOverlay"
        private const val utteranceId = "call_mode_timeout"
    }
}
