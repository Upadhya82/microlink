import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// Fades and lifts a list item into place, offset by its position so a list
/// settles in sequence rather than snapping in all at once.
///
/// Wrap list items with it and pass the builder's index. The delay is capped
/// (see [AppMotion.maxStaggerIndex]) so a long list never makes the user wait
/// for the effect to finish.
class StaggerIn extends StatefulWidget {
  final int index;
  final Widget child;

  /// How far the item travels up as it fades in.
  final double offsetY;

  const StaggerIn({
    super.key,
    required this.index,
    required this.child,
    this.offsetY = 14,
  });

  @override
  State<StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<StaggerIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
  );

  late final Animation<double> _animation = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.enter,
  );

  /// Held so it can be cancelled: the list may scroll this item away before
  /// its turn comes, and an uncancelled delay would stay pending after the
  /// widget was disposed.
  Timer? _startTimer;

  @override
  void initState() {
    super.initState();
    final delay = AppMotion.staggerDelay(widget.index);
    if (delay == Duration.zero) {
      _controller.forward();
    } else {
      _startTimer = Timer(delay, _controller.forward);
    }
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Opacity(
          opacity: _animation.value,
          child: Transform.translate(
            offset: Offset(0, widget.offsetY * (1 - _animation.value)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}
