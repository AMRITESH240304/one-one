import 'package:one_one_app/one_one.dart';

const startupLoadingThreshold = Duration(milliseconds: 500);

final Stopwatch appStartupClock = Stopwatch()..start();

void logStartupMilestone(String milestone, [Stopwatch? phase]) {
  debugPrint(
    '[Startup] $milestone '
    'app=${appStartupClock.elapsedMilliseconds}ms'
    '${phase == null ? '' : ' phase=${phase.elapsedMilliseconds}ms'}',
  );
}

class DelayedLoadingIndicator extends StatefulWidget {
  const DelayedLoadingIndicator({
    super.key,
    required this.child,
    this.threshold = startupLoadingThreshold,
  });

  final Widget child;

  /// How long to wait, with nothing shown, before revealing [child]. Defaults
  /// to [startupLoadingThreshold].
  final Duration threshold;

  @override
  State<DelayedLoadingIndicator> createState() =>
      _DelayedLoadingIndicatorState();
}

class _DelayedLoadingIndicatorState extends State<DelayedLoadingIndicator> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.threshold, () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _visible ? widget.child : const SizedBox.shrink();
}
