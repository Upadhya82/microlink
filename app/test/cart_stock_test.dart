import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/models/shop.dart';
import 'package:frontend/features/orders/cart_controller.dart';

/// Item 12: the cart must not promise stock the shop does not have, and when
/// the server refuses the order (409) the cart is brought back in step.
Product _product({
  String id = 'p1',
  String name = 'Rice 5kg',
  int stock = 10,
  bool available = true,
  double price = 100,
}) =>
    Product(
      id: id,
      shopId: 's1',
      name: name,
      description: '',
      price: price,
      stockQuantity: stock,
      category: 'grocery',
      isAvailable: available,
    );

void main() {
  final cart = CartController.instance;

  // The cart is a singleton, so each test starts from empty.
  setUp(cart.clear);

  group('adding to the cart', () {
    test('a product in stock is added', () {
      final added = cart.add(_product(), shopId: 's1', shopName: 'Shop');
      expect(added, isTrue);
      expect(cart.quantityOf('p1'), 1);
    });

    test('a product with nothing left is refused', () {
      final added =
          cart.add(_product(stock: 0), shopId: 's1', shopName: 'Shop');
      expect(added, isFalse);
      expect(cart.isEmpty, isTrue);
    });

    test('a product marked out of stock is refused even with units', () {
      final added = cart.add(
        _product(stock: 7, available: false),
        shopId: 's1',
        shopName: 'Shop',
      );
      expect(added, isFalse);
      expect(cart.isEmpty, isTrue);
    });

    test('the cart never holds more than the shelf has', () {
      final product = _product(stock: 2);
      expect(cart.add(product, shopId: 's1', shopName: 'Shop'), isTrue);
      expect(cart.add(product, shopId: 's1', shopName: 'Shop'), isTrue);
      expect(cart.add(product, shopId: 's1', shopName: 'Shop'), isFalse);
      expect(cart.quantityOf('p1'), 2);
    });

    test('adding from another shop starts a new cart', () {
      cart.add(_product(), shopId: 's1', shopName: 'One');
      cart.add(_product(id: 'p2'), shopId: 's2', shopName: 'Two');
      expect(cart.shopId, 's2');
      expect(cart.quantityOf('p1'), 0);
      expect(cart.quantityOf('p2'), 1);
    });
  });

  group('syncWithStock after a 409', () {
    test('a line that sold out is dropped and named', () {
      cart.add(_product(), shopId: 's1', shopName: 'Shop');
      final changed = cart.syncWithStock([_product(stock: 0)]);
      expect(changed, ['Rice 5kg']);
      expect(cart.isEmpty, isTrue);
    });

    test('a product that is gone from the shop is dropped', () {
      cart.add(_product(), shopId: 's1', shopName: 'Shop');
      final changed = cart.syncWithStock(const <Product>[]);
      expect(changed, ['Rice 5kg']);
      expect(cart.isEmpty, isTrue);
    });

    test('a line asking for more than is left is cut back', () {
      final product = _product(stock: 10);
      cart.add(product, shopId: 's1', shopName: 'Shop');
      cart.add(product, shopId: 's1', shopName: 'Shop');
      cart.add(product, shopId: 's1', shopName: 'Shop');
      expect(cart.quantityOf('p1'), 3);

      final changed = cart.syncWithStock([_product(stock: 2)]);
      expect(changed, ['Rice 5kg']);
      expect(cart.quantityOf('p1'), 2);
    });

    test('a line that still fits is left alone', () {
      cart.add(_product(stock: 10), shopId: 's1', shopName: 'Shop');
      final changed = cart.syncWithStock([_product(stock: 10)]);
      expect(changed, isEmpty);
      expect(cart.quantityOf('p1'), 1);
    });

    test('a changed price is picked up', () {
      cart.add(_product(price: 100), shopId: 's1', shopName: 'Shop');
      cart.syncWithStock([_product(price: 120)]);
      expect(cart.total, 120);
    });

    test('only the short line is touched in a two-line cart', () {
      cart.add(_product(), shopId: 's1', shopName: 'Shop');
      cart.add(
        _product(id: 'p2', name: 'Dhal 1kg'),
        shopId: 's1',
        shopName: 'Shop',
      );

      final changed = cart.syncWithStock([
        _product(stock: 0),
        _product(id: 'p2', name: 'Dhal 1kg'),
      ]);

      expect(changed, ['Rice 5kg']);
      expect(cart.quantityOf('p1'), 0);
      expect(cart.quantityOf('p2'), 1);
      expect(cart.shopId, 's1');
    });

    test('a cart emptied by the sync forgets its shop', () {
      cart.add(_product(), shopId: 's1', shopName: 'Shop');
      cart.syncWithStock(const <Product>[]);
      expect(cart.shopId, isNull);
      expect(cart.shopName, isNull);
    });

    test('syncing an empty cart changes nothing', () {
      expect(cart.syncWithStock([_product()]), isEmpty);
      expect(cart.isEmpty, isTrue);
    });
  });
}
