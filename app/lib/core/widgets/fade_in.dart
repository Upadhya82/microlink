import 'package:flutter/material.dart';

/// A short, subtle fade + rise-in used when content finishes loading. Keep
/// this as the one place motion-on-load is defined so every screen feels
/// consistent.
class FadeIn extends StatefulWidget {
  final Widget child;
  final Duration duration;

  const FadeIn({super.key, required this.child, this.duration = const Duration(milliseconds: 280)});

  @override
  State<FadeIn> createState() => _FadeInState();
}

class _FadeInState extends State<FadeIn> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration)..forward();
  late final Animation<double> _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.02),
    end: Offset.zero,
  ).animate(_fade);

  @override
  void dispose() {
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
