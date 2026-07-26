import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

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
  const DelayedLoadingIndicator({super.key, required this.child});

  final Widget child;

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
    _timer = Timer(startupLoadingThreshold, () {
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
