import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/models/app_notification.dart';
import 'package:frontend/core/models/order.dart';
import 'package:frontend/core/models/shop.dart';
import 'package:frontend/core/widgets/list_filter_bar.dart';
import 'package:frontend/core/widgets/order_filters.dart';
import 'package:frontend/core/widgets/shop_filters.dart';
import 'package:frontend/features/notifications/screens/notifications_screen.dart';
import 'package:frontend/features/shop_owner/widgets/owner_filters.dart';

/// The filters added across the app's lists.
DeliveryOrder _order(String id, String status, {List<Map<String, dynamic>>? items, double? distance}) =>
    DeliveryOrder.fromJson({
      'id': id,
      'customer_id': 'c1',
      'shop_id': 's1',
      'items': items ?? [
        {'product_id': 'p1', 'name': 'Rice 5kg', 'quantity': 1, 'price': 250},
      ],
      'delivery_address': '12 Temple Road, Kandy',
      'delivery_lat': 7.29,
      'delivery_lng': 80.63,
      'status': status,
      'total_amount': 250,
      'created_at': '2026-10-20T08:00:00Z',
      'updated_at': '2026-10-20T08:00:00Z',
      if (distance != null) 'distance_km': distance,
    });

Shop _shop(String name, String category, {bool open = true}) => Shop.fromJson({
      'id': name,
      'owner_id': 'o1',
      'name': name,
      'category': category,
      'address': 'Main Street',
      'latitude': 7.0,
      'longitude': 80.0,
      'is_open': open,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-01-01T00:00:00Z',
    });

Product _product(String name, int stock, {bool hidden = false}) => Product(
      id: name,
      shopId: 's1',
      name: name,
      description: '',
      price: 100,
      stockQuantity: stock,
      category: 'grocery',
      isAvailable: stock > 0,
      isHidden: hidden,
    );

void main() {
  group('shared helpers', () {
    test('matchesQuery ignores case and empty searches match everything', () {
      expect(matchesQuery('', ['anything']), isTrue);
      expect(matchesQuery('RICE', ['Rice 5kg']), isTrue);
      expect(matchesQuery('milk', ['Rice 5kg', null]), isFalse);
    });

    test('valueFilterOptions counts each value', () {
      final options = valueFilterOptions(['open', 'resolved', 'open']);
      expect(options.first.value, 'all');
      expect(options.first.count, 3);
      expect(options.firstWhere((o) => o.value == 'open').count, 2);
    });
  });

  group('orders', () {
    final orders = [
      _order('aaaa-0001', 'pending'),
      _order('bbbb-0002', 'delivered'),
      _order('cccc-0003', 'cancelled'),
      _order('dddd-0004', 'in_transit', items: const [], distance: 1.5),
    ];

    test('status groups', () {
      expect(orderStatusGroup('accepted'), 'active');
      expect(orderStatusGroup('delivered'), 'delivered');
      expect(orderStatusGroup('cancelled'), 'cancelled');
    });

    test('filter by group and search by item or order number', () {
      expect(filterOrders(orders, group: 'active').length, 2);
      expect(filterOrders(orders, group: 'delivered').single.id, 'bbbb-0002');
      expect(filterOrders(orders, query: 'rice').length, 3);
      expect(filterOrders(orders, query: '0003').single.id, 'cccc-0003');
    });

    test('driver jobs: distance and parcel filters', () {
      expect(filterAvailableJobs(orders, 'near2').single.id, 'dddd-0004');
      expect(filterAvailableJobs(orders, 'parcel').single.id, 'dddd-0004');
      expect(filterAvailableJobs(orders, 'shop').length, 3);
    });
  });

  group('shops', () {
    final shops = [
      _shop('Kamal Super', 'grocery'),
      _shop('Nimal Pharmacy', 'pharmacy', open: false),
    ];

    test('category, open now and search', () {
      expect(filterShops(shops, filter: 'pharmacy').single.name, 'Nimal Pharmacy');
      expect(filterShops(shops, filter: openNowFilter).single.name, 'Kamal Super');
      expect(filterShops(shops, query: 'kamal').single.name, 'Kamal Super');
    });

    test('options list only categories that are present', () {
      final values = shopFilterOptions(shops).map((o) => o.value).toList();
      expect(values, containsAll(['all', openNowFilter, 'grocery', 'pharmacy']));
      expect(values, isNot(contains('electronics')));
    });
  });

  group('owner products', () {
    final products = [
      _product('Rice', 20),
      _product('Milk', 3),
      _product('Bread', 0, hidden: true),
    ];

    test('stock groups and hidden', () {
      expect(filterOwnerProducts(products, filter: 'in').single.name, 'Rice');
      expect(filterOwnerProducts(products, filter: 'low').single.name, 'Milk');
      expect(filterOwnerProducts(products, filter: 'out').single.name, 'Bread');
      expect(filterOwnerProducts(products, filter: 'hidden').single.name, 'Bread');
      expect(filterOwnerProducts(products, query: 'mil').single.name, 'Milk');
    });
  });

  group('notifications', () {
    AppNotification note(String id, String kind, {bool read = false}) => AppNotification.fromJson({
          'id': id,
          'title': 'Title $id',
          'body': 'Body about $kind',
          'kind': kind,
          'is_read': read,
        });

    final items = [
      note('1', 'order'),
      note('2', 'shop_alert', read: true),
      note('3', 'crowdsource'),
    ];

    test('groups, unread and search', () {
      expect(notificationGroup('shop_alert'), 'shops');
      expect(filterNotifications(items, filter: 'unread').length, 2);
      expect(filterNotifications(items, filter: 'community').single.id, '3');
      expect(filterNotifications(items, query: 'order').single.id, '1');
    });
  });
}
