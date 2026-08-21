import 'package:flutter_test/flutter_test.dart';
import 'package:one_one_app/features/online/audio_output_bridge.dart';

void main() {
  test('parses native audio-output state maps', () {
    expect(
      AudioOutputState.fromMap({'route': 'earpiece', 'muted': true}),
      const AudioOutputState(route: AudioOutputRoute.earpiece, muted: true),
    );
    expect(parseAudioOutputRoute('headset'), AudioOutputRoute.headset);
    expect(parseAudioOutputRoute('bluetooth'), AudioOutputRoute.bluetooth);
    expect(parseAudioOutputRoute(null), AudioOutputRoute.speaker);
    expect(parseAudioOutputRoute('unknown'), AudioOutputRoute.speaker);
  });

  test('resolves a single glyph from route and mute', () {
    expect(
      resolveAudioOutputGlyph(route: AudioOutputRoute.speaker, muted: false),
      AudioOutputGlyphKind.speaker,
    );
    expect(
      resolveAudioOutputGlyph(route: AudioOutputRoute.earpiece, muted: false),
      AudioOutputGlyphKind.earpiece,
    );
    expect(
      resolveAudioOutputGlyph(route: AudioOutputRoute.headset, muted: false),
      AudioOutputGlyphKind.headset,
    );
    expect(
      resolveAudioOutputGlyph(route: AudioOutputRoute.bluetooth, muted: false),
      AudioOutputGlyphKind.headset,
    );
    expect(
      resolveAudioOutputGlyph(route: AudioOutputRoute.speaker, muted: true),
      AudioOutputGlyphKind.muted,
    );
  });

  test('tooltips describe tap vs hold without the old swap overlay', () {
    expect(
      audioOutputTooltip(
        kind: AudioOutputGlyphKind.speaker,
        speakerPreferenceOn: true,
      ),
      contains('tap to switch to phone'),
    );
    expect(
      audioOutputTooltip(
        kind: AudioOutputGlyphKind.earpiece,
        speakerPreferenceOn: false,
      ),
      contains('tap to switch to speaker'),
    );
    expect(
      audioOutputTooltip(
        kind: AudioOutputGlyphKind.muted,
        speakerPreferenceOn: true,
      ),
      contains('tap to return to speaker'),
    );
  });
}
