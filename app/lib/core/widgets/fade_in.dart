import 'dart:async';

import 'package:flutter/material.dart';

/// A short, subtle fade + rise-in used when content finishes loading. Keep
/// this as the one place motion-on-load is defined so every screen feels
/// consistent.
class FadeIn extends StatefulWidget {
  final Widget child;
  final Duration duration;

  /// Waited out before the fade starts. Used to play one element after
  /// another instead of everything at once.
  final Duration delay;

  const FadeIn({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 280),
    this.delay = Duration.zero,
  });

  @override
  State<FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration);
  late final Animation<double> _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.02),
    end: Offset.zero,
  ).animate(_fade);

  /// Held so it can be cancelled: a bare Future.delayed stays pending after
  /// the widget is gone, which leaks and makes widget tests fail on
  /// "a Timer is still pending even after the widget tree was disposed".
  Timer? _startTimer;

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _startTimer = Timer(widget.delay, _controller.forward);
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
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}
