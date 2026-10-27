import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_card.dart';

// ---------------------------------------------------------------------------
// Period rules (pure, tested in test/shop_performance_test.dart)
// ---------------------------------------------------------------------------

/// Which stretch of time the owner is looking at.
enum PeriodKind { allTime, year, custom }

/// A chosen period, from the day the owner joined MicroLink up to today.
class PerformancePeriod {
  final PeriodKind kind;

  /// Set for [PeriodKind.year].
  final int? year;

  /// 1-12, or null for the whole year. Only used with [PeriodKind.year].
  final int? month;

  /// Set for [PeriodKind.custom].
  final DateTimeRange? range;

  const PerformancePeriod.allTime()
      : kind = PeriodKind.allTime,
        year = null,
        month = null,
        range = null;

  const PerformancePeriod.year(int this.year, {this.month})
      : kind = PeriodKind.year,
        range = null;

  const PerformancePeriod.custom(DateTimeRange this.range)
      : kind = PeriodKind.custom,
        year = null,
        month = null;
}

DateTime _dayOnly(DateTime value) => DateTime(value.year, value.month, value.day);

/// The first and last day of [period], kept between [joined] and [today].
DateTimeRange resolvePeriod(
  PerformancePeriod period, {
  required DateTime joined,
  required DateTime today,
}) {
  final first = _dayOnly(joined);
  final last = _dayOnly(today);
  DateTime start;
  DateTime end;
  switch (period.kind) {
    case PeriodKind.allTime:
      start = first;
      end = last;
    case PeriodKind.year:
      final year = period.year!;
      if (period.month == null) {
        start = DateTime(year, 1, 1);
        end = DateTime(year, 12, 31);
      } else {
        start = DateTime(year, period.month!, 1);
        end = DateTime(year, period.month! + 1, 0); // last day of the month
      }
    case PeriodKind.custom:
      start = _dayOnly(period.range!.start);
      end = _dayOnly(period.range!.end);
  }
  if (start.isBefore(first)) start = first;
  if (end.isAfter(last)) end = last;
  if (end.isBefore(start)) end = start;
  return DateTimeRange(start: start, end: end);
}

/// How finely to split a period into bars: days for up to a month, months
/// for up to two years, years beyond that.
String granularityFor(DateTimeRange range) {
  final days = range.end.difference(range.start).inDays + 1;
  if (days <= 31) return 'day';
  final months = (range.end.year - range.start.year) * 12 +
      range.end.month -
      range.start.month +
      1;
  if (months <= 24) return 'month';
  return 'year';
}

/// The years an owner can pick: from the year they joined to this year,
/// newest first.
List<int> selectableYears({required DateTime joined, required DateTime today}) => [
      for (var year = today.year; year >= joined.year; year--) year,
    ];

/// The months of [year] that fall between [joined] and [today].
List<int> selectableMonths(
  int year, {
  required DateTime joined,
  required DateTime today,
}) {
  final from = year == joined.year ? joined.month : 1;
  final to = year == today.year ? today.month : 12;
  return [for (var month = from; month <= to; month++) month];
}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

/// One bar's worth of figures.
class PerformanceBucket {
  final String period; // 2026-10-25, 2026-10 or 2026
  final double sales;
  final int deliveredOrders;
  final int itemsSold;
  final int views;
  final int searchImpressions;

  const PerformanceBucket({
    required this.period,
    this.sales = 0,
    this.deliveredOrders = 0,
    this.itemsSold = 0,
    this.views = 0,
    this.searchImpressions = 0,
  });
}

class TopProduct {
  final String name;
  final int quantity;
  final double sales;
  const TopProduct(this.name, this.quantity, this.sales);
}

class PerformanceData {
  final List<PerformanceBucket> buckets;
  final double sales;
  final int deliveredOrders;
  final int itemsSold;
  final int ordersPlaced;
  final int cancelledOrders;
  final int views;
  final int searchImpressions;
  final List<TopProduct> topProducts;

