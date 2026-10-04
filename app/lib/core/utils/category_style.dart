import 'package:flutter/material.dart';

import '../models/shop.dart';

/// Maps a shop category to the outlined icon used to represent it wherever
/// there's no real shop photo (list thumbnails, the detail hero watermark,
/// Home's rails).
IconData categoryIcon(String category) {
  switch (category) {
    case 'grocery':
      return Icons.storefront_outlined;
    case 'restaurant':
      return Icons.restaurant_outlined;
    case 'pharmacy':
      return Icons.local_pharmacy_outlined;
    case 'bakery':
      return Icons.bakery_dining_outlined;
    case 'electronics':
      return Icons.devices_outlined;
    case 'clothing':
      return Icons.checkroom_outlined;
    case 'hardware':
      return Icons.hardware_outlined;
    case 'stationery':
      return Icons.edit_note_outlined;
    default:
      return Icons.storefront_outlined;
  }
}

/// A tinted background/foreground pair for a category's icon box, cycled
/// across the theme's container colors so categories read as visually
/// distinct without ever hardcoding a hex value.
({Color background, Color foreground}) categoryColors(BuildContext context, String category) {
  final colorScheme = Theme.of(context).colorScheme;
  final palette = [
    (background: colorScheme.primaryContainer, foreground: colorScheme.primary),
    (background: colorScheme.secondaryContainer, foreground: colorScheme.onSecondaryContainer),
    (background: colorScheme.tertiaryContainer, foreground: colorScheme.onTertiaryContainer),
    (background: colorScheme.surfaceContainerHighest, foreground: colorScheme.onSurfaceVariant),
  ];
  final index = shopCategories.indexOf(category);
  return palette[(index < 0 ? 0 : index) % palette.length];
}
