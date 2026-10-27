import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/models/suggested_shop.dart';
import 'package:frontend/core/theme/app_theme.dart';
import 'package:frontend/features/home/widgets/suggested_shop_card.dart';

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
        'distance_km': ?distance,
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

  group('the card', () {
    Future<void> show(WidgetTester tester, SuggestedShop shop) =>
        tester.pumpWidget(MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: SuggestedShopCard(shop: shop)),
        ));

    testWidgets('never claims the place is verified', (tester) async {
      // The tick used to be painted with no condition at all, so every
      // suggestion wore it. Nobody has checked a suggestion: it has no
      // owner, no listing and no products, and the app grants a tick to
      // no shop card anywhere.
      await show(tester, SuggestedShop.fromJson(json(distance: 4.3)));

      expect(find.byIcon(Icons.verified_rounded), findsNothing);
      expect(find.byIcon(Icons.verified), findsNothing);
      expect(find.byIcon(Icons.verified_outlined), findsNothing);
      expect(find.byIcon(Icons.verified_user), findsNothing);
    });

    testWidgets('says what it is instead', (tester) async {
      await show(tester, SuggestedShop.fromJson(json(distance: 4.3)));

      expect(find.text('SUGGESTED'), findsOneWidget);
      expect(find.text('Corner Grocery'), findsOneWidget);
    });

    testWidgets('a long name is cut off rather than overflowing',
        (tester) async {
      // Dropping the tick left the name on its own; it still has to stay on
      // one line inside the 190px card.
      final shop = SuggestedShop.fromJson({
        ...json(distance: 4.3),
        'shop_name': 'Nimal Hardware and General Trading Centre, Pitipana',
      });
      await show(tester, shop);

      final name = tester.widget<Text>(find.text(shop.name));
      expect(name.maxLines, 1);
      expect(name.overflow, TextOverflow.ellipsis);
      expect(tester.takeException(), isNull);
    });
  });
}
