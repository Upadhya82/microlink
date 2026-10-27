import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/features/location/widgets/area_search_field.dart';

/// Searching a shop by name from the map's search bar.
///
/// The bar used to ask `/shops/landmark` only, which geocodes a PLACE. A
/// shop name either came back 404 ("thusitha bakers") or, worse, matched a
/// town hiding inside the name ("diyagama bakers" landed on the town of
/// Diyagama and listed whatever was near it, which looks like a result and
/// is not one). It now also asks `/shops?q=`, which matches shop names, and
/// a tapped suggestion opens that shop's page.
///
/// These cover the parsing of a suggestion. The debounce and the request
/// race live in widget state and are exercised by running the app.
void main() {
  group('ShopMatch.fromJson', () {
    test('reads the fields a suggestion row shows', () {
      final shop = ShopMatch.fromJson(const {
        'id': 'shop-1',
        'name': 'thusitha bakers',
        'address': 'diyagama, homagama',
        'category': 'bakery',
      });

      expect(shop.id, 'shop-1');
      expect(shop.name, 'thusitha bakers');
      expect(shop.address, 'diyagama, homagama');
      expect(shop.category, 'bakery');
    });

    test('a shop with no address still parses', () {
      // The row falls back to showing the category, so an empty address
      // must not be null and must not throw.
      final shop = ShopMatch.fromJson(const {
        'id': 'shop-2',
        'name': 'Corner Shop',
        'category': 'grocery',
      });

      expect(shop.address, '');
      expect(shop.category, 'grocery');
    });

    test('an unknown category falls back rather than throwing', () {
      final shop = ShopMatch.fromJson(const {
        'id': 'shop-3',
        'name': 'Mystery Shop',
      });

      expect(shop.category, 'other');
      expect(shop.name, 'Mystery Shop');
    });

    test('the id is what the shop page is opened with', () {
      // The whole point of the suggestion: it carries the id, so tapping
      // can open the profile directly instead of searching again.
      final shop = ShopMatch.fromJson(const {
        'id': '33333333-3333-3333-3333-333333333333',
        'name': 'Nimal Pharmacy',
        'address': 'Homagama',
        'category': 'pharmacy',
      });

      expect(shop.id, '33333333-3333-3333-3333-333333333333');
    });
  });

  group('SearchedArea', () {
    test('still carries what the area jump needs', () {
      // Enter keeps meaning "go to this area": /shops?q= matches addresses
      // too, so submitting "Homagama" must move the map rather than open
      // some shop that happens to be in Homagama.
      const area = SearchedArea(
        name: 'Homagama',
        latitude: 6.8441,
        longitude: 80.0020,
        shopCount: 13,
      );

      expect(area.name, 'Homagama');
      expect(area.latitude, 6.8441);
      expect(area.shopCount, 13);
    });
  });
}
