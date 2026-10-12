import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// Scales a widget up into place with a slight overshoot, fading as it goes.
///
/// For the one element on a screen that should feel like it arrived rather
/// than was simply drawn -- a brand mark, a success tick, a badge. Overshoot
/// is attention-grabbing by design, so a screen gets at most one of these;
/// everything else uses the quieter [FadeIn].
class PopIn extends StatefulWidget {
  final Widget child;

  /// Waited out before the animation starts, for sequencing one element
  /// after another.
  final Duration delay;

  final Duration duration;

  /// Size at the start, as a fraction of the final size. Below about 0.5 the
  /// overshoot reads as a bounce rather than as the thing settling.
  final double from;

  const PopIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = AppMotion.slow,
    this.from = 0.72,
  });

  @override
  State<PopIn> createState() => _PopInState();
}

class _PopInState extends State<PopIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration);

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future.delayed(widget.delay, () {
        // The screen can be gone before the delay is up.
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // easeOutBack overshoots past 1 and comes back, which is the "pop".
    final scale = Tween<double>(begin: widget.from, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: AppMotion.emphasized),
    );
    // The fade finishes in the first half so the element is solid while it is
    // still settling -- fading all the way through makes it look uncertain.
    final fade = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0, 0.5, curve: AppMotion.enter),
    );

    return FadeTransition(
      opacity: fade,
      child: ScaleTransition(scale: scale, child: widget.child),
    );
  }
}
