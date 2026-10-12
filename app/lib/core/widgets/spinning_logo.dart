import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Spins its child around the vertical axis, continuously, with enough
/// perspective that a flat icon reads as a solid object turning rather than
/// as a shape being squashed.
///
/// Perspective is the whole trick. Without it, a rotation on Y is an
/// orthographic projection -- the child simply narrows to a line and widens
/// again, which looks like a horizontal squeeze. Giving the matrix a small
/// Z-depth entry makes the near edge larger than the far one, and the eye
/// reads that as rotation in space.
///
/// The child is a flat surface, so the far side is its mirror image, exactly
/// as a printed card would be. That is what makes it look like a real object
/// rather than an icon being redrawn.
class SpinningLogo extends StatefulWidget {
  /// The thing being spun. Ignored when [builder] is given.
  final Widget? child;

  /// Builds the spinning content from the current turn, as a fraction of a
  /// full rotation (0 to 1).
  ///
  /// Use this instead of [child] when the content's own shading depends on
  /// which way it is facing -- a metal surface whose highlight should travel
  /// as it turns, for instance. Rebuilt every frame, so keep it light.
  final Widget Function(BuildContext context, double turn)? builder;

  /// Time for one full turn. Slower than about 2s reads as deliberate; much
  /// faster becomes hard to look at, and on a login screen people are trying
  /// to read the fields underneath it.
  final Duration duration;

  /// A constant tilt away from the viewer, in radians. A little of this stops
  /// the shape looking like it is spinning on a flat page: the top edge stays
  /// slightly further away throughout.
  final double tilt;

  /// How strongly perspective is applied. Larger exaggerates the near edge;
  /// past roughly 0.004 the child distorts noticeably at the halfway point.
  final double perspective;

  const SpinningLogo({
    super.key,
    this.child,
    this.builder,
    this.duration = const Duration(seconds: 4),
    this.tilt = 0.18,
    this.perspective = 0.0015,
  }) : assert(child != null || builder != null, 'Give SpinningLogo a child or a builder');

  @override
  State<SpinningLogo> createState() => _SpinningLogoState();
}

class _SpinningLogoState extends State<SpinningLogo> with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: widget.duration)..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Motion that never stops is the kind most likely to make someone ill, so
    // this one respects the platform's "reduce motion" setting and simply
    // stands still.
    final reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (reduceMotion) {
      // Still shown facing forward, just not turning.
      return widget.builder?.call(context, 0) ?? widget.child!;
    }

    return AnimatedBuilder(
      animation: _controller,
      // Only passed through when the content does not depend on the turn;
      // a builder has to run every frame, so it cannot be cached here.
      child: widget.builder == null ? widget.child : null,
      builder: (context, child) {
        final fraction = _controller.value;
        return Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            // Row 3, column 2 is the perspective term: it divides x and y by
            // a function of z, so parts further away draw smaller.
            ..setEntry(3, 2, widget.perspective)
            ..rotateX(widget.tilt)
            ..rotateY(fraction * 2 * math.pi),
          child: widget.builder?.call(context, fraction) ?? child!,
        );
      },
    );
  }
}
