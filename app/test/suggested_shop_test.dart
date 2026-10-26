import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/models/suggested_shop.dart';

/// The Home "User Suggestions" rail reads crowdsource-service's
/// `GET /crowdsource/shop-reports/approved`.
void main() {
  Map<String, dynamic> json({
    String? opening = '08:00',
    String? closing = '20:00',
    double? distance,
    String? photo,
  }) =>
      {
        'id': 'r1',
        'shop_name': 'Corner Grocery',
        'category': 'grocery',
        'address': '12 Temple Road',
        'latitude': 6.9271,
        'longitude': 79.8612,
        'description': 'Next to the bus stop',
        'phone': '0771234567',
        'opening_time': opening,
        'closing_time': closing,
        'photo_path': photo,
        'approved_at': '2026-10-20T08:30:00Z',
        if (distance != null) 'distance_km': distance,
      };

  test('reads every field the card and sheet show', () {
    final shop = SuggestedShop.fromJson(
      json(distance: 1.4, photo: '/crowdsource/shop-reports/r1/photo'),
    );
    expect(shop.name, 'Corner Grocery');
    expect(shop.category, 'grocery');
    expect(shop.address, '12 Temple Road');
    expect(shop.latitude, 6.9271);
    expect(shop.distanceKm, 1.4);
    expect(shop.photoPath, '/crowdsource/shop-reports/r1/photo');
    expect(shop.approvedAt.toUtc().day, 20);
  });

  test('shows opening hours only when both times are known', () {
    expect(SuggestedShop.fromJson(json()).hours, '08:00 – 20:00');
    expect(SuggestedShop.fromJson(json(closing: null)).hours, isNull);
  });

  test('no location sent means no distance', () {
    expect(SuggestedShop.fromJson(json()).distanceKm, isNull);
  });
}