  /// False when the sales figures could not be loaded (views still shown).
  final bool salesAvailable;

  const PerformanceData({
    required this.buckets,
    required this.sales,
    required this.deliveredOrders,
    required this.itemsSold,
    required this.ordersPlaced,
    required this.cancelledOrders,
    required this.views,
    required this.searchImpressions,
    required this.topProducts,
    required this.salesAvailable,
  });

  /// Merges shop-service's views history and delivery-service's sales,
  /// matched by period. Either may be null when that service did not answer.
  factory PerformanceData.merge(
    Map<String, dynamic>? history,
    Map<String, dynamic>? sales,
  ) {
    final viewsByPeriod = <String, Map>{
      for (final b in (history?['buckets'] as List? ?? const []))
        (b as Map)['period'].toString(): b,
    };
    final salesByPeriod = <String, Map>{
      for (final b in (sales?['buckets'] as List? ?? const []))
        (b as Map)['period'].toString(): b,
    };
    final periods = <String>{...viewsByPeriod.keys, ...salesByPeriod.keys}.toList()
      ..sort();
    int toInt(Object? v) => (v as num?)?.toInt() ?? 0;
    double toDouble(Object? v) => (v as num?)?.toDouble() ?? 0;
    final totals = (sales?['totals'] as Map?) ?? const {};

    return PerformanceData(
      buckets: [
        for (final period in periods)
          PerformanceBucket(
            period: period,
            sales: toDouble(salesByPeriod[period]?['sales']),
            deliveredOrders: toInt(salesByPeriod[period]?['delivered_orders']),
            itemsSold: toInt(salesByPeriod[period]?['items_sold']),
            views: toInt(viewsByPeriod[period]?['views']),
            searchImpressions: toInt(viewsByPeriod[period]?['search_impressions']),
          ),
      ],
      sales: toDouble(totals['sales']),
      deliveredOrders: toInt(totals['delivered_orders']),
      itemsSold: toInt(totals['items_sold']),
      ordersPlaced: toInt(totals['orders_placed']),
      cancelledOrders: toInt(totals['cancelled_orders']),
      views: toInt(history?['total_views']),
      searchImpressions: toInt(history?['total_search_impressions']),
      topProducts: [
        for (final p in (sales?['top_products'] as List? ?? const []))
          TopProduct(
            (p as Map)['name']?.toString() ?? '',
            toInt(p['quantity']),
            toDouble(p['sales']),
          ),
      ],
      salesAvailable: sales != null,
    );
  }
}

/// What the bar chart can show.
enum PerformanceMetric { sales, orders, items, views, impressions }

extension PerformanceMetricInfo on PerformanceMetric {
  String get label => switch (this) {
        PerformanceMetric.sales => 'Sales',
        PerformanceMetric.orders => 'Orders',
        PerformanceMetric.items => 'Items sold',
        PerformanceMetric.views => 'Shop views',
        PerformanceMetric.impressions => 'Search impressions',
      };

  double valueOf(PerformanceBucket bucket) => switch (this) {
        PerformanceMetric.sales => bucket.sales,
        PerformanceMetric.orders => bucket.deliveredOrders.toDouble(),
        PerformanceMetric.items => bucket.itemsSold.toDouble(),
        PerformanceMetric.views => bucket.views.toDouble(),
        PerformanceMetric.impressions => bucket.searchImpressions.toDouble(),
      };

  bool get isMoney => this == PerformanceMetric.sales;
  bool get needsSales =>
      this == PerformanceMetric.sales ||
      this == PerformanceMetric.orders ||
      this == PerformanceMetric.items;
}

final NumberFormat _money = NumberFormat('#,##0.00');
final NumberFormat _whole = NumberFormat('#,##0');

String formatMetric(PerformanceMetric metric, double value) =>
    metric.isMoney ? 'Rs. ${_money.format(value)}' : _whole.format(value);

