package app.oneone.one_one_app

fun main() {
    check(
        audioOutputRoute(
            communicationDeviceType = DEVICE_BUILTIN_SPEAKER,
            speakerphoneOn = true,
            bluetoothScoOn = false,
            wiredHeadsetOn = false,
            bluetoothA2dpOn = false,
        ) == "speaker",
    )
    check(
        audioOutputRoute(
            communicationDeviceType = DEVICE_BUILTIN_EARPIECE,
            speakerphoneOn = false,
            bluetoothScoOn = false,
            wiredHeadsetOn = false,
            bluetoothA2dpOn = false,
        ) == "earpiece",
    )
    check(
        audioOutputRoute(
            communicationDeviceType = DEVICE_WIRED_HEADPHONES,
            speakerphoneOn = true,
            bluetoothScoOn = false,
            wiredHeadsetOn = true,
            bluetoothA2dpOn = false,
        ) == "headset",
    )
    check(
        audioOutputRoute(
            communicationDeviceType = DEVICE_BLUETOOTH_SCO,
            speakerphoneOn = false,
            bluetoothScoOn = true,
            wiredHeadsetOn = false,
            bluetoothA2dpOn = false,
        ) == "bluetooth",
    )
    check(
        audioOutputRoute(
            communicationDeviceType = null,
            speakerphoneOn = false,
            bluetoothScoOn = false,
            wiredHeadsetOn = true,
            bluetoothA2dpOn = false,
        ) == "headset",
    )
    check(
        audioOutputRoute(
            communicationDeviceType = null,
            speakerphoneOn = true,
            bluetoothScoOn = false,
            wiredHeadsetOn = false,
            bluetoothA2dpOn = false,
        ) == "speaker",
    )
    // Regression: on Android 12+ `communicationDevice` can still report the
    // built-in earpiece while a wired headset is plugged in. The presence flag
    // must win so the call-bar glyph flips to the headset icon.
    check(
        audioOutputRoute(
            communicationDeviceType = DEVICE_BUILTIN_EARPIECE,
            speakerphoneOn = false,
            bluetoothScoOn = false,
            wiredHeadsetOn = true,
            bluetoothA2dpOn = false,
        ) == "headset",
    )
    check(
        audioOutputRoute(
            communicationDeviceType = DEVICE_BUILTIN_SPEAKER,
            speakerphoneOn = true,
            bluetoothScoOn = false,
            wiredHeadsetOn = false,
            bluetoothA2dpOn = true,
        ) == "bluetooth",
    )
    check(isMediaMuted(streamMuted = true, streamVolume = 8))
    check(isMediaMuted(streamMuted = false, streamVolume = 0))
    check(!isMediaMuted(streamMuted = false, streamVolume = 3))
}
