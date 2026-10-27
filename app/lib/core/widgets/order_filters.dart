import '../models/order.dart';
import 'list_filter_bar.dart';

/// Order filters shared by the customer's, shop owner's and driver's order
/// lists: Active / Delivered / Cancelled, plus a search.

/// 'active', 'delivered' or 'cancelled'.
String orderStatusGroup(String status) => switch (status) {
      'delivered' => 'delivered',
      'cancelled' => 'cancelled',
      _ => 'active',
    };

/// The last 6 characters of an order id, as shown on screen ("#A1B2C3").
String orderShortId(String id) {
  final cleaned = id.replaceAll('-', '').toUpperCase();
  return cleaned.length <= 6 ? cleaned : cleaned.substring(cleaned.length - 6);
}

/// Orders in [group] ('all' or a value from [orderStatusGroup]) matching
/// [query] by order number, item names or addresses.
List<DeliveryOrder> filterOrders(
  List<DeliveryOrder> orders, {
  String group = 'all',
  String query = '',
}) {
  return orders.where((order) {
    if (group != 'all' && orderStatusGroup(order.status) != group) return false;
    return matchesQuery(query, [
      orderShortId(order.id),
      order.id,
      order.deliveryAddress,
      order.pickupAddress,
      order.itemDescription,
      for (final item in order.items) item['name']?.toString(),
    ]);
  }).toList();
}

/// The chips for an order list, with counts.
List<FilterOption<String>> orderFilterOptions(List<DeliveryOrder> orders) {
  final counts = countBy(orders, (DeliveryOrder o) => orderStatusGroup(o.status));
  return [
    FilterOption('all', 'All', count: orders.length),
    FilterOption('active', 'Active', count: counts['active'] ?? 0),
    FilterOption('delivered', 'Delivered', count: counts['delivered'] ?? 0),
    FilterOption('cancelled', 'Cancelled', count: counts['cancelled'] ?? 0),
  ];
}

// ---------------------------------------------------------------------------
// Driver: available deliveries
// ---------------------------------------------------------------------------

/// A parcel the customer asked to have carried ("Request a delivery"), as
/// opposed to an order from a shop: it has no product lines.
bool isParcelRequest(DeliveryOrder order) => order.items.isEmpty;

/// Available jobs under [filter]: 'all', 'near2' (within 2 km), 'near5'
/// (within 5 km), 'shop' (shop orders) or 'parcel' (parcel requests).
List<DeliveryOrder> filterAvailableJobs(List<DeliveryOrder> orders, String filter) {
  return orders.where((order) {
    final distance = order.distanceKm;
    return switch (filter) {
      'near2' => distance != null && distance <= 2,
      'near5' => distance != null && distance <= 5,
      'shop' => !isParcelRequest(order),
      'parcel' => isParcelRequest(order),
      _ => true,
    };
  }).toList();
}

List<FilterOption<String>> availableJobFilterOptions(List<DeliveryOrder> orders) {
  int count(String filter) => filterAvailableJobs(orders, filter).length;
  return [
    FilterOption('all', 'All', count: orders.length),
    FilterOption('near2', 'Within 2 km', count: count('near2')),
    FilterOption('near5', 'Within 5 km', count: count('near5')),
    FilterOption('shop', 'Shop orders', count: count('shop')),
    FilterOption('parcel', 'Parcels', count: count('parcel')),
  ];
}