/// A bar's label: "25", "Oct" (or "Oct '25" across years) or "2026".
String periodLabel(String period, {bool showYear = false}) {
  final parts = period.split('-');
  if (parts.length == 3) return '${int.parse(parts[2])}';
  if (parts.length == 2) {
    final month = DateTime(int.parse(parts[0]), int.parse(parts[1]));
    return showYear ? DateFormat("MMM ''yy").format(month) : DateFormat('MMM').format(month);
  }
  return period;
}

/// The same period written out in full, for the "best period" line.
String periodLongLabel(String period) {
  final parts = period.split('-');
  if (parts.length == 3) {
    return DateFormat('d MMM yyyy').format(DateTime.parse(period));
  }
  if (parts.length == 2) {
    return DateFormat('MMMM yyyy').format(DateTime(int.parse(parts[0]), int.parse(parts[1])));
  }
  return period;
}

// ---------------------------------------------------------------------------
// Widget
// ---------------------------------------------------------------------------

/// "Performance over time": sales, orders and views for any period since the
/// owner joined, as figures, a bar chart and best sellers.
///
/// Sits under the existing analytics, which it does not change. Reads
/// `GET /shops/{id}/analytics/history` (views) and
/// `GET /delivery/orders/shop/{id}/sales` (sales).
class ShopPerformanceSection extends StatefulWidget {
  final String shopId;
  const ShopPerformanceSection({super.key, required this.shopId});

  @override
  State<ShopPerformanceSection> createState() => _ShopPerformanceSectionState();
}

