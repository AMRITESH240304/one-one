// Standalone preview/tuning harness for the emoji reaction burst effect.
//
// Run with:
//   flutter run -t lib/dev/emoji_burst_preview_main.dart
//
// Lets you trigger the OLD single-emoji reaction and the NEW streaming burst
// side by side against the same dark backdrop, and live-tune count / spread /
// speed so a change can be compared before wiring it into the real call
// screen (identity_home_screen.dart). Has no Firebase/LiveKit dependency, so
// it launches instantly on any device or simulator.
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

import '../features/talk/models/emoji_burst.dart';
import '../features/talk/models/in_call_reaction.dart';
import '../features/talk/ui/emoji_burst_overlay.dart';
import '../features/talk/ui/in_call_reaction_overlay.dart';

void main() {
  runApp(const _EmojiBurstPreviewApp());
}

class _EmojiBurstPreviewApp extends StatelessWidget {
  const _EmojiBurstPreviewApp();

  @override
  Widget build(BuildContext context) {
    return ScreenUtilInit(
      designSize: const Size(393, 873),
      minTextAdapt: true,
      builder: (context, child) => const MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Emoji burst preview',
        home: _EmojiBurstPreviewScreen(),
      ),
    );
  }
}

const _quickEmojis = <String>['😂', '❤️', '🔥', '👏', '🎉', '💯'];

class _EmojiBurstPreviewScreen extends StatefulWidget {
  const _EmojiBurstPreviewScreen();

  @override
  State<_EmojiBurstPreviewScreen> createState() =>
      _EmojiBurstPreviewScreenState();
}

class _EmojiBurstPreviewScreenState extends State<_EmojiBurstPreviewScreen> {
  String _emoji = _quickEmojis.first;
  int _sequence = 0;

  List<InCallReaction> _legacyBubbles = const [];
  List<EmojiBurst> _bursts = const [];

  // Directly mirrors EmojiBurstConfig fields so every tunable knob in the
  // real effect is reachable here.
  int _particleCount = EmojiBurstConfig.standard.particleCount;
  double _spreadWidth = EmojiBurstConfig.standard.spreadWidth;
  double _riseHeight = EmojiBurstConfig.standard.riseHeight;
  int _minDurationMs = EmojiBurstConfig.standard.minDurationMs;
  int _maxDurationMs = EmojiBurstConfig.standard.maxDurationMs;
  int _staggerMs = EmojiBurstConfig.standard.staggerMs;
  double _minEmojiSize = EmojiBurstConfig.standard.minEmojiSize;
  double _maxEmojiSize = EmojiBurstConfig.standard.maxEmojiSize;
  double _wobbleAmplitude = EmojiBurstConfig.standard.wobbleAmplitude;

  EmojiBurstConfig get _config => EmojiBurstConfig(
    particleCount: _particleCount,
    spreadWidth: _spreadWidth,
    riseHeight: _riseHeight,
    minDurationMs: _minDurationMs,
    maxDurationMs: _maxDurationMs,
    staggerMs: _staggerMs,
    minEmojiSize: _minEmojiSize,
    maxEmojiSize: _maxEmojiSize,
    wobbleAmplitude: _wobbleAmplitude,
  );

  String get _nextId => 'preview-${_sequence++}';

  void _resetToStandard() {
    setState(() {
      final config = EmojiBurstConfig.standard;
      _particleCount = config.particleCount;
      _spreadWidth = config.spreadWidth;
      _riseHeight = config.riseHeight;
      _minDurationMs = config.minDurationMs;
      _maxDurationMs = config.maxDurationMs;
      _staggerMs = config.staggerMs;
      _minEmojiSize = config.minEmojiSize;
      _maxEmojiSize = config.maxEmojiSize;
      _wobbleAmplitude = config.wobbleAmplitude;
    });
  }

  void _triggerLegacySingle() {
    final id = _nextId;
    final reaction = InCallReaction(
      id: id,
      userId: 'preview',
      displayName: 'you',
      text: _emoji,
      sentAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _legacyBubbles = [reaction]);
    Future.delayed(const Duration(milliseconds: 2900), () {
      if (!mounted) return;
      setState(
        () => _legacyBubbles = _legacyBubbles
            .where((item) => item.id != id)
            .toList(growable: false),
      );
    });
  }

  void _triggerBurst() {
    final burst = EmojiBurst(id: _nextId, emoji: _emoji, senderName: 'you', config: _config);
    setState(() => _bursts = [..._bursts, burst]);
  }

