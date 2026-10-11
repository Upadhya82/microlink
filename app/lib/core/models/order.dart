/// Mirrors delivery-service's `OrderResponse` / `OrderDetailResponse` schemas.
/// `items` is intentionally freeform (list of `{name, quantity, price}`-ish
/// maps) since the backend stores it as opaque JSON.
///
/// SRS REQ-DELIV-3: there is no cart and no payment. `totalAmount` is only the
/// fee the customer OFFERS the agent (0 = "to be agreed"), settled outside the
/// app. The pickup / item-description / ETA / rating fields are all optional
/// so older orders still parse.
class DeliveryOrder {
  final String id;
  final String customerId;
  final String shopId;
  final String? agentId;
  final List<Map<String, dynamic>> items;
  final String deliveryAddress;
  final double deliveryLat;
  final double deliveryLng;
  final String status;
  final double totalAmount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<OrderEvent> events;
  final double? distanceKm;
  final String? pickupAddress;
  final double? pickupLat;
  final double? pickupLng;
  final String? itemDescription;
  final DateTime? promisedBy;
  final int? agentEtaMinutes;
  final int? rating;
  final String? ratingComment;
  final double? tripDistanceKm;

  /// Handover codes. The server decides who may see which: the shop owner
  /// gets [pickupCode], the customer gets [deliveryCode], and the agent --
  /// who has to ask for both -- gets neither. Null simply means "not yours".
  final String? pickupCode;
  final String? deliveryCode;

  const DeliveryOrder({
    required this.id,
    required this.customerId,
    required this.shopId,
    this.agentId,
    required this.items,
    required this.deliveryAddress,
    required this.deliveryLat,
    required this.deliveryLng,
    required this.status,
    required this.totalAmount,
    required this.createdAt,
    required this.updatedAt,
    this.events = const [],
    this.distanceKm,
    this.pickupAddress,
    this.pickupLat,
    this.pickupLng,
    this.itemDescription,
    this.promisedBy,
    this.agentEtaMinutes,
    this.rating,
    this.ratingComment,
    this.tripDistanceKm,
    this.pickupCode,
    this.deliveryCode,
  });

  factory DeliveryOrder.fromJson(Map<String, dynamic> json) {
    return DeliveryOrder(
      id: json['id'] as String,
      customerId: json['customer_id'] as String,
      shopId: json['shop_id'] as String,
      agentId: json['agent_id'] as String?,
      items: (json['items'] as List? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
      deliveryAddress: json['delivery_address'] as String? ?? '',
      deliveryLat: (json['delivery_lat'] as num).toDouble(),
      deliveryLng: (json['delivery_lng'] as num).toDouble(),
      status: json['status'] as String,
      totalAmount: (json['total_amount'] as num).toDouble(),
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
      events: (json['events'] as List? ?? [])
          .map((e) => OrderEvent.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      distanceKm: (json['distance_km'] as num?)?.toDouble(),
      pickupAddress: json['pickup_address'] as String?,
      pickupLat: (json['pickup_lat'] as num?)?.toDouble(),
      pickupLng: (json['pickup_lng'] as num?)?.toDouble(),
      itemDescription: json['item_description'] as String?,
      promisedBy: json['promised_by'] == null
          ? null
          : DateTime.parse(json['promised_by'] as String),
      agentEtaMinutes: json['agent_eta_minutes'] as int?,
      rating: json['rating'] as int?,
      ratingComment: json['rating_comment'] as String?,
      tripDistanceKm: (json['trip_distance_km'] as num?)?.toDouble(),
      pickupCode: json['pickup_code'] as String?,
      deliveryCode: json['delivery_code'] as String?,
    );
  }
}

class OrderEvent {
  final String status;
  final DateTime createdAt;

  const OrderEvent({required this.status, required this.createdAt});

  factory OrderEvent.fromJson(Map<String, dynamic> json) {
    return OrderEvent(
      status: json['status'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// The order lifecycle, in order (delivery-service's `Order.status` enum).
const List<String> orderStatusFlow = [
  'pending',
  'accepted',
  'picked_up',
  'in_transit',
  'delivered',
];

String formatOrderStatusLabel(String status) {
  return switch (status) {
    'pending' => 'Pending',
    'accepted' => 'Accepted',
    'picked_up' => 'Picked Up',
    'in_transit' => 'In Transit',
    'delivered' => 'Delivered',
    'cancelled' => 'Cancelled',
    _ => status,
  };
}
