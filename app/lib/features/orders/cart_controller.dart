import 'package:flutter/foundation.dart';

import '../../core/models/shop.dart';

/// One product in the cart, with the quantity the customer wants.
class CartLine {
  final Product product;
  final int quantity;

  const CartLine({required this.product, required this.quantity});

  /// Charged at the discounted price -- the customer is shown "Rs.90, was
  /// Rs.120", so billing the original would be a straightforward lie.
  double get lineTotal => product.finalPrice * quantity;

  /// What this line would have cost without the discount, for the savings
  /// line at checkout.
  double get lineTotalBeforeDiscount => product.price * quantity;

  CartLine copyWith({int? quantity}) =>
      CartLine(product: product, quantity: quantity ?? this.quantity);

  /// The shape delivery-service stores in `Order.items` (opaque JSON to it,
  /// so the names here are what every later screen and the shop-stats
  /// endpoint will read back).
  Map<String, dynamic> toOrderItem() => {
        'product_id': product.id,
        'name': product.name,
        'quantity': quantity,
        'price': product.finalPrice,
        // Kept so an order receipt can still show what the discount was.
        'original_price': product.price,
        'discount_percent': product.discountPercent,
      };
}

/// The customer's cart.
///
/// Deliberately **single-shop**: an order in delivery-service belongs to one
/// `shop_id` and is carried by one agent, so a cart spanning two shops
/// could not be placed. Adding a product from a different shop asks the
/// customer to start a new cart rather than silently dropping items.
class CartController extends ChangeNotifier {
  CartController._();
  static final CartController instance = CartController._();

  String? _shopId;
  String? _shopName;
  final Map<String, CartLine> _lines = {};

  String? get shopId => _shopId;
  String? get shopName => _shopName;

  List<CartLine> get lines => _lines.values.toList(growable: false);

  bool get isEmpty => _lines.isEmpty;

  int get itemCount => _lines.values.fold(0, (sum, line) => sum + line.quantity);

  double get total => _lines.values.fold(0, (sum, line) => sum + line.lineTotal);

  /// Total before any discounts, so checkout can show the saving.
  double get totalBeforeDiscount =>
      _lines.values.fold(0, (sum, line) => sum + line.lineTotalBeforeDiscount);

  double get totalSavings => totalBeforeDiscount - total;

  bool get hasSavings => totalSavings > 0.009;

  int quantityOf(String productId) => _lines[productId]?.quantity ?? 0;

  /// True when [shopId] is a different shop from the one already in the cart.
  bool wouldReplaceCart(String shopId) =>
      _shopId != null && _shopId != shopId && _lines.isNotEmpty;

  /// Adds one of [product]. Pass [shopName] so the cart can name the shop
  /// without another lookup. Returns false when the shelf cannot cover it,
  /// so the screen can say why nothing happened.
  bool add(Product product, {required String shopId, required String shopName}) {
    // Nothing on the shelf, or the owner marked it unavailable. The old
    // check read `stockQuantity > 0 && ...`, which let a product showing 0
    // units be added in any quantity -- the order then failed at the till.
    if (!product.isAvailable || product.stockQuantity <= 0) return false;

    if (_shopId != shopId) {
      _lines.clear();
      _shopId = shopId;
      _shopName = shopName;
    }
    final existing = _lines[product.id];
    final nextQuantity = (existing?.quantity ?? 0) + 1;
    // Never let the cart promise more than the shop has on the shelf.
    if (nextQuantity > product.stockQuantity) return false;
    _lines[product.id] = CartLine(product: product, quantity: nextQuantity);
    notifyListeners();
    return true;
  }

  /// Brings the cart back in step with the shop's current stock, after the
  /// server refused the order because something had sold out (409).
  ///
  /// [fresh] is the shop's product list as it is now. A line whose product
  /// has gone, or has nothing left, is dropped; a line asking for more than
  /// is left is cut back to what is there. Returns the names of the products
  /// that changed, so checkout can name them.
  List<String> syncWithStock(Iterable<Product> fresh) {
    final byId = {for (final product in fresh) product.id: product};
    final changed = <String>[];

    for (final line in lines) {
      final current = byId[line.product.id];
      if (current == null || !current.isAvailable || current.stockQuantity <= 0) {
        changed.add(line.product.name);
        _lines.remove(line.product.id);
        continue;
      }
      if (line.quantity > current.stockQuantity) {
        changed.add(current.name);
        _lines[line.product.id] =
            CartLine(product: current, quantity: current.stockQuantity);
        continue;
      }
      // Same quantity, but the price or stock may have moved on.
      _lines[line.product.id] =
          CartLine(product: current, quantity: line.quantity);
    }

    if (_lines.isEmpty) {
      _shopId = null;
      _shopName = null;
    }
    notifyListeners();
    return changed;
  }

  void remove(String productId) {
    final existing = _lines[productId];
    if (existing == null) return;
    if (existing.quantity <= 1) {
      _lines.remove(productId);
    } else {
      _lines[productId] = existing.copyWith(quantity: existing.quantity - 1);
    }
    if (_lines.isEmpty) {
      _shopId = null;
      _shopName = null;
    }
    notifyListeners();
  }

  void removeLine(String productId) {
    _lines.remove(productId);
    if (_lines.isEmpty) {
      _shopId = null;
      _shopName = null;
    }
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    _shopId = null;
    _shopName = null;
    notifyListeners();
  }
}
