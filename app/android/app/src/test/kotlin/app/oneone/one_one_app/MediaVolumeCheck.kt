package app.oneone.one_one_app

fun main() {
    check(mediaVolumePercent(streamMuted = true, streamVolume = 5, streamMaxVolume = 15) == 0)
    check(mediaVolumePercent(streamMuted = false, streamVolume = 0, streamMaxVolume = 15) == 0)
    check(mediaVolumePercent(streamMuted = false, streamVolume = 3, streamMaxVolume = 15) == 20)
    check(mediaVolumePercent(streamMuted = false, streamVolume = 8, streamMaxVolume = 15) == 53)
    check(mediaVolumeBand(0) == "muted")
    check(mediaVolumeBand(24) == "very_low")
    check(mediaVolumeBand(25) == "low")
    check(mediaVolumeBand(49) == "low")
    check(mediaVolumeBand(50) == "ok")
    check(mediaVolumeAttention(0) == "volume_muted")
    check(mediaVolumeAttention(24) == "volume_very_low")
    check(mediaVolumeAttention(49) == "volume_low")
    check(mediaVolumeAttention(50) == null)
}
