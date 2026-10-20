import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/constants/app_constants.dart';
import 'package:frontend/core/models/shop.dart';
import 'package:frontend/core/theme/app_theme.dart';
import 'package:frontend/core/widgets/app_text_field.dart';
import 'package:frontend/core/widgets/status_badge.dart';

/// Item 11: a product needs [AppConstants.minListableStock] in stock before
/// customers see it. The owner keeps seeing it, marked as hidden.
Product _product({required int stock}) => Product(
      id: 'p1',
      shopId: 's1',
      name: 'Rice 5kg',
      description: '',
      price: 1250,
      stockQuantity: stock,
      category: 'grocery',
      isAvailable: true,
    );

void main() {
  group('Product.isHiddenFromCustomers', () {
    test('a product at the minimum is visible', () {
      expect(
        _product(stock: AppConstants.minListableStock).isHiddenFromCustomers,
        isFalse,
      );
    });

    test('a product above the minimum is visible', () {
      expect(_product(stock: 40).isHiddenFromCustomers, isFalse);
    });

    test('a product one below the minimum is hidden', () {
      expect(
        _product(stock: AppConstants.minListableStock - 1)
            .isHiddenFromCustomers,
        isTrue,
      );
    });

    test('a product with nothing left is hidden', () {
      expect(_product(stock: 0).isHiddenFromCustomers, isTrue);
    });

    test('the threshold matches the one shop-service enforces', () {
      expect(AppConstants.minListableStock, 5);
    });
  });

  group('the owner is told why a product is hidden', () {
    testWidgets('the badge names the threshold', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: StatusBadge(
                label:
                    'Hidden: under ${AppConstants.minListableStock} in stock',
                background: Colors.amber,
                foreground: Colors.black,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Hidden: under 5 in stock'), findsOneWidget);
    });
  });

  group('AppTextField helper text', () {
    testWidgets('a rule under the field is shown to the owner', (tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: AppTextField(
              controller: controller,
              label: 'Stock quantity',
              helperText: 'Customers only see products with at least '
                  '${AppConstants.minListableStock} in stock.',
            ),
          ),
        ),
      );

      expect(
        find.text(
          'Customers only see products with at least 5 in stock.',
        ),
        findsOneWidget,
      );
    });
  });
}
