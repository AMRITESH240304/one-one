package app.oneone.one_one_app

fun main() {
    check(
        shouldRetainNotificationAudio(
            success = true,
            kind = VoiceNudgeContract.kindVoice,
            fileExists = true,
        ),
    )
    check(
        !shouldRetainNotificationAudio(
            success = false,
            kind = VoiceNudgeContract.kindVoice,
            fileExists = true,
        ),
    )
    check(
        !shouldRetainNotificationAudio(
            success = true,
            kind = VoiceNudgeContract.kindRing,
            fileExists = true,
        ),
    )
}
