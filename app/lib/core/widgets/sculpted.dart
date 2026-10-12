import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Draws a flat shape as though it were cut from polished metal: real
/// thickness, a lit face, and a specular streak that travels across it.
///
/// Flutter has no 3D renderer, so the depth is built the way a printmaker
/// would build it -- the same shape stamped repeatedly, each copy a little
/// further back and a little darker, with the lit face laid on top. Stacked
/// densely enough the steps read as a continuous extruded edge.
///
/// The caller supplies [layer], which must paint the shape in whatever solid
/// color it is handed. An icon or a line of text both qualify, which is why
/// this takes a builder rather than a widget: the same shape has to be drawn
/// once per depth step.
class Sculpted extends StatelessWidget {
  /// Paints the shape in the given color. Called once per depth step plus
  /// once for the face, so it should be cheap.
  final Widget Function(Color color) layer;

  /// The material's own color, before lighting. The face runs from lighter
  /// than this to darker; the extruded sides are all darker.
  final Color baseColor;

  /// How far back the shape extends, in logical pixels. Past roughly a tenth
  /// of the shape's size the extrusion starts to read as a smear rather than
  /// as thickness.
  final double depth;

  /// Number of stamped copies making up the extrusion. More is smoother and
  /// costs a widget each; eight is enough to look solid at icon sizes.
  final int steps;

  /// Which way the shape extends, as a unit vector. Usually points away from
  /// the light so the thickness shows on the shadowed side.
  final Offset direction;

  /// Where the specular streak sits across the face, 0 at the left edge and
  /// 1 at the right. Animate it to make the highlight travel, which is what
  /// makes the surface read as polished rather than painted.
  final double highlight;

  /// Soft contact shadow under the shape. Without it the object floats.
  final bool shadow;

  const Sculpted({
    super.key,
    required this.layer,
    required this.baseColor,
    this.depth = 7,
    this.steps = 8,
    this.direction = const Offset(0.55, 1),
    this.highlight = 0.5,
    this.shadow = true,
  });

  /// Lightness-shifted variants of [baseColor]. Working in HSL keeps the hue
  /// steady, so the dark edges stay the same green rather than drifting grey.
  Color _shade(double lightness) {
    final hsl = HSLColor.fromColor(baseColor);
    return hsl.withLightness(lightness.clamp(0.0, 1.0)).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final baseLightness = HSLColor.fromColor(baseColor).lightness;

    return Stack(
      alignment: Alignment.center,
      clipBehavior: Clip.none,
      children: [
        if (shadow)
          Transform.translate(
            offset: direction * (depth + 3),
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
              child: layer(Colors.black.withValues(alpha: 0.28)),
            ),
          ),

        // The extruded side wall, drawn back to front so nearer steps cover
        // further ones. Darkening with depth is what gives it a rounded,
        // bevelled edge instead of a flat slab.
        for (var i = steps; i >= 1; i--)
          Transform.translate(
            offset: direction * (depth * i / steps),
            child: layer(_shade(baseLightness * (0.30 + 0.38 * (1 - i / steps)))),
          ),

        // The face. ShaderMask paints the gradient through the shape, so the
        // lighting follows the letterforms rather than sitting in a box
        // behind them.
        ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) => _faceShader(bounds, baseLightness),
          child: layer(Colors.white),
        ),
      ],
    );
  }

  /// The lit face: darker at the top-left where it turns away, the material's
  /// own color across the middle, and a narrow bright band at [highlight].
  ui.Shader _faceShader(Rect bounds, double baseLightness) {
    final pos = highlight.clamp(0.0, 1.0);
    // The band has to stay inside 0..1 and keep its stops strictly
    // increasing, or the gradient throws.
    const halfBand = 0.08;
    final bandStart = (pos - halfBand).clamp(0.02, 0.94);
    final bandEnd = (bandStart + halfBand * 2).clamp(0.06, 0.98);

    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        _shade(baseLightness * 1.18),
        _shade(baseLightness * 0.92),
        // The specular itself: not pure white, which would look like a hole,
        // but the material lifted most of the way towards it.
        _shade(baseLightness + (1 - baseLightness) * 0.78),
        _shade(baseLightness * 0.88),
        _shade(baseLightness * 0.62),
      ],
      stops: [0, bandStart, (bandStart + bandEnd) / 2, bandEnd, 1],
    ).createShader(bounds);
  }
}
