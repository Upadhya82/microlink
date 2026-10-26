import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/features/shop_owner/widgets/shop_performance_section.dart';

/// The shop owner's "Performance over time" filters.
void main() {
  final joined = DateTime(2025, 8, 14);
  final today = DateTime(2026, 10, 25);

  group('resolvePeriod', () {
    test('all time runs from the day the owner joined to today', () {
      final range = resolvePeriod(
        const PerformancePeriod.allTime(),
        joined: joined,
        today: today,
      );
      expect(range.start, DateTime(2025, 8, 14));
      expect(range.end, DateTime(2026, 10, 25));
    });

    test('the joining year starts on the joining day', () {
      final range = resolvePeriod(
        const PerformancePeriod.year(2025),
        joined: joined,
        today: today,
      );
      expect(range.start, DateTime(2025, 8, 14));
      expect(range.end, DateTime(2025, 12, 31));
    });

    test('this year stops at today', () {
      final range = resolvePeriod(
        const PerformancePeriod.year(2026),
        joined: joined,
        today: today,
      );
      expect(range.start, DateTime(2026, 1, 1));
      expect(range.end, DateTime(2026, 10, 25));
    });

    test('a month covers the whole month', () {
      final range = resolvePeriod(
        const PerformancePeriod.year(2026, month: 2),
        joined: joined,
        today: today,
      );
      expect(range.start, DateTime(2026, 2, 1));
      expect(range.end, DateTime(2026, 2, 28));
    });

    test('custom dates are kept inside joined..today', () {
      final range = resolvePeriod(
        PerformancePeriod.custom(
          DateTimeRange(start: DateTime(2024, 1, 1), end: DateTime(2027, 1, 1)),
        ),
        joined: joined,
        today: today,
      );
      expect(range.start, DateTime(2025, 8, 14));
      expect(range.end, DateTime(2026, 10, 25));
    });
  });

  group('granularityFor', () {
    test('a month or less is shown day by day', () {
      expect(
        granularityFor(DateTimeRange(start: DateTime(2026, 2, 1), end: DateTime(2026, 2, 28))),
        'day',
      );
    });

    test('a year is shown month by month', () {
      expect(
        granularityFor(DateTimeRange(start: DateTime(2026, 1, 1), end: DateTime(2026, 12, 31))),
        'month',
      );
    });

    test('more than two years is shown year by year', () {
      expect(
        granularityFor(DateTimeRange(start: DateTime(2023, 1, 1), end: DateTime(2026, 10, 25))),
        'year',
      );
    });
  });

  test('years and months offered start from when the owner joined', () {
    expect(selectableYears(joined: joined, today: today), [2026, 2025]);
    expect(selectableMonths(2025, joined: joined, today: today), [8, 9, 10, 11, 12]);
    expect(selectableMonths(2026, joined: joined, today: today), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  });

  test('views and sales are merged by period', () {
    final data = PerformanceData.merge(
      {
        'buckets': [
          {'period': '2026-01', 'views': 10, 'search_impressions': 40},
          {'period': '2026-02', 'views': 5, 'search_impressions': 12},
        ],
        'total_views': 15,
        'total_search_impressions': 52,
      },
      {
        'buckets': [
          {'period': '2026-01', 'sales': 1500.0, 'delivered_orders': 3, 'items_sold': 7},
          {'period': '2026-02', 'sales': 0.0, 'delivered_orders': 0, 'items_sold': 0},
        ],
        'totals': {
          'sales': 1500.0,
          'delivered_orders': 3,
          'items_sold': 7,
          'orders_placed': 4,
          'cancelled_orders': 1,
        },
        'top_products': [
          {'name': 'Rice 5kg', 'quantity': 5, 'sales': 1250.0},
        ],
      },
    );
    expect(data.buckets, hasLength(2));
    expect(data.buckets.first.views, 10);
    expect(data.buckets.first.sales, 1500.0);
    expect(data.sales, 1500.0);
    expect(data.cancelledOrders, 1);
    expect(data.views, 15);
    expect(data.topProducts.single.name, 'Rice 5kg');
    expect(data.salesAvailable, isTrue);
  });

  test('views still show when sales could not be loaded', () {
    final data = PerformanceData.merge(
      {
        'buckets': [
          {'period': '2026', 'views': 3, 'search_impressions': 9},
        ],
        'total_views': 3,
        'total_search_impressions': 9,
      },
      null,
    );
    expect(data.salesAvailable, isFalse);
    expect(data.views, 3);
    expect(data.buckets.single.sales, 0);
  });

  test('labels and money read naturally', () {
    expect(periodLabel('2026-10-25'), '25');
    expect(periodLabel('2026-10'), 'Oct');
    expect(periodLabel('2026-10', showYear: true), "Oct '26");
    expect(periodLabel('2026'), '2026');
    expect(periodLongLabel('2026-10'), 'October 2026');
    expect(formatMetric(PerformanceMetric.sales, 12500), 'Rs. 12,500.00');
    expect(formatMetric(PerformanceMetric.views, 1234), '1,234');
  });
}
