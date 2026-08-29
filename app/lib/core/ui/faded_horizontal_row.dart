import 'package:one_one_app/one_one.dart';

/// Dark blur that fades a horizontal carousel into the adjacent chrome.
///
/// Same treatment as the join/create group switcher: profiles sliding under
/// a pinned trailing control read as "more people this way."
class HorizontalEdgeVeil extends StatelessWidget {
  const HorizontalEdgeVeil({super.key, required this.leftEdge});

  final bool leftEdge;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (bounds) => LinearGradient(
          begin: leftEdge ? Alignment.centerLeft : Alignment.centerRight,
          end: leftEdge ? Alignment.centerRight : Alignment.centerLeft,
          colors: const [Colors.white, Color(0x99FFFFFF), Colors.transparent],
          stops: const [0, 0.35, 1],
        ).createShader(bounds),
        child: ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
            child: const ColoredBox(color: Colors.transparent),
          ),
        ),
      ),
    );
  }
}

/// Horizontal list that can pin [leading]/[trailing] and fades overflowing
/// children with [HorizontalEdgeVeil].
class FadedHorizontalRow extends StatefulWidget {
  const FadedHorizontalRow({
    super.key,
    required this.height,
    required this.children,
    this.leading,
    this.trailing,
    this.listPadding,
    this.gap,
    this.veilWidth,
    this.clipBehavior = Clip.hardEdge,
  });

  final double height;
  final List<Widget> children;
  final Widget? leading;
  final Widget? trailing;
  final EdgeInsetsGeometry? listPadding;
  final double? gap;
  final double? veilWidth;
  final Clip clipBehavior;

  @override
  State<FadedHorizontalRow> createState() => _FadedHorizontalRowState();
}

class _FadedHorizontalRowState extends State<FadedHorizontalRow> {
  final ScrollController _controller = ScrollController();
  bool _fadeLeft = false;
  bool _fadeRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_syncFades);
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncFades());
  }

  @override
  void didUpdateWidget(covariant FadedHorizontalRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.children.length != widget.children.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncFades());
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_syncFades)
      ..dispose();
    super.dispose();
  }

  void _syncFades() {
    if (!mounted || !_controller.hasClients) return;
    final position = _controller.position;
    final fadeLeft = position.pixels > 2;
    final fadeRight =
        position.maxScrollExtent > 2 &&
        position.pixels < position.maxScrollExtent - 2;
    if (fadeLeft == _fadeLeft && fadeRight == _fadeRight) return;
    setState(() {
      _fadeLeft = fadeLeft;
      _fadeRight = fadeRight;
    });
  }

  @override
  Widget build(BuildContext context) {
    final gap = widget.gap ?? 8.w;
    final veilWidth = widget.veilWidth ?? 40.w;
    final list = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollUpdateNotification ||
            notification is ScrollMetricsNotification) {
          _syncFades();
        }
        return false;
      },
      child: ListView(
        controller: _controller,
        scrollDirection: Axis.horizontal,
        clipBehavior: widget.clipBehavior,
        padding: widget.listPadding,
        children: widget.children,
      ),
    );

    return SizedBox(
      height: widget.height,
      child: Row(
        children: [
          if (widget.leading != null) ...[widget.leading!, SizedBox(width: gap)],
          Expanded(
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: _fadeLeft || _fadeRight
                        ? ShaderMask(
                            blendMode: BlendMode.dstIn,
                            shaderCallback: (bounds) => LinearGradient(
                              colors: [
                                _fadeLeft ? Colors.transparent : Colors.white,
                                _fadeLeft
                                    ? const Color(0x40FFFFFF)
                                    : Colors.white,
                                Colors.white,
                                Colors.white,
                                _fadeRight
                                    ? const Color(0x40FFFFFF)
                                    : Colors.white,
                                _fadeRight ? Colors.transparent : Colors.white,
                              ],
                              stops: const [0, 0.08, 0.22, 0.78, 0.92, 1],
                            ).createShader(bounds),
                            child: list,
                          )
                        : list,
                  ),
                  if (_fadeLeft)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: veilWidth,
                      child: const HorizontalEdgeVeil(leftEdge: true),
                    ),
                  if (_fadeRight)
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: veilWidth,
                      child: const HorizontalEdgeVeil(leftEdge: false),
                    ),
                ],
              ),
            ),
          ),
          if (widget.trailing != null) ...[
            SizedBox(width: gap),
            widget.trailing!,
          ],
        ],
      ),
    );
  }
}
