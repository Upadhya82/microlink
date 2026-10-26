import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/category_style.dart';
import '../../../core/models/shop.dart';
import 'map_tile_layer.dart';

/// The furniture that sits over a map: the base-layer picker, zoom buttons,
/// a scale bar, the tile attribution, and the category filter strip.
///
/// Kept together and away from the map screens because all of it is pure
/// presentation -- it reads the camera and calls back, and never touches the
/// map controller or the network itself.

// ---------------------------------------------------------------- layers

/// The sheet behind the layers button: Map / Satellite / Terrain, shown as
/// labelled swatches rather than a plain list so the choice can be made by
/// recognition instead of by reading.
class MapLayerPicker extends StatelessWidget {
  const MapLayerPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final MapBaseLayer selected;
  final ValueChanged<MapBaseLayer> onSelected;

  static Future<void> show(
    BuildContext context, {
    required MapBaseLayer selected,
    required ValueChanged<MapBaseLayer> onSelected,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => MapLayerPicker(selected: selected, onSelected: onSelected),
    );
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Map type', style: textTheme.titleMedium),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                for (final layer in MapBaseLayer.values) ...[
                  Expanded(
                    child: _LayerSwatch(
                      layer: layer,
                      isSelected: layer == selected,
                      onTap: () {
                        onSelected(layer);
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
                  if (layer != MapBaseLayer.values.last)
                    const SizedBox(width: AppSpacing.md),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LayerSwatch extends StatelessWidget {
  const _LayerSwatch({
    required this.layer,
    required this.isSelected,
    required this.onTap,
  });

  final MapBaseLayer layer;
  final bool isSelected;
  final VoidCallback onTap;

  /// A hint of what the layer looks like. Real tiles would be truer, but
  /// they cost three extra map requests every time the sheet opens, on
  /// connections this app is meant to tolerate.
  LinearGradient get _preview => switch (layer) {
        MapBaseLayer.standard => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFF2EFE9), Color(0xFFD9E7D2)],
          ),
        MapBaseLayer.satellite => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF2E4A2B), Color(0xFF14331F)],
          ),
        MapBaseLayer.terrain => const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFE8E0CC), Color(0xFFBFC9A0)],
          ),
      };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Column(
        // Stretch, or the preview shrink-wraps to the icon inside it and
        // the swatches come out as narrow pills instead of thumbnails.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 72,
            decoration: BoxDecoration(
              gradient: _preview,
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: Border.all(
                color: isSelected ? colorScheme.primary : colorScheme.outlineVariant,
                width: isSelected ? 2.5 : 1,
              ),
            ),
            child: Icon(
              layer.icon,
              color: layer.isDark ? Colors.white70 : Colors.black54,
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            layer.label,
            style: textTheme.labelLarge?.copyWith(
              color: isSelected ? colorScheme.primary : colorScheme.onSurface,
              fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ zoom

/// The stacked +/- buttons. A map that can only be zoomed by pinching is
/// awkward on a desktop browser, which is where this app gets demonstrated.
class MapZoomControls extends StatelessWidget {
  const MapZoomControls({
    super.key,
    required this.onZoomIn,
    required this.onZoomOut,
    this.canZoomIn = true,
    this.canZoomOut = true,
  });

  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final bool canZoomIn;
  final bool canZoomOut;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Material(
      color: colorScheme.surface,
      elevation: 3,
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ZoomButton(
            icon: Icons.add,
            tooltip: 'Zoom in',
            onPressed: canZoomIn ? onZoomIn : null,
          ),
          Divider(height: 1, thickness: 1, color: colorScheme.outlineVariant),
          _ZoomButton(
            icon: Icons.remove,
            tooltip: 'Zoom out',
            onPressed: canZoomOut ? onZoomOut : null,
          ),
        ],
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: SizedBox(
          width: 44,
          height: 40,
          child: Icon(
            icon,
            size: 22,
            color: onPressed == null
                ? colorScheme.onSurface.withValues(alpha: 0.3)
                : colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- scale bar

/// The "2 km" bar in the corner.
///
/// Web Mercator stretches horizontally away from the equator, so the scale
/// depends on latitude as well as zoom. Sri Lanka is near enough the equator
/// that the correction is small, but the formula is the same one the tile
/// grid is built on, so it stays right wherever the map is panned.
class MapScaleBar extends StatelessWidget {
  const MapScaleBar({
    super.key,
    required this.zoom,
    required this.latitude,
    this.onDark = false,
  });

  final double zoom;
  final double latitude;
  final bool onDark;

  /// Metres covered by one logical pixel at this zoom and latitude.
  static double metresPerPixel(double zoom, double latitude) {
    const equatorMetresPerPixel = 156543.03392;
    return equatorMetresPerPixel *
        math.cos(latitude * math.pi / 180) /
        math.pow(2, zoom);
  }

  /// The largest round distance that fits in [maxPixels].
  static (double metres, String label) _niceDistance(double maxMetres) {
    const steps = <double>[
      1, 2, 5, 10, 20, 50, 100, 200, 500,
      1000, 2000, 5000, 10000, 20000, 50000, 100000, 200000, 500000,
    ];
    var chosen = steps.first;
    for (final step in steps) {
      if (step <= maxMetres) chosen = step;
    }
    final label = chosen >= 1000
        ? '${(chosen / 1000).toStringAsFixed(0)} km'
        : '${chosen.toStringAsFixed(0)} m';
    return (chosen, label);
  }

  @override
  Widget build(BuildContext context) {
    const maxWidth = 90.0;
    final perPixel = metresPerPixel(zoom, latitude);
    final (metres, label) = _niceDistance(perPixel * maxWidth);
    final width = (metres / perPixel).clamp(24.0, maxWidth);
    final ink = onDark ? Colors.white : Colors.black87;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: ink,
            shadows: [
              Shadow(
                color: onDark ? Colors.black54 : Colors.white70,
                blurRadius: 2,
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Container(
          width: width,
          height: 6,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: ink, width: 1.5),
              right: BorderSide(color: ink, width: 1.5),
              bottom: BorderSide(color: ink, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

/// The tile provider's credit line. Both OpenStreetMap and Esri require it
/// to be visible on the map, so it is never optional.
class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key, required this.layer});

  final MapBaseLayer layer;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: (layer.isDark ? Colors.black : Colors.white).withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        child: Text(
          layer.attribution,
          style: TextStyle(
            fontSize: 9.5,
            color: layer.isDark ? Colors.white70 : Colors.black54,
          ),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------- categories

/// The scrolling filter strip across the top of the map.
///
/// Selecting a chip narrows the pins and the nearby list to that category;
/// selecting it again clears the filter, so there is no separate "All" chip
/// to hunt for.
class MapCategoryChips extends StatelessWidget {
  const MapCategoryChips({
    super.key,
    required this.selected,
    required this.onSelected,
    this.counts = const {},
  });

  final String? selected;
  final ValueChanged<String?> onSelected;

  /// How many shops are loaded in each category, used to grey out the chips
  /// that would return an empty map.
  final Map<String, int> counts;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
        itemCount: shopCategories.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) {
          final category = shopCategories[index];
          final count = counts[category] ?? 0;
          return _CategoryChip(
            category: category,
            isSelected: category == selected,
            // Before the first load there are no counts at all, so every
            // chip stays tappable rather than the strip looking broken.
            isEmpty: counts.isNotEmpty && count == 0,
            onTap: () => onSelected(category == selected ? null : category),
          );
        },
      ),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.category,
    required this.isSelected,
    required this.isEmpty,
    required this.onTap,
  });

  final String category;
  final bool isSelected;
  final bool isEmpty;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final style = categoryStyle(context, category);

    final foreground = isSelected
        ? colorScheme.onPrimary
        : isEmpty
            ? colorScheme.onSurface.withValues(alpha: 0.38)
            : colorScheme.onSurface;

    return Material(
      color: isSelected ? colorScheme.primary : colorScheme.surface,
      elevation: isSelected ? 2 : 1,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: isEmpty && !isSelected ? null : onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                categoryIcon(category),
                size: 17,
                color: isSelected ? colorScheme.onPrimary : style.pin,
              ),
              const SizedBox(width: 6),
              Text(
                formatCategoryLabel(category),
                style: textTheme.labelLarge?.copyWith(
                  color: foreground,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
