import '../models/shop.dart';
import 'list_filter_bar.dart';

/// Shop-list filters shared by My Favorites and Recommended For You:
/// a category chip row (only categories that are in the list), "Open now",
/// and a search over name, address and category.

const String openNowFilter = '__open_now__';

List<Shop> filterShops(
  List<Shop> shops, {
  String filter = 'all',
  String query = '',
}) {
  return shops.where((shop) {
    if (filter == openNowFilter && !shop.isOpen) return false;
    if (filter != 'all' && filter != openNowFilter && shop.category != filter) return false;
    return matchesQuery(query, [
      shop.name,
      shop.address,
      shop.category,
      formatCategoryLabel(shop.category),
    ]);
  }).toList();
}

List<FilterOption<String>> shopFilterOptions(List<Shop> shops) {
  final byCategory = countBy(shops, (Shop s) => s.category);
  final categories = byCategory.keys.toList()
    ..sort((a, b) => formatCategoryLabel(a).compareTo(formatCategoryLabel(b)));
  return [
    FilterOption('all', 'All', count: shops.length),
    FilterOption(openNowFilter, 'Open now', count: shops.where((s) => s.isOpen).length),
    for (final category in categories)
      FilterOption(category, formatCategoryLabel(category), count: byCategory[category]),
  ];
}
