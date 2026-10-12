/// Mirrors admin-service's `AdResponse` schema (`/ads/*`). A shop owner's
/// or outside company's paid banner shown on the customer Home screen,
/// once an admin has approved it.
class Ad {
  final String id;
  final String? shopId;
  final String advertiserName;
  final String title;
  final String subtitle;
  final String imageUrl;
  final String status;
  final DateTime? startDate;
  final DateTime? endDate;
  final DateTime? createdAt;

  const Ad({
    required this.id,
    required this.shopId,
    required this.advertiserName,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.status,
    this.startDate,
    this.endDate,
    this.createdAt,
  });

  factory Ad.fromJson(Map<String, dynamic> json) {
    return Ad(
      id: json['id'] as String,
      shopId: json['shop_id'] as String?,
      advertiserName: json['advertiser_name'] as String,
      title: json['title'] as String,
      subtitle: json['subtitle'] as String? ?? '',
      // An uploaded banner wins over a pasted link: image_path is the
      // server's own copy, which is always reachable.
      imageUrl: (json['image_path'] as String?)?.isNotEmpty == true
          ? json['image_path'] as String
          : (json['image_url'] as String? ?? ''),
      status: json['status'] as String? ?? 'pending',
      startDate: DateTime.tryParse(json['start_date']?.toString() ?? ''),
      endDate: DateTime.tryParse(json['end_date']?.toString() ?? ''),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
    );
  }
}
