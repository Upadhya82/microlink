/// A real place from OpenStreetMap's Overpass API (`GET /shops/external`),
/// not a MicroLink shop -- deliberately a separate, smaller type rather
/// than shoehorned into [Shop], since it has no owner, no rating, no
/// open/closed state, and no products. Never pass one where a real shop id
/// is expected (shop detail, orders, favorites, ...).
class ExternalPlace {
  final String id;
  final String name;
  final String category;
  final String address;
  final double latitude;
  final double longitude;
  final String? phone;
  final String? openingHours;

  const ExternalPlace({
    required this.id,
    required this.name,
    required this.category,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.phone,
    this.openingHours,
  });

  factory ExternalPlace.fromJson(Map<String, dynamic> json) {
    return ExternalPlace(
      id: json['id'] as String,
      name: json['name'] as String,
      category: json['category'] as String,
      address: json['address'] as String? ?? '',
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      phone: json['phone'] as String?,
      openingHours: json['opening_hours'] as String?,
    );
  }
}
