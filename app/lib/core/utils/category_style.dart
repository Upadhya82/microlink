import 'package:flutter/material.dart';

import '../models/shop.dart';

/// Colours and icons for shop categories.
///
/// Each category owns a hue instead of cycling the four theme container
/// colours, which previously made grocery and clothing render identically --
/// on a map full of pins that is the difference between scanning and
/// squinting. The hues are spread around the wheel and chosen semantically
/// where a convention exists (green for fresh food, red for pharmacy), which
/// is what lets someone read the map without the legend.
///
/// Within each mode the colours are held at a similar perceived lightness so
/// no single category screams louder than the rest, and the dark variants
/// are lifted and desaturated rather than reused, because a saturated mid
/// tone that reads well on white glows unpleasantly on a dark map.
class CategoryStyle {
  /// Saturated fill for a map pin. Icons drawn on it are white.
  final Color pin;

  /// Soft tint for list thumbnails and chips.
  final Color container;

  /// Icon/text colour that sits on [container].
  final Color onContainer;

  const CategoryStyle({
    required this.pin,
    required this.container,
    required this.onContainer,
  });
}

// Light mode: saturated but not fluorescent pins, pale tints for thumbnails.
const Map<String, CategoryStyle> _lightStyles = {
  'grocery': CategoryStyle(
    pin: Color(0xFF2E9E5B),
    container: Color(0xFFDDF3E5),
    onContainer: Color(0xFF1B6B3C),
  ),
  'restaurant': CategoryStyle(
    pin: Color(0xFFE8702A),
    container: Color(0xFFFCE8DA),
    onContainer: Color(0xFF9C4615),
  ),
  'pharmacy': CategoryStyle(
    pin: Color(0xFFD6455B),
    container: Color(0xFFFBE0E4),
    onContainer: Color(0xFF8F2634),
  ),
  'bakery': CategoryStyle(
    pin: Color(0xFFC8872B),
    container: Color(0xFFF9ECD7),
    onContainer: Color(0xFF855715),
  ),
  'electronics': CategoryStyle(
    pin: Color(0xFF4C6FE7),
    container: Color(0xFFE0E6FC),
    onContainer: Color(0xFF2B45A3),
  ),
  'clothing': CategoryStyle(
    pin: Color(0xFF8B5CF6),
    container: Color(0xFFEDE4FE),
    onContainer: Color(0xFF5B32B5),
  ),
  'hardware': CategoryStyle(
    pin: Color(0xFF5B7085),
    container: Color(0xFFE3E9EF),
    onContainer: Color(0xFF3A4A59),
  ),
  'stationery': CategoryStyle(
    pin: Color(0xFF0E9594),
    container: Color(0xFFD7F0F0),
    onContainer: Color(0xFF066362),
  ),
  'other': CategoryStyle(
    pin: Color(0xFF6B7280),
    container: Color(0xFFE8EAED),
    onContainer: Color(0xFF454B54),
  ),
};

// Dark mode: lifted, slightly desaturated hues so pins stay legible on the
// inverted map tiles without glowing.
const Map<String, CategoryStyle> _darkStyles = {
  'grocery': CategoryStyle(
    pin: Color(0xFF4FBD7C),
    container: Color(0xFF1C3D2A),
    onContainer: Color(0xFF8FDCAC),
  ),
  'restaurant': CategoryStyle(
    pin: Color(0xFFF08E52),
    container: Color(0xFF45291A),
    onContainer: Color(0xFFF7BE96),
  ),
  'pharmacy': CategoryStyle(
    pin: Color(0xFFE8737F),
    container: Color(0xFF45222A),
    onContainer: Color(0xFFF2A8AF),
  ),
  'bakery': CategoryStyle(
    pin: Color(0xFFDDA94E),
    container: Color(0xFF42331C),
    onContainer: Color(0xFFEFCD95),
  ),
  'electronics': CategoryStyle(
    pin: Color(0xFF7D97EE),
    container: Color(0xFF232F52),
    onContainer: Color(0xFFADBDF5),
  ),
  'clothing': CategoryStyle(
    pin: Color(0xFFA886F8),
    container: Color(0xFF342348),
    onContainer: Color(0xFFC9B2FB),
  ),
  'hardware': CategoryStyle(
    pin: Color(0xFF8699AC),
    container: Color(0xFF2A333C),
    onContainer: Color(0xFFB4C2CF),
  ),
  'stationery': CategoryStyle(
    pin: Color(0xFF3FB8B7),
    container: Color(0xFF123B3B),
    onContainer: Color(0xFF86D9D8),
  ),
  'other': CategoryStyle(
    pin: Color(0xFF99A1AE),
    container: Color(0xFF2C3139),
    onContainer: Color(0xFFBFC5CE),
  ),
};

/// The full style for [category] in the current brightness.
CategoryStyle categoryStyle(BuildContext context, String category) {
  final styles =
      Theme.of(context).brightness == Brightness.dark ? _darkStyles : _lightStyles;
  return styles[category] ?? styles['other']!;
}

/// The icon used to represent a place type.
///
/// Rounded (filled) rather than outlined: these are read at 18-20px on a
/// coloured pin, where an outline nearly disappears.
IconData categoryIcon(String category) {
  switch (category) {
    case 'grocery':
      return Icons.local_grocery_store_rounded;
    case 'restaurant':
      return Icons.restaurant_rounded;
    case 'pharmacy':
      return Icons.medical_services_rounded;
    case 'bakery':
      return Icons.bakery_dining_rounded;
    case 'electronics':
      return Icons.devices_other_rounded;
    case 'clothing':
      return Icons.checkroom_rounded;
    case 'hardware':
      return Icons.handyman_rounded;
    case 'stationery':
      return Icons.auto_stories_rounded;
    default:
      return Icons.storefront_rounded;
  }
}

/// Human-readable label for a category, for chips and legends.
String categoryLabel(String category) {
  if (category.isEmpty) return 'Other';
  return category[0].toUpperCase() + category.substring(1);
}

/// Kept for the screens that only need the thumbnail tint pair.
({Color background, Color foreground}) categoryColors(
  BuildContext context,
  String category,
) {
  final style = categoryStyle(context, category);
  return (background: style.container, foreground: style.onContainer);
}

/// Every category the backend defines, for legends and filter rows.
List<String> get allCategories => shopCategories;