  void _onBurstFinished(String id) {
    if (!mounted) return;
    setState(
      () => _bursts = _bursts.where((item) => item.id != id).toList(growable: false),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              flex: 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xff101010), Color(0xff1c1c1c)],
                      ),
                    ),
                  ),
                  const Center(
                    child: Text(
                      'preview stage',
                      style: TextStyle(color: Colors.white24, fontSize: 12),
                    ),
                  ),
                  if (_legacyBubbles.isNotEmpty)
                    InCallReactionOverlay(reactions: _legacyBubbles),
                  if (_bursts.isNotEmpty)
                    EmojiBurstOverlay(
                      bursts: _bursts,
                      onBurstFinished: _onBurstFinished,
                    ),
                  Positioned(
                    left: 12,
                    top: 12,
                    child: _Pill(
                      text: _legacyBubbles.isNotEmpty
                          ? 'OLD: single emoji'
                          : _bursts.isNotEmpty
                          ? 'NEW: burst (${_config.particleCount}x)'
                          : 'tap a trigger below',
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 4,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                decoration: const BoxDecoration(
                  color: Color(0xff141414),
                  border: Border(top: BorderSide(color: Colors.white12)),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Emoji burst tuner',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          TextButton(
                            onPressed: _resetToStandard,
                            child: const Text('Reset to standard'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final emoji in _quickEmojis)
                            ChoiceChip(
                              label: Text(emoji, style: const TextStyle(fontSize: 18)),
                              selected: _emoji == emoji,
                              onSelected: (_) => setState(() => _emoji = emoji),
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _triggerLegacySingle,
                              child: const Text('Trigger OLD (single)'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: _triggerBurst,
                              child: const Text('Trigger NEW (burst)'),
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 28, color: Colors.white12),
                      _TuneSlider(
                        label: 'Count',
                        value: _particleCount.toDouble(),
                        min: 1,
                        max: 30,
                        divisions: 29,
                        valueLabel: '$_particleCount',
                        onChanged: (v) => setState(() => _particleCount = v.round()),
                      ),
                      _TuneSlider(
                        label: 'Spread',
                        value: _spreadWidth,
                        min: 0,
                        max: 1,
                        divisions: 20,
                        valueLabel: _spreadWidth.toStringAsFixed(2),
                        onChanged: (v) => setState(() => _spreadWidth = v),
                      ),
                      _TuneSlider(
                        label: 'Rise height',
                        value: _riseHeight,
                        min: 0.2,
                        max: 1,
                        divisions: 16,
                        valueLabel: _riseHeight.toStringAsFixed(2),
                        onChanged: (v) => setState(() => _riseHeight = v),
                      ),
                      _TuneSlider(
                        label: 'Min duration (ms)',
                        value: _minDurationMs.toDouble(),
                        min: 300,
                        max: _maxDurationMs.toDouble(),
                        divisions: 27,
                        valueLabel: '$_minDurationMs',
                        onChanged: (v) => setState(() => _minDurationMs = v.round()),
                      ),
                      _TuneSlider(
                        label: 'Max duration (ms)',
                        value: _maxDurationMs.toDouble(),
                        min: _minDurationMs.toDouble(),
                        max: 3000,
                        divisions: 27,
                        valueLabel: '$_maxDurationMs',
                        onChanged: (v) => setState(() => _maxDurationMs = v.round()),
                      ),
                      _TuneSlider(
                        label: 'Stagger (ms) - speed of stream',
                        value: _staggerMs.toDouble(),
                        min: 0,
                        max: 200,
                        divisions: 20,
                        valueLabel: '$_staggerMs',
                        onChanged: (v) => setState(() => _staggerMs = v.round()),
                      ),
                      _TuneSlider(
                        label: 'Wobble amplitude',
                        value: _wobbleAmplitude,
                        min: 0,
                        max: 40,
                        divisions: 20,
                        valueLabel: _wobbleAmplitude.toStringAsFixed(0),
                        onChanged: (v) => setState(() => _wobbleAmplitude = v),
                      ),
                      _TuneSlider(
                        label: 'Min emoji size',
                        value: _minEmojiSize,
                        min: 10,
                        max: _maxEmojiSize,
                        divisions: 20,
                        valueLabel: _minEmojiSize.toStringAsFixed(0),
                        onChanged: (v) => setState(() => _minEmojiSize = v),
                      ),
                      _TuneSlider(
                        label: 'Max emoji size',
                        value: _maxEmojiSize,
                        min: _minEmojiSize,
                        max: 72,
                        divisions: 20,
                        valueLabel: _maxEmojiSize.toStringAsFixed(0),
                        onChanged: (v) => setState(() => _maxEmojiSize = v),
                      ),
                      Text(
                        'Total burst duration: ${_config.totalDurationMs}ms',
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TuneSlider extends StatelessWidget {
  const _TuneSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              valueLabel,
              textAlign: TextAlign.end,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white70, fontSize: 11)),
    );
  }
}
