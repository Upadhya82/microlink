/// A shop a user suggested that an admin approved.
///
/// Mirrors crowdsource-service's `ApprovedSuggestionResponse`
/// (`GET /crowdsource/shop-reports/approved`). Kept apart from [Shop]: a
/// suggestion is not a shop-service listing, so it has no products, ratings
/// or detail page of its own.
class SuggestedShop {
  final String id;
  final String name;
  final String category;
  final String address;
  final double latitude;
  final double longitude;
  final String description;
  final String? phone;
  final String? openingTime;
  final String? closingTime;

  /// Server-relative path to the shop-front photo, or null when there is none.
  final String? photoPath;
  final DateTime approvedAt;

  /// Set when the app sent its location with the request.
  final double? distanceKm;

  const SuggestedShop({
    required this.id,
    required this.name,
    required this.category,
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.description,
    required this.approvedAt,
    this.phone,
    this.openingTime,
    this.closingTime,
    this.photoPath,
    this.distanceKm,
  });

  /// "08:00 – 20:00", or null when the suggestion did not say.
  String? get hours {
    if (openingTime == null || closingTime == null) return null;
    if (openingTime!.isEmpty || closingTime!.isEmpty) return null;
    return '$openingTime – $closingTime';
  }

  factory SuggestedShop.fromJson(Map<String, dynamic> json) {
    return SuggestedShop(
      id: json['id'] as String,
      name: json['shop_name'] as String? ?? '',
      category: json['category'] as String? ?? 'other',
      address: json['address'] as String? ?? '',
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      description: json['description'] as String? ?? '',
      phone: json['phone'] as String?,
      openingTime: json['opening_time'] as String?,
      closingTime: json['closing_time'] as String?,
      photoPath: json['photo_path'] as String?,
      approvedAt: DateTime.tryParse(json['approved_at'] as String? ?? '') ??
          DateTime.now(),
      distanceKm: (json['distance_km'] as num?)?.toDouble(),
    );
  }
}
