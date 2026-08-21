import 'package:flutter/material.dart';

import '../groups/models/group_member_summary.dart';
import '../identity/ui/profile_avatar.dart';

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

/// Everything the PiP overlay needs to render and act.
class LiveSessionOverlayData {
  const LiveSessionOverlayData({
    required this.activeSpeaker,
    required this.isMuted,
    required this.onToggleMute,
    required this.accentColor,
  });

  final GroupMemberSummary activeSpeaker;
  final bool isMuted;
  final VoidCallback onToggleMute;
  final Color accentColor;

  LiveSessionOverlayData copyWith({
    GroupMemberSummary? activeSpeaker,
    bool? isMuted,
    VoidCallback? onToggleMute,
    Color? accentColor,
  }) {
    return LiveSessionOverlayData(
      activeSpeaker: activeSpeaker ?? this.activeSpeaker,
      isMuted: isMuted ?? this.isMuted,
      onToggleMute: onToggleMute ?? this.onToggleMute,
      accentColor: accentColor ?? this.accentColor,
    );
  }
}

// ---------------------------------------------------------------------------
// Controller — singleton ValueNotifier
// ---------------------------------------------------------------------------

/// Controls the in-app floating live-session PiP overlay.
///
/// The home screen calls [setSession] when the local user is live and another
/// route is pushed on top, and [clearSession] when the session ends or the
/// home screen becomes the active top-level route again.
class LiveSessionOverlayController {
  LiveSessionOverlayController._();

  static final LiveSessionOverlayController instance =
      LiveSessionOverlayController._();

  final ValueNotifier<LiveSessionOverlayData?> state =
      ValueNotifier<LiveSessionOverlayData?>(null);

  void setSession(LiveSessionOverlayData data) => state.value = data;

  void updateSession(LiveSessionOverlayData data) {
    if (state.value != null) state.value = data;
  }

  void clearSession() => state.value = null;
}

// ---------------------------------------------------------------------------
// Floating PiP widget — placed directly as a Stack child in OneOneApp
// ---------------------------------------------------------------------------

/// Draggable floating overlay shown whenever the user is in a live session
/// and has navigated away from the home screen.
///
/// This widget must be a direct child of a [Stack] so that the [Positioned]
/// it builds is correctly interpreted by [RenderStack].
class LiveSessionFloatingPip extends StatefulWidget {
  const LiveSessionFloatingPip({
    super.key,
    required this.navigatorKey,
  });

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<LiveSessionFloatingPip> createState() => _LiveSessionFloatingPipState();
}

class _LiveSessionFloatingPipState extends State<LiveSessionFloatingPip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  LiveSessionOverlayData? _data;
  Offset _position = Offset.zero;
  bool _positioned = false;

  @override
  void initState() {
    super.initState();
    _data = LiveSessionOverlayController.instance.state.value;
    LiveSessionOverlayController.instance.state.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {
      _data = LiveSessionOverlayController.instance.state.value;
    });
  }

  @override
  void dispose() {
    LiveSessionOverlayController.instance.state
        .removeListener(_onSessionChanged);
    _pulseController.dispose();
    super.dispose();
  }

  void _returnToHome() {
    widget.navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  void _onDragUpdate(DragUpdateDetails details, Size screenSize) {
    const w = 172.0;
    const h = 64.0;
    const margin = 12.0;
    setState(() {
      _position = Offset(
        (_position.dx + details.delta.dx)
            .clamp(margin, screenSize.width - w - margin),
        (_position.dy + details.delta.dy)
            .clamp(margin, screenSize.height - h - margin),
      );
    });
  }

  Offset _defaultPosition(Size screenSize) {
    return Offset(screenSize.width - 172.0 - 16, screenSize.height - 64.0 - 120);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) return const SizedBox.shrink();

    final screenSize = MediaQuery.sizeOf(context);
    if (!_positioned) {
      _position = _defaultPosition(screenSize);
      _positioned = true;
    }

    return Positioned(
      left: _position.dx,
      top: _position.dy,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanUpdate: (d) => _onDragUpdate(d, screenSize),
        onTap: _returnToHome,
        child: _PipContainer(
          data: data,
          pulseController: _pulseController,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// PiP visual container
// ---------------------------------------------------------------------------

class _PipContainer extends StatelessWidget {
  const _PipContainer({
    required this.data,
    required this.pulseController,
  });

  final LiveSessionOverlayData data;
  final AnimationController pulseController;

  @override
  Widget build(BuildContext context) {
    final accent = data.accentColor;
    return Material(
      color: Colors.transparent,
      child: Container(
        width: 172,
        height: 60,
        decoration: BoxDecoration(
          color: const Color(0xee0e0e0e),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(
            color: const Color(0xff7CFF6B).withValues(alpha: 0.55),
            width: 1.5,
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 14,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              // Pulsing live dot
              AnimatedBuilder(
                animation: pulseController,
                builder: (context, _) {
                  final glow = 0.45 + 0.55 * pulseController.value;
                  return Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xff7CFF6B),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xff7CFF6B).withValues(alpha: glow),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(width: 5),
              const Text(
                'Live',
                style: TextStyle(
                  color: Color(0xff7CFF6B),
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 10),
              // Active speaker avatar
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: accent.withValues(alpha: 0.75),
                    width: 1.5,
                  ),
                ),
                child: ClipOval(
                  child: ProfileAvatar(
                    profilePhotoUrl: data.activeSpeaker.profilePhotoUrl,
                    profilePhotoBase64: data.activeSpeaker.profilePhotoBase64,
                    avatarAsset: data.activeSpeaker.avatarAsset,
                    radius: 17,
                    backgroundColor: const Color(0xff2a2a2a),
                    fallback: Text(
                      data.activeSpeaker.displayName.isEmpty
                          ? '?'
                          : data.activeSpeaker.displayName
                              .trim()
                              .substring(0, 1)
                              .toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              // Mute toggle button — does NOT navigate back, just toggles mic.
              GestureDetector(
                onTap: data.onToggleMute,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: data.isMuted
                        ? const Color(0xffff5a5f).withValues(alpha: 0.18)
                        : Colors.white.withValues(alpha: 0.08),
                    border: Border.all(
                      color: data.isMuted
                          ? const Color(0xffff5a5f).withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Icon(
                    data.isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                    color: data.isMuted
                        ? const Color(0xffff5a5f)
                        : Colors.white70,
                    size: 15,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
