import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// Sweeps a soft highlight across its child, the usual "content is loading"
/// treatment.
///
/// A moving highlight rather than the opacity pulse this used to be: a pulse
/// reads as something blinking at you, while a sweep reads as content on its
/// way, which is the point of a skeleton. One controller drives the whole
/// list because every row shares the same [Shimmer] ancestor timing.
class Shimmer extends StatefulWidget {
  final Widget child;

  const Shimmer({super.key, required this.child});

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    // Lighten in light mode, lift in dark mode -- a white highlight on a dark
    // surface would glare.
    final highlight = Color.alphaBlend(
      (Theme.of(context).brightness == Brightness.dark ? Colors.white : Colors.white)
          .withValues(alpha: 0.35),
      base,
    );

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            // Travel from fully off one edge to fully off the other.
            final dx = (_controller.value * 2) - 1;
            return LinearGradient(
              begin: Alignment(dx - 0.3, -0.2),
              end: Alignment(dx + 0.3, 0.2),
              colors: [base, highlight, base],
              stops: const [0.0, 0.5, 1.0],
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// A loading skeleton for list-style screens (shops, orders, notifications),
/// shown instead of a bare spinner so the wait hints at the shape of the
/// content that is coming.
class SkeletonList extends StatelessWidget {
  final int itemCount;
  final double itemHeight;

  const SkeletonList({super.key, this.itemCount = 6, this.itemHeight = 96});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Shimmer(
      child: ListView.separated(
        // The skeleton must not scroll -- it is a placeholder, not content.
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: itemCount,
        separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
        itemBuilder: (_, _) => _SkeletonCard(height: itemHeight, color: color),
      ),
    );
  }
}

class _SkeletonCard extends StatelessWidget {
  final double height;
  final Color color;

  const _SkeletonCard({required this.height, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          // A rough impression of the real card: thumbnail, title, subtitle.
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(AppRadius.input),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Bar(color: color, widthFactor: 0.55),
                const SizedBox(height: AppSpacing.sm),
                _Bar(color: color, widthFactor: 0.3),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  final Color color;
  final double widthFactor;

  const _Bar({required this.color, required this.widthFactor});

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      alignment: Alignment.centerLeft,
      widthFactor: widthFactor,
      child: Container(
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
      ),
    );
  }
}
