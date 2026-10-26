import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/features/admin/screens/admin_product_categories_tab.dart';
import 'package:frontend/features/shop_owner/widgets/product_category_field.dart';

/// Predefined product categories with an "Others" option.
void main() {
  const options = [
    ProductCategoryOption('grocery', 'Grocery'),
    ProductCategoryOption('first-aid', 'First aid'),
    ProductCategoryOption('men', "Men's clothing"),
  ];

  test('names compare without case, spacing or punctuation', () {
    expect(categoryNameKey('  First-Aid '), 'first aid');
    expect(categoryNameKey("Men's  Clothing"), 'men s clothing');
  });

  test('an existing product category is matched to the list', () {
    expect(matchCategoryOption('grocery', options), 'grocery');
    expect(matchCategoryOption('First Aid', options), 'first-aid');
    expect(matchCategoryOption("men's clothing", options), 'men');
  });

  test('anything else is an "Others" category', () {
    expect(matchCategoryOption('Pet food', options), isNull);
    expect(matchCategoryOption('', options), isNull);
  });

  test('the admin gets a tidy default name', () {
    expect(suggestedLabel('  pet   food '), 'Pet food');
    expect(suggestedLabel(''), '');
  });

  test('a suggestion reads the review list', () {
    final s = CategorySuggestion.fromJson({
      'name': 'Pet food',
      'product_count': 3,
      'shop_count': 2,
      'example_products': ['Dog biscuits', 'Cat food tin'],
    });
    expect(s.productCount, 3);
    expect(s.shopCount, 2);
    expect(s.examples, hasLength(2));
  });
}
