import '../l10n/app_strings.dart';

/// Mirrors shop-service's `ShopResponse` schema.
class Shop {
  final String id;
  final String ownerId;
  final String name;
  final String description;
  final String category;
  final String address;
  final double latitude;
  final double longitude;
  final String? phone;
  final String? imageUrl;
  final String openingTime;
  final String closingTime;
  final bool isOpen;
  final double ratingAvg;
  final int ratingCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final double? distanceKm;
  final String? reason;

  const Shop({
    required this.id,
    required this.ownerId,
    required this.name,
    required this.description,
    required this.category,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.phone,
    this.imageUrl,
    required this.openingTime,
    required this.closingTime,
    required this.isOpen,
    required this.ratingAvg,
    required this.ratingCount,
    required this.createdAt,
    required this.updatedAt,
    this.distanceKm,
    this.reason,
  });

  factory Shop.fromJson(Map<String, dynamic> json) {
    return Shop(
      id: json['id'] as String,
      ownerId: json['owner_id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      category: json['category'] as String? ?? 'other',
      address: json['address'] as String? ?? '',
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      phone: json['phone'] as String?,
      imageUrl: json['image_url'] as String?,
      openingTime: json['opening_time'] as String? ?? '09:00',
      closingTime: json['closing_time'] as String? ?? '18:00',
      isOpen: json['is_open'] as bool? ?? false,
      ratingAvg: (json['rating_avg'] as num?)?.toDouble() ?? 0,
      ratingCount: (json['rating_count'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      distanceKm: (json['distance_km'] as num?)?.toDouble(),
      reason: json['reason'] as String?,
    );
  }
}

/// Mirrors shop-service's `ProductResponse` schema.
class Product {
  final String id;
  final String shopId;
  final String name;
  final String description;
  final double price;
  final int stockQuantity;
  final String category;
  final bool isAvailable;

  /// Percentage off, 0-90.
  final int discountPercent;

  /// Price after the discount. Computed by shop-service rather than here so
  /// every client shows the same number.
  final double finalPrice;

  /// Server-relative path to the product photo, or null when there is none.
  final String? imageUrl;

  const Product({
    required this.id,
    required this.shopId,
    required this.name,
    required this.description,
    required this.price,
    required this.stockQuantity,
    required this.category,
    required this.isAvailable,
    this.discountPercent = 0,
    double? finalPrice,
    this.imageUrl,
  }) : finalPrice = finalPrice ?? price;

  bool get hasDiscount => discountPercent > 0;

  /// What the customer saves, for the "you save Rs.X" line.
  double get savings => price - finalPrice;

  factory Product.fromJson(Map<String, dynamic> json) {
    return Product(
      id: json['id'] as String,
      shopId: json['shop_id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      price: (json['price'] as num).toDouble(),
      stockQuantity: (json['stock_quantity'] as num?)?.toInt() ?? 0,
      category: json['category'] as String? ?? '',
      isAvailable: json['is_available'] as bool? ?? true,
      discountPercent: (json['discount_percent'] as num?)?.toInt() ?? 0,
      finalPrice: (json['final_price'] as num?)?.toDouble(),
      imageUrl: json['image_url'] as String?,
    );
  }
}

/// Mirrors shop-service's `ShopAlertResponse` schema.
class ShopAlert {
  final String id;
  final String shopId;
  final String message;
  final DateTime createdAt;

  const ShopAlert({
    required this.id,
    required this.shopId,
    required this.message,
    required this.createdAt,
  });

  factory ShopAlert.fromJson(Map<String, dynamic> json) {
    return ShopAlert(
      id: json['id'] as String,
      shopId: json['shop_id'] as String,
      message: json['message'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// The fixed set of shop categories the backend accepts (shop-service's
/// `ShopCategory` enum) -- use this for dropdowns/filter chips.
const List<String> shopCategories = [
  'grocery',
  'restaurant',
  'pharmacy',
  'electronics',
  'clothing',
  'hardware',
  'stationery',
  'bakery',
  'other',
];

/// Display name for a shop category, translated when the app is in Sinhala.
///
/// Falls back to capitalising the raw value, so a category the backend adds
/// later still renders as something readable instead of an empty chip.
String formatCategoryLabel(String category) {
  if (category.isEmpty) return category;
  final key = 'category.$category';
  final translated = tr(key);
  if (translated != key) return translated;
  return category[0].toUpperCase() + category.substring(1);
}
