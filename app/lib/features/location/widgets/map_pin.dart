import 'package:flutter/material.dart';

import '../../../core/theme/app_motion.dart';
import '../../../core/utils/category_style.dart';

/// A teardrop map marker: a rounded head carrying an icon, tapering to a
/// point at the bottom.
///
/// Drawn rather than composed from an [Icon] so the point sits exactly on
/// the marker's anchor and the fill can be any category colour. A plain
/// circle (what this replaced) gives no indication of which pixel it refers
/// to, which matters once pins are close together.
class MapPin extends StatelessWidget {
  final IconData icon;
  final Color color;

  /// Dimmed, for a shop that is currently closed.
  final bool muted;

  /// Enlarged with a ring, for the pin the user has selected.
  final bool selected;

  final String? tooltip;
  final VoidCallback? onTap;

  const MapPin({
    super.key,
    required this.icon,
    required this.color,
    this.muted = false,
    this.selected = false,
    this.tooltip,
    this.onTap,
  });

  /// Pin for a shop category, with its own hue.
  factory MapPin.forCategory(
    BuildContext context,
    String category, {
    bool muted = false,
    bool selected = false,
    String? tooltip,
    VoidCallback? onTap,
  }) {
    return MapPin(
      icon: categoryIcon(category),
      color: categoryStyle(context, category).pin,
      muted: muted,
      selected: selected,
      tooltip: tooltip,
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;

    Widget pin = AnimatedScale(
      duration: AppMotion.medium,
      curve: AppMotion.emphasized,
      scale: selected ? 1.18 : 1,
      child: Opacity(
        opacity: muted ? 0.5 : 1,
        child: CustomPaint(
          painter: _PinPainter(
            color: color,
            borderColor: surface,
            ringColor: selected ? surface : null,
          ),
          child: SizedBox(
            width: 34,
            height: 44,
            // The icon rides in the head, not the centre of the bounding box.
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Center(
                child: Icon(icon, size: 17, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );

    if (tooltip != null) {
      pin = Tooltip(message: tooltip!, child: pin);
    }
    if (onTap != null) {
      pin = GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: pin);
    }
    return pin;
  }
}

class _PinPainter extends CustomPainter {
  final Color color;
  final Color borderColor;
  final Color? ringColor;

  _PinPainter({required this.color, required this.borderColor, this.ringColor});

  @override
  void paint(Canvas canvas, Size size) {
    final headRadius = size.width / 2;
    final headCentre = Offset(size.width / 2, headRadius);
    final tip = Offset(size.width / 2, size.height);

    // Teardrop: the head circle, plus two curves sweeping down to the tip.
    final path = Path()
      ..addOval(Rect.fromCircle(center: headCentre, radius: headRadius))
      ..moveTo(headCentre.dx - headRadius * 0.86, headCentre.dy + headRadius * 0.5)
      ..quadraticBezierTo(
        headCentre.dx - headRadius * 0.5,
        size.height * 0.82,
        tip.dx,
        tip.dy,
      )
      ..quadraticBezierTo(
        headCentre.dx + headRadius * 0.5,
        size.height * 0.82,
        headCentre.dx + headRadius * 0.86,
        headCentre.dy + headRadius * 0.5,
      )
      ..close();

    canvas.drawShadow(path, Colors.black.withValues(alpha: 0.5), 3, false);
    canvas.drawPath(path, Paint()..color = color);
    canvas.drawPath(
      path,
      Paint()
        ..color = borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    if (ringColor != null) {
      canvas.drawCircle(
        headCentre,
        headRadius + 2.5,
        Paint()
          ..color = ringColor!
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_PinPainter old) =>
      old.color != color || old.borderColor != borderColor || old.ringColor != ringColor;
}

/// The user's own position: a solid dot inside a soft halo -- the convention
/// every map app uses, so it reads as "me" rather than as another place.
class MyLocationDot extends StatelessWidget {
  const MyLocationDot({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.22),
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: colorScheme.primary,
            shape: BoxShape.circle,
            border: Border.all(color: colorScheme.surface, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: colorScheme.primary.withValues(alpha: 0.45),
                blurRadius: 8,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Horizontal legend of the categories currently on screen, so the pin
/// colours are decodable instead of decorative.
class CategoryLegend extends StatelessWidget {
  final List<String> categories;

  const CategoryLegend({super.key, required this.categories});

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 26,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: categories.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final category = categories[index];
          final style = categoryStyle(context, category);
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: style.container,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(categoryIcon(category), size: 13, color: style.onContainer),
                const SizedBox(width: 5),
                Text(
                  categoryLabel(category),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: style.onContainer,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
