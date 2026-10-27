import '../../../core/constants/app_constants.dart';
import '../../../core/models/shop.dart';
import '../../../core/widgets/list_filter_bar.dart';

/// Filters for the shop owner's Products tab.

/// 'out' (nothing left), 'low' (1 to the low-stock line) or 'in'.
String productStockGroup(Product product) {
  if (product.stockQuantity <= 0) return 'out';
  if (product.stockQuantity <= AppConstants.lowStockThreshold) return 'low';
  return 'in';
}

/// Products under [filter] ('all', 'in', 'low', 'out' or 'hidden') that
/// match [query] by name, description or category.
List<Product> filterOwnerProducts(
  List<Product> products, {
  String filter = 'all',
  String query = '',
}) {
  return products.where((product) {
    switch (filter) {
      case 'hidden':
        if (!product.isHidden) return false;
      case 'in':
      case 'low':
      case 'out':
        if (productStockGroup(product) != filter) return false;
    }
    return matchesQuery(query, [
      product.name,
      product.description,
      product.category,
      formatCategoryLabel(product.category),
    ]);
  }).toList();
}

List<FilterOption<String>> ownerProductFilterOptions(List<Product> products) {
  final counts = countBy(products, productStockGroup);
  return [
    FilterOption('all', 'All', count: products.length),
    FilterOption('in', 'In stock', count: counts['in'] ?? 0),
    FilterOption('low', 'Low stock', count: counts['low'] ?? 0),
    FilterOption('out', 'Out of stock', count: counts['out'] ?? 0),
    FilterOption('hidden', 'Hidden', count: products.where((p) => p.isHidden).length),
  ];
}
