package app.oneone.one_one_app

import android.content.Context
import android.database.ContentObserver
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings

object AudioOutputContract {
    const val flutterChannel = "app.oneone/audio_output"
    const val methodGetState = "getState"
    const val methodSetMuted = "setMuted"
    const val methodSetProximityMonitoring = "setProximityMonitoring"
    const val methodOnStateChanged = "onStateChanged"
}

/** Mirrors [AudioDeviceInfo] type ints so unit checks don't need the SDK. */
const val DEVICE_BUILTIN_EARPIECE = 1
const val DEVICE_BUILTIN_SPEAKER = 2
const val DEVICE_WIRED_HEADSET = 3
const val DEVICE_WIRED_HEADPHONES = 4
const val DEVICE_BLUETOOTH_SCO = 7
const val DEVICE_BLUETOOTH_A2DP = 8
const val DEVICE_USB_DEVICE = 11
const val DEVICE_HEARING_AID = 23
const val DEVICE_USB_HEADSET = 22
const val DEVICE_BLE_HEADSET = 26
const val DEVICE_BLE_SPEAKER = 27

fun audioOutputRoute(
    communicationDeviceType: Int?,
    speakerphoneOn: Boolean,
    bluetoothScoOn: Boolean,
    wiredHeadsetOn: Boolean,
    bluetoothA2dpOn: Boolean,
): String {
    if (communicationDeviceType != null) {
        return when (communicationDeviceType) {
            DEVICE_BUILTIN_SPEAKER, DEVICE_BLE_SPEAKER -> "speaker"
            DEVICE_BUILTIN_EARPIECE -> "earpiece"
            DEVICE_BLUETOOTH_SCO,
            DEVICE_BLUETOOTH_A2DP,
            DEVICE_BLE_HEADSET,
            -> "bluetooth"
            DEVICE_WIRED_HEADSET,
            DEVICE_WIRED_HEADPHONES,
            DEVICE_USB_HEADSET,
            DEVICE_USB_DEVICE,
            DEVICE_HEARING_AID,
            -> "headset"
            else -> if (speakerphoneOn) "speaker" else "earpiece"
        }
    }
    return when {
        bluetoothScoOn || bluetoothA2dpOn -> "bluetooth"
        wiredHeadsetOn -> "headset"
        speakerphoneOn -> "speaker"
        else -> "earpiece"
    }
}

object AudioOutput {
    fun readState(context: Context): Map<String, Any> {
        return mapOf(
            "route" to currentRoute(context),
            "muted" to MediaVolume.isMuted(context),
        )
    }

    fun currentRoute(context: Context): String {
        val audioManager = context.getSystemService(AudioManager::class.java)
        val communicationType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            audioManager.communicationDevice?.type
        } else {
            null
        }
        @Suppress("DEPRECATION")
        return audioOutputRoute(
            communicationDeviceType = communicationType,
            speakerphoneOn = audioManager.isSpeakerphoneOn,
            bluetoothScoOn = audioManager.isBluetoothScoOn,
            wiredHeadsetOn = audioManager.isWiredHeadsetOn,
            bluetoothA2dpOn = audioManager.isBluetoothA2dpOn,
        )
    }
}

/**
 * Pushes route and mute changes to Flutter so the call-bar icon stays in
 * sync with headphones, Bluetooth, and hardware volume keys.
 */
class AudioOutputMonitor(
    private val context: Context,
    private val onChanged: () -> Unit,
) {
    private val handler = Handler(Looper.getMainLooper())
    private val emitRunnable = Runnable { onChanged() }
    private var started = false
    private var communicationListener: AudioManager.OnCommunicationDeviceChangedListener? = null

    private val deviceCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = schedule()
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) = schedule()
    }

    private val volumeObserver = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) = schedule()
    }

    fun start() {
        if (started) return
        started = true
        val audioManager = context.getSystemService(AudioManager::class.java)
        audioManager.registerAudioDeviceCallback(deviceCallback, handler)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val listener = AudioManager.OnCommunicationDeviceChangedListener { schedule() }
            communicationListener = listener
            audioManager.addOnCommunicationDeviceChangedListener(context.mainExecutor, listener)
        }
        context.contentResolver.registerContentObserver(
            Settings.System.CONTENT_URI,
            true,
            volumeObserver,
        )
    }

    fun stop() {
        if (!started) return
        started = false
        handler.removeCallbacks(emitRunnable)
        val audioManager = context.getSystemService(AudioManager::class.java)
        audioManager.unregisterAudioDeviceCallback(deviceCallback)
        val listener = communicationListener
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && listener != null) {
            audioManager.removeOnCommunicationDeviceChangedListener(listener)
        }
        communicationListener = null
        context.contentResolver.unregisterContentObserver(volumeObserver)
    }

    private fun schedule() {
        handler.removeCallbacks(emitRunnable)
        handler.postDelayed(emitRunnable, 80)
    }
}
