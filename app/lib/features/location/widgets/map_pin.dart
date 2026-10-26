import 'package:flutter/material.dart';

import '../../../core/theme/app_motion.dart';
import '../../../core/utils/category_style.dart';

/// A map marker: a rounded head carrying a category glyph, tapering to a
/// point at the bottom.
///
/// Drawn rather than composed from an [Icon] so the point sits exactly on
/// the marker's anchor and the fill can be any category colour. A plain
/// circle (what this replaced) gives no indication of which pixel it refers
/// to, which matters once pins are close together.
///
/// Everything here is painted as vectors at the device's own resolution, so
/// a pin is as sharp at zoom 20 as at zoom 10 -- unlike an image marker,
/// which would soften the moment the map scaled it.
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
    Widget pin = AnimatedScale(
      duration: AppMotion.medium,
      curve: AppMotion.emphasized,
      scale: selected ? 1.22 : 1,
      child: Opacity(
        opacity: muted ? 0.55 : 1,
        child: SizedBox(
          width: 38,
          height: 50,
          child: CustomPaint(
            painter: _PinPainter(color: color, selected: selected),
            // The glyph rides in the head, not the centre of the bounding
            // box, and is drawn over the painter so it stays crisp.
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Center(
                child: Icon(icon, size: 18, color: Colors.white),
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
  final bool selected;

  _PinPainter({required this.color, required this.selected});

  /// A lighter version of the category colour for the top of the gradient.
  /// Lifting the lightness rather than blending towards white keeps the hue,
  /// so grocery still reads green and pharmacy still reads red.
  Color get _light {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness + 0.16).clamp(0.0, 1.0))
        .withSaturation((hsl.saturation + 0.08).clamp(0.0, 1.0))
        .toColor();
  }

  Color get _dark {
    final hsl = HSLColor.fromColor(color);
    return hsl.withLightness((hsl.lightness - 0.12).clamp(0.0, 1.0)).toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    const collar = 2.4;
    final headRadius = (size.width - collar * 2) / 2;
    final headCentre = Offset(size.width / 2, headRadius + collar);
    final tip = Offset(size.width / 2, size.height - 1.5);

    final path = Path()
      ..addOval(Rect.fromCircle(center: headCentre, radius: headRadius))
      ..moveTo(headCentre.dx - headRadius * 0.84, headCentre.dy + headRadius * 0.54)
      ..quadraticBezierTo(
        headCentre.dx - headRadius * 0.46,
        tip.dy - headRadius * 0.34,
        tip.dx,
        tip.dy,
      )
      ..quadraticBezierTo(
        headCentre.dx + headRadius * 0.46,
        tip.dy - headRadius * 0.34,
        headCentre.dx + headRadius * 0.84,
        headCentre.dy + headRadius * 0.54,
      )
      ..close();

    // A soft contact shadow on the ground under the tip, rather than a
    // shadow cast by the whole pin. Canvas.drawShadow spreads a dark haze
    // across the head and muddies the colour, which is what made the old
    // pins look washed out against the map.
    canvas.drawOval(
      Rect.fromCenter(center: Offset(tip.dx, tip.dy - 1), width: 13, height: 5),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.28)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
    );

    // White collar first, as a stroke under the fill, so the pin separates
    // from whatever it sits on -- dark satellite imagery especially.
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = collar * 2
        ..strokeJoin = StrokeJoin.round,
    );

    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_light, color, _dark],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(Offset.zero & size),
    );

    // A highlight across the top of the head, the thing that makes a flat
    // disc read as a rounded object.
    canvas.drawArc(
      Rect.fromCircle(center: headCentre, radius: headRadius * 0.72),
      3.6,
      2.0,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.42)
        ..style = PaintingStyle.stroke
        ..strokeWidth = headRadius * 0.26
        ..strokeCap = StrokeCap.round,
    );

    if (selected) {
      canvas.drawCircle(
        headCentre,
        headRadius + collar + 2.5,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
      canvas.drawCircle(
        headCentre,
        headRadius + collar + 2.5,
        Paint()
          ..color = _dark.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_PinPainter old) =>
      old.color != color || old.selected != selected;
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
