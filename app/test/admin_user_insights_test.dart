import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/features/admin/screens/admin_user_insights_tab.dart';

/// The admin "User Insights" tab filters and counts on the loaded list.
void main() {
  final data = UserInsights.fromJson({
    'totals': {'customer': 3, 'shop_owner': 1, 'delivery_agent': 1, 'total': 5},
    'new_this_week': {'customer': 1, 'shop_owner': 0, 'delivery_agent': 1},
    'provinces': ['Western', 'Central'],
    'districts': {
      'Western': ['Colombo', 'Gampaha', 'Kalutara'],
      'Central': ['Kandy', 'Matale', 'Nuwara Eliya'],
    },
    'users': [
      {
        'id': 'c1',
        'full_name': 'Kamal Perera',
        'email': 'kamal@example.com',
        'role': 'customer',
        'district': 'Colombo',
        'province': 'Western',
      },
      {
        'id': 'c2',
        'full_name': 'Nimali Silva',
        'email': 'nimali@example.com',
        'role': 'customer',
        'district': 'Kandy',
        'province': 'Central',
      },
      {
        'id': 'c3',
        'full_name': 'Unknown Place',
        'email': 'nowhere@example.com',
        'role': 'customer',
        'district': null,
        'province': null,
      },
      {
        'id': 'o1',
        'full_name': 'Sunil Stores',
        'email': 'sunil@example.com',
        'role': 'shop_owner',
        'district': 'Gampaha',
        'province': 'Western',
      },
      {
        'id': 'a1',
        'full_name': 'Ruwan Rider',
        'email': 'ruwan@example.com',
        'role': 'delivery_agent',
        'district': 'Colombo',
        'province': 'Western',
      },
    ],
  });

  test('reads the totals and filter lists', () {
    expect(data.totals['customer'], 3);
    expect(data.newThisWeek['delivery_agent'], 1);
    expect(data.districts['Central'], contains('Kandy'));
    expect(data.users, hasLength(5));
  });

  test('island-wide includes everyone, even with no known area', () {
    final users = filterInsightUsers(data.users);
    expect(users, hasLength(5));
    expect(countByRole(users), {'customer': 3, 'shop_owner': 1, 'delivery_agent': 1});
  });

  test('a province keeps only its users', () {
    final users = filterInsightUsers(data.users, province: 'Western');
    expect(users.map((u) => u.id), unorderedEquals(['c1', 'o1', 'a1']));
  });

  test('a district narrows it further', () {
    final users = filterInsightUsers(
      data.users,
      province: 'Western',
      district: 'Colombo',
    );
    expect(users.map((u) => u.id), unorderedEquals(['c1', 'a1']));
  });

  test('search matches a name or an email, ignoring case', () {
    expect(filterInsightUsers(data.users, query: 'kamal').single.id, 'c1');
    expect(filterInsightUsers(data.users, query: 'SUNIL@').single.id, 'o1');
    expect(filterInsightUsers(data.users, query: 'nobody-called-this'), isEmpty);
  });

  test('search and area combine', () {
    expect(
      filterInsightUsers(data.users, province: 'Central', query: 'kamal'),
      isEmpty,
    );
  });

  test('a user with no area says so', () {
    final user = data.users.firstWhere((u) => u.id == 'c3');
    expect(user.areaLabel, unknownAreaLabel);
    final kamal = data.users.firstWhere((u) => u.id == 'c1');
    expect(kamal.areaLabel, 'Colombo, Western Province');
  });
}
