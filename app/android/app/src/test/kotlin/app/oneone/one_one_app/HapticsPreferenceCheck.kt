package app.oneone.one_one_app

fun main() {
    check(HapticsPreferenceStore.normalize(null) == HapticsPreferenceStore.light)
    check(HapticsPreferenceStore.normalize("LIGHT") == HapticsPreferenceStore.light)
    check(HapticsPreferenceStore.normalize("medium") == HapticsPreferenceStore.medium)
    check(HapticsPreferenceStore.normalize("wild") == HapticsPreferenceStore.wild)
    check(HapticsPreferenceStore.normalize("unknown") == HapticsPreferenceStore.light)

    check(NudgeHapticsWaveforms.lightBurst.contentEquals(longArrayOf(0, 150, 100, 150, 100, 150)))
    check(NudgeHapticsWaveforms.mediumBurst.contentEquals(longArrayOf(0, 80, 50, 80, 180, 80, 50, 80)))
    check(NudgeHapticsWaveforms.wildLoop.contentEquals(longArrayOf(0, 140, 70)))
    check(NudgeHapticsWaveforms.totalMs(NudgeHapticsWaveforms.lightBurst) == 650L)
}
