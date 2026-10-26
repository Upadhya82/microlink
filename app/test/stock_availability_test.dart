import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/models/shop.dart';
import 'package:frontend/features/shop_discovery/shop_discovery_support.dart';

/// Customers see how many of each product are left, down to the last one.
Product _product(int stock, {bool available = true}) => Product(
      id: 'p1',
      shopId: 's1',
      name: 'Rice 5kg',
      description: '',
      price: 250,
      stockQuantity: stock,
      category: 'grocery',
      isAvailable: available,
    );

void main() {
  group('stockLabel on the shop page', () {
    test('in stock shows how many are available', () {
      expect(stockLabel('in_stock', quantity: 24), 'In stock · 24 available');
    });

    test('low stock shows how many are left', () {
      expect(stockLabel('low_stock', quantity: 3), 'Low stock · 3 left');
    });

    test('the very last item says so', () {
      expect(stockLabel('low_stock', quantity: 1), 'Low stock · Only 1 left');
      expect(stockLabel('in_stock', quantity: 1), 'In stock · Only 1 left');
    });

    test('without a quantity the old labels are unchanged', () {
      expect(stockLabel('in_stock'), 'In stock');
      expect(stockLabel('low_stock'), 'Low stock');
      expect(stockLabel('out_of_stock'), 'Out of stock');
    });
  });

  group('Product.availabilityLabel at checkout', () {
    test('counts down to the last item', () {
      expect(_product(12).availabilityLabel, '12 available');
      expect(_product(2).availabilityLabel, '2 available');
      expect(_product(1).availabilityLabel, 'Only 1 left');
    });

    test('nothing left is out of stock', () {
      expect(_product(0).availabilityLabel, 'Out of stock');
      expect(_product(5, available: false).availabilityLabel, 'Out of stock');
    });
  });
}
