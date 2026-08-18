package app.oneone.one_one_app

fun main() {
    check(shouldSpeakVoiceOverlay(streamMuted = false, streamVolume = 5))
    check(!shouldSpeakVoiceOverlay(streamMuted = true, streamVolume = 5))
    check(!shouldSpeakVoiceOverlay(streamMuted = false, streamVolume = 0))
    check(!shouldSpeakVoiceOverlay(streamMuted = true, streamVolume = 0))
}
