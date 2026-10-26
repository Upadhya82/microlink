import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/constants/app_constants.dart';
import 'package:frontend/core/models/shop.dart';
import 'package:frontend/core/theme/app_theme.dart';
import 'package:frontend/core/widgets/status_badge.dart';

/// Customers can order a product down to its last item. Selling that last
/// item hides it until the owner unhides it. The owner keeps seeing it,
/// marked as hidden.
Product _product({
  required int stock,
  bool hidden = false,
  String? reason,
}) =>
    Product(
      id: 'p1',
      shopId: 's1',
      name: 'Rice 5kg',
      description: '',
      price: 1250,
      stockQuantity: stock,
      category: 'grocery',
      isAvailable: stock > 0,
      isHidden: hidden,
      hiddenReason: reason,
    );

void main() {
  group('Product.isHiddenFromCustomers', () {
    test('a product with only one item left is visible', () {
      expect(_product(stock: 1).isHiddenFromCustomers, isFalse);
    });

    test('a product with a few items left is visible', () {
      expect(_product(stock: 4).isHiddenFromCustomers, isFalse);
    });

    test('a product with nothing left is hidden', () {
      expect(_product(stock: 0).isHiddenFromCustomers, isTrue);
    });

    test('a product hidden after selling out stays hidden after restocking',
        () {
      expect(
        _product(stock: 10, hidden: true, reason: 'sold_out')
            .isHiddenFromCustomers,
        isTrue,
      );
    });

    test('the thresholds match the ones shop-service enforces', () {
      expect(AppConstants.minListableStock, 1);
      expect(AppConstants.lowStockThreshold, 5);
    });
  });

  group('Product.hiddenLabel', () {
    test('a visible product has no badge', () {
      expect(_product(stock: 3).hiddenLabel, isNull);
    });

    test('a sold-out product says so', () {
      expect(
        _product(stock: 0, hidden: true, reason: 'sold_out').hiddenLabel,
        'Hidden: sold out',
      );
    });

    test('a product the owner hid says so', () {
      expect(
        _product(stock: 8, hidden: true, reason: 'owner').hiddenLabel,
        'Hidden from customers',
      );
    });

    test('an empty product that was never hidden says why', () {
      expect(_product(stock: 0).hiddenLabel, 'Hidden: no stock');
    });
  });

  group('Product.fromJson', () {
    test('reads the hidden flag and reason', () {
      final product = Product.fromJson({
        'id': 'p1',
        'shop_id': 's1',
        'name': 'Rice 5kg',
        'price': 1250,
        'stock_quantity': 0,
        'is_hidden': true,
        'hidden_reason': 'sold_out',
      });
      expect(product.isHidden, isTrue);
      expect(product.hiddenReason, 'sold_out');
    });

    test('an older response without the flag is not hidden', () {
      final product = Product.fromJson({
        'id': 'p1',
        'shop_id': 's1',
        'name': 'Rice 5kg',
        'price': 1250,
        'stock_quantity': 3,
      });
      expect(product.isHidden, isFalse);
    });
  });

  group('the owner is told why a product is hidden', () {
    testWidgets('the badge shows the label', (tester) async {
      final product = _product(stock: 0, hidden: true, reason: 'sold_out');
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: StatusBadge(
              label: product.hiddenLabel!,
              background: Colors.amber,
              foreground: Colors.black,
            ),
          ),
        ),
      );

      expect(find.text('Hidden: sold out'), findsOneWidget);
    });
  });
}
