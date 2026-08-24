import 'package:one_one_app/one_one.dart';

/// Height of the system navigation bar / home-indicator, in logical pixels.
///
/// Uses [MediaQueryData.padding] when the engine reports it, and falls back
/// to [MediaQueryData.viewPadding] when a parent (modal bottom sheets, or
/// Android edge-to-edge with a stripped `padding`) has zeroed it. While the
/// keyboard is visible, returns `padding.bottom` only so the nav-bar inset
/// is not stacked on top of [MediaQueryData.viewInsets].
double bottomSystemInsetOf(BuildContext context) {
  final media = MediaQuery.of(context);
  if (media.viewInsets.bottom > 0) {
    return media.padding.bottom;
  }
  return max(media.padding.bottom, media.viewPadding.bottom);
}

/// [MediaQuery] whose bottom [MediaQueryData.padding] is at least the live
/// system inset. Lets existing `SafeArea(bottom: true)` widgets protect
/// content on Android edge-to-edge without changing the top/status inset.
MediaQueryData withEnsuredBottomInset(MediaQueryData media) {
  if (media.viewInsets.bottom > 0) return media;
  final bottom = max(media.padding.bottom, media.viewPadding.bottom);
  if (bottom == media.padding.bottom) return media;
  return media.copyWith(padding: media.padding.copyWith(bottom: bottom));
}

/// Safe area that always clears the bottom system inset, including inside
/// modal bottom sheets where Flutter removes [MediaQueryData.padding].
///
/// Top inset is unchanged unless [top] is set to false.
class BottomSystemSafeArea extends StatelessWidget {
  const BottomSystemSafeArea({
    super.key,
    this.top = true,
    this.minimum = EdgeInsets.zero,
    required this.child,
  });

  final bool top;
  final EdgeInsets minimum;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final bottom = max(minimum.bottom, bottomSystemInsetOf(context));
    return SafeArea(
      top: top,
      bottom: false,
      minimum: minimum.copyWith(bottom: 0),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: child,
      ),
    );
  }
}