class _ShopPerformanceSectionState extends State<ShopPerformanceSection>
    with AutomaticKeepAliveClientMixin {
  // Kept while scrolled out of view, so it does not reload every time.
  @override
  bool get wantKeepAlive => true;

  DateTime? _joined;
  PerformancePeriod _period = const PerformancePeriod.allTime();
  PerformanceMetric _metric = PerformanceMetric.sales;

  bool _loading = true;
  String? _error;
  PerformanceData? _data;
  DateTimeRange? _range;
  String _granularity = 'month';

  /// Bumped when the date picker is cancelled, so the Period dropdown goes
  /// back to showing the period that is still in effect.
  int _pickerCancels = 0;

  static final DateFormat _dayFormat = DateFormat('d MMM yyyy');

  DateTime get _today => DateTime.now();

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // When did this owner join MicroLink? Their account's creation date.
    try {
      final me = await ApiClient.instance.get('/users/me') as Map<String, dynamic>;
      _joined = DateTime.tryParse(me['created_at']?.toString() ?? '')?.toLocal();
    } catch (_) {
      // Falls back to the shop's own start date once the history arrives.
    }
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final joined = _joined ?? DateTime(_today.year - 1, _today.month, _today.day);
    final range = resolvePeriod(_period, joined: joined, today: _today);
    final granularity = granularityFor(range);
    final query = {
      'start': DateFormat('yyyy-MM-dd').format(range.start),
      'end': DateFormat('yyyy-MM-dd').format(range.end),
      'granularity': granularity,
    };

    Map<String, dynamic>? history;
    Map<String, dynamic>? sales;
    String? historyError;
    await Future.wait([
      () async {
        try {
          history = await ApiClient.instance.get(
            '/shops/${widget.shopId}/analytics/history',
            query: query,
          ) as Map<String, dynamic>;
        } on ApiException catch (e) {
          historyError = e.message;
        } catch (_) {
          historyError = 'Could not load your shop views.';
        }
      }(),
      () async {
        try {
          sales = await ApiClient.instance.get(
            '/delivery/orders/shop/${widget.shopId}/sales',
            query: query,
          ) as Map<String, dynamic>;
        } catch (_) {
          sales = null; // views still shown; the cards say sales are unavailable
        }
      }(),
    ]);

    if (!mounted) return;
    // No account date: start from the day the shop was added instead.
    if (_joined == null && history?['shop_created_at'] != null) {
      final shopAdded = DateTime.tryParse(history!['shop_created_at'].toString());
      if (shopAdded != null) {
        _joined = shopAdded.toLocal();
        if (_period.kind == PeriodKind.allTime) {
          await _load();
          return;
        }
      }
    }
    setState(() {
      _loading = false;
      _range = range;
      _granularity = granularity;
      if (history == null && sales == null) {
        _error = historyError ?? 'Could not load your performance.';
        _data = null;
      } else {
        _data = PerformanceData.merge(history, sales);
      }
    });
  }

  void _setPeriod(PerformancePeriod period) {
    setState(() => _period = period);
    _load();
  }

  Future<void> _pickCustomRange() async {
    final joined = _dayOnly(_joined ?? DateTime(_today.year - 1));
    final today = _dayOnly(_today);
    final current = _range;
    final initial = current != null &&
            !current.start.isBefore(joined) &&
            !current.end.isAfter(today)
        ? current
        : null;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: joined,
      lastDate: today,
      initialDateRange: initial,
      helpText: 'Choose the dates to look at',
    );
    if (!mounted) return;
    if (picked != null) {
      _setPeriod(PerformancePeriod.custom(picked));
    } else {
      setState(() => _pickerCancels++);
    }
  }

  String get _periodSummary {
    final range = _range;
    if (range == null) return '';
    return '${_dayFormat.format(range.start)} – ${_dayFormat.format(range.end)}';
  }

  String get _unitName => switch (_granularity) {
        'day' => 'day',
        'month' => 'month',
        _ => 'year',
      };

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final textTheme = Theme.of(context).textTheme;
    final secondary = context.appColors.textSecondary;
    final joined = _joined;
    final today = _today;

    // The "Period" dropdown: all time, each year since joining, custom dates.
    final periodValue = switch (_period.kind) {
      PeriodKind.allTime => 'all',
      PeriodKind.year => 'year:${_period.year}',
      PeriodKind.custom => 'custom',
    };
    final years = joined == null ? [today.year] : selectableYears(joined: joined, today: today);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Performance over time', style: textTheme.titleMedium),
        const SizedBox(height: 2),
        Text(
          joined == null
              ? 'Pick a period to see your sales and views.'
              : 'Any period since you joined on ${_dayFormat.format(joined)}.',
          style: textTheme.bodySmall?.copyWith(color: secondary),
        ),
        const SizedBox(height: AppSpacing.md),

        // --- Filters ---
        DropdownButtonFormField<String>(
          key: ValueKey('period-$periodValue-${years.length}-$_pickerCancels'),
          initialValue: periodValue,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Period',
            prefixIcon: Icon(Icons.date_range_outlined),
          ),
          items: [
            const DropdownMenuItem(value: 'all', child: Text('All time (since you joined)')),
            for (final year in years)
              DropdownMenuItem(value: 'year:$year', child: Text('Year $year')),
            const DropdownMenuItem(value: 'custom', child: Text('Custom dates…')),
          ],
          onChanged: (value) {
            if (value == null) return;
            if (value == 'all') {
              _setPeriod(const PerformancePeriod.allTime());
            } else if (value == 'custom') {
              _pickCustomRange();
            } else {
              _setPeriod(PerformancePeriod.year(int.parse(value.substring(5))));
            }
          },
        ),
        if (_period.kind == PeriodKind.year) ...[
          const SizedBox(height: AppSpacing.md),
          DropdownButtonFormField<int?>(
            key: ValueKey('month-${_period.year}-${_period.month}'),
            initialValue: _period.month,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Month',
              prefixIcon: Icon(Icons.calendar_month_outlined),
            ),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('Whole year')),
              for (final month in selectableMonths(
                _period.year!,
                joined: joined ?? DateTime(_period.year!),
                today: today,
              ))
                DropdownMenuItem<int?>(
                  value: month,
                  child: Text(DateFormat('MMMM').format(DateTime(_period.year!, month))),
                ),
            ],
            onChanged: (month) => _setPeriod(PerformancePeriod.year(_period.year!, month: month)),
          ),
        ],
        if (_period.kind == PeriodKind.custom)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: OutlinedButton.icon(
              onPressed: _pickCustomRange,
              icon: const Icon(Icons.edit_calendar_outlined),
              label: const Text('Change dates'),
            ),
          ),
        if (_range != null) ...[
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Showing $_periodSummary',
            style: textTheme.bodySmall?.copyWith(color: secondary, fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),

        // --- Results ---
        if (_loading)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.xl),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_error != null)
          AppCard(
            child: Row(
              children: [
                Expanded(child: Text(_error!)),
                TextButton(onPressed: _load, child: const Text('Retry')),
              ],
            ),
          )
        else if (_data != null)
          _results(context, _data!),
      ],
    );
  }

  Widget _results(BuildContext context, PerformanceData data) {
    final textTheme = Theme.of(context).textTheme;
    final secondary = context.appColors.textSecondary;
    final colorScheme = Theme.of(context).colorScheme;
    final salesText = data.salesAvailable ? null : 'Not available';

    final values = [for (final b in data.buckets) _metric.valueOf(b)];
    final total = values.fold<double>(0, (a, b) => a + b);
    var bestIndex = -1;
    for (var i = 0; i < values.length; i++) {
      if (values[i] > 0 && (bestIndex == -1 || values[i] > values[bestIndex])) bestIndex = i;
    }
    final spansYears = _range != null && _range!.start.year != _range!.end.year;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Figures for the period
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppSpacing.md,
          crossAxisSpacing: AppSpacing.md,
          childAspectRatio: 1.9,
          children: [
            _Figure(
              icon: Icons.payments_outlined,
              label: 'Total sales',
              value: salesText ?? formatMetric(PerformanceMetric.sales, data.sales),
            ),
            _Figure(
              icon: Icons.shopping_bag_outlined,
              label: 'Delivered orders',
              value: salesText ?? _whole.format(data.deliveredOrders),
            ),
            _Figure(
              icon: Icons.inventory_2_outlined,
              label: 'Items sold',
              value: salesText ?? _whole.format(data.itemsSold),
            ),
            _Figure(
              icon: Icons.cancel_outlined,
              label: 'Cancelled orders',
              value: salesText ??
                  '${_whole.format(data.cancelledOrders)} of ${_whole.format(data.ordersPlaced)}',
            ),
            _Figure(
              icon: Icons.visibility_outlined,
              label: 'Shop views',
              value: _whole.format(data.views),
            ),
            _Figure(
              icon: Icons.search,
              label: 'Search impressions',
              value: _whole.format(data.searchImpressions),
            ),
          ],
        ),
        if (!data.salesAvailable) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Sales figures could not be loaded just now. Pull down to try again.',
            style: textTheme.bodySmall?.copyWith(color: secondary),
          ),
        ],

        // Chart
        const SizedBox(height: AppSpacing.xl),
        Text('Chart', style: textTheme.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            for (final metric in PerformanceMetric.values)
              if (data.salesAvailable || !metric.needsSales)
                ChoiceChip(
                  label: Text(metric.label),
                  selected: _metric == metric,
                  onSelected: (_) => setState(() => _metric = metric),
                ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        AppCard(
          child: data.buckets.isEmpty
              ? Text('No data for this period.', style: TextStyle(color: secondary))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_metric.label} per $_unitName',
                      style: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _PeriodBarChart(
                      labels: [
                        for (final b in data.buckets)
                          periodLabel(b.period, showYear: spansYears),
                      ],
                      values: values,
                      color: colorScheme.primary,
                      highlight: bestIndex,
                      format: (v) => _metric.isMoney ? _compactMoney(v) : _whole.format(v),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          _chartSummary(data, values, total, bestIndex),
          style: textTheme.bodySmall?.copyWith(color: secondary),
        ),

        // Best sellers
        if (data.salesAvailable) ...[
          const SizedBox(height: AppSpacing.xl),
          Text('Best-selling products', style: textTheme.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          if (data.topProducts.isEmpty)
            Text(
              'No products sold in this period.',
              style: textTheme.bodyMedium?.copyWith(color: secondary),
            )
          else
            AppCard(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Column(
                children: [
                  for (var i = 0; i < data.topProducts.length; i++)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: CircleAvatar(
                        radius: 14,
                        backgroundColor: colorScheme.primaryContainer,
                        child: Text('${i + 1}', style: textTheme.labelMedium),
                      ),
                      title: Text(data.topProducts[i].name),
                      subtitle: Text('${_whole.format(data.topProducts[i].quantity)} sold'),
                      trailing: Text(
                        formatMetric(PerformanceMetric.sales, data.topProducts[i].sales),
                        style: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  /// The line under the chart: total, average and the best period.
  String _chartSummary(
    PerformanceData data,
    List<double> values,
    double total,
    int bestIndex,
  ) {
    if (total == 0) {
      return 'Nothing recorded for ${_metric.label.toLowerCase()} in this period yet.';
    }
    final parts = <String>[
      'Total: ${formatMetric(_metric, total)}',
      'Average: ${formatMetric(_metric, total / values.length)} per $_unitName',
    ];
    if (bestIndex >= 0) {
      final best = periodLongLabel(data.buckets[bestIndex].period);
      parts.add('Best $_unitName: $best (${formatMetric(_metric, values[bestIndex])})');
    }
    return parts.join(' · ');
  }

  /// Short money for the top of a bar: 950, 12.5K, 1.2M.
  static String _compactMoney(double value) {
    if (value >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}M';
    if (value >= 1000) return '${(value / 1000).toStringAsFixed(1)}K';
    return value.toStringAsFixed(0);
  }
}

class _Figure extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _Figure({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: AppSpacing.xs),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// Vertical bars, one per period. Scrolls sideways when there are more bars
/// than fit, so a month of days stays readable on a phone.
class _PeriodBarChart extends StatelessWidget {
  final List<String> labels;
  final List<double> values;
  final Color color;
  final int highlight;
  final String Function(double value) format;

  const _PeriodBarChart({
    required this.labels,
    required this.values,
    required this.color,
    required this.highlight,
    required this.format,
  });

  static const double _chartHeight = 140;
  static const double _barSlot = 44;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final secondary = context.appColors.textSecondary;
    final highest = values.fold<double>(0, (a, b) => a > b ? a : b);

    Widget bar(int i) {
      final fraction = highest == 0 ? 0.0 : values[i] / highest;
      final height = (fraction * _chartHeight).clamp(3.0, _chartHeight);
      final isBest = i == highlight;
      return SizedBox(
        width: _barSlot,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                values[i] == 0 ? '' : format(values[i]),
                style: textTheme.labelSmall?.copyWith(
                  fontWeight: isBest ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Container(
              width: 22,
              height: height,
              decoration: BoxDecoration(
                color: isBest ? color : color.withValues(alpha: 0.55),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(5)),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              labels[i],
              maxLines: 1,
              style: textTheme.labelSmall?.copyWith(color: secondary),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final needed = values.length * _barSlot;
        final row = Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisAlignment: needed < constraints.maxWidth
              ? MainAxisAlignment.spaceAround
              : MainAxisAlignment.start,
          children: [for (var i = 0; i < values.length; i++) bar(i)],
        );
        return SizedBox(
          height: _chartHeight + 44,
          child: needed <= constraints.maxWidth
              ? row
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  // Newest periods are on the right; start there.
                  reverse: true,
                  child: row,
                ),
        );
      },
    );
  }
}
