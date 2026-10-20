import '../l10n/app_strings.dart';
import '../constants/app_constants.dart';

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

  /// Item 6: whether an admin has verified this shop.
  ///
  /// Deliberately nullable: a page cached before the app read this field
  /// has no value for it, and guessing "not verified" would brand every
  /// cached shop with a chip it may not deserve. Null means "we do not
  /// know yet", and nothing is shown until the next refresh.
  final bool? isVerified;

  /// Item 10: how many of this shop's products customers can actually see.
  /// A shop needs [AppConstants.minProductsToVerify] of them before an
  /// admin can verify it.
  final int listableProductCount;

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
    this.isVerified,
    this.listableProductCount = 0,
  });

  /// Whether this shop has enough listed products to be verified.
  bool get hasEnoughProductsToVerify =>
      listableProductCount >= AppConstants.minProductsToVerify;

  /// "3 of 5 products listed", for the owner dashboard and admin review.
  String get productProgressLabel =>
      '$listableProductCount of ${AppConstants.minProductsToVerify} products listed';

  /// Show the "Not verified" chip only when the server actually said so.
  bool get showsNotVerifiedChip => isVerified == false;

  /// The owner is waiting on an admin.
  bool get awaitingVerification => isVerified == false;

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
      // Absent (an older cached page) stays null rather than becoming false.
      isVerified: json['is_verified'] as bool?,
      listableProductCount:
          (json['listable_product_count'] as num?)?.toInt() ?? 0,
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

  /// True when customers cannot see this product: shop-service only lists
  /// products with at least [AppConstants.minListableStock] in stock. The
  /// owner still sees it, so it can be restocked.
  bool get isHiddenFromCustomers =>
      stockQuantity < AppConstants.minListableStock;

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
