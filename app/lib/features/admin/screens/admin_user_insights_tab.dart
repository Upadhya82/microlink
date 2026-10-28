import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';

/// Admin tab: how many customers, shop owners and delivery agents MicroLink
/// has, and roughly where they are.
///
/// Backed by admin-service's `GET /admin/user-insights`, which gathers users
/// from user-service and places each one in a district from data the system
/// already has (a shop's location, an agent's live location, a customer's
/// last delivery address). Filtering and search happen here, on the loaded
/// list, so changing a filter is instant and needs no new request.
class AdminUserInsightsTab extends StatefulWidget {
  const AdminUserInsightsTab({super.key});

  @override
  State<AdminUserInsightsTab> createState() => _AdminUserInsightsTabState();
}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

/// The three roles shown, in display order.
const List<String> insightRoles = ['customer', 'shop_owner', 'delivery_agent'];

String insightRoleLabel(String role) => switch (role) {
      'customer' => 'Customers',
      'shop_owner' => 'Shop owners',
      'delivery_agent' => 'Delivery agents',
      _ => role,
    };

/// Label for users whose area could not be worked out.
const String unknownAreaLabel = 'Location not known';

class InsightUser {
  final String id;
  final String fullName;
  final String email;
  final String role;
  final bool isActive;
  final DateTime? createdAt;
  final String? district;
  final String? province;

  /// False for a shop owner or delivery agent still waiting for approval.
  final bool isVerified;

  const InsightUser({
    required this.id,
    required this.fullName,
    required this.email,
    required this.role,
    required this.isActive,
    required this.createdAt,
    required this.district,
    required this.province,
    this.isVerified = true,
  });

  /// One of [insightStatuses]: deactivated wins over waiting for approval.
  String get status {
    if (!isActive) return 'deactivated';
    if (!isVerified) return 'pending';
    return 'active';
  }

  factory InsightUser.fromJson(Map<String, dynamic> json) => InsightUser(
        id: json['id']?.toString() ?? '',
        fullName: json['full_name']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        role: json['role']?.toString() ?? '',
        isActive: json['is_active'] != false,
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
        district: json['district'] as String?,
        province: json['province'] as String?,
        isVerified: json['is_verified'] != false,
      );

  String get areaLabel =>
      district == null ? unknownAreaLabel : '$district, $province Province';
}

class UserInsights {
  final Map<String, int> totals;
  final Map<String, int> newThisWeek;
  final List<String> provinces;
  final Map<String, List<String>> districts;
  final List<InsightUser> users;

  const UserInsights({
    required this.totals,
    required this.newThisWeek,
    required this.provinces,
    required this.districts,
    required this.users,
  });

  factory UserInsights.fromJson(Map<String, dynamic> json) {
    Map<String, int> counts(Object? raw) => {
          for (final entry in ((raw as Map?) ?? const {}).entries)
            entry.key.toString(): (entry.value as num?)?.toInt() ?? 0,
        };
    final rawDistricts = (json['districts'] as Map?) ?? const {};
    return UserInsights(
      totals: counts(json['totals']),
      newThisWeek: counts(json['new_this_week']),
      provinces: [
        for (final p in (json['provinces'] as List? ?? const [])) p.toString(),
      ],
      districts: {
        for (final entry in rawDistricts.entries)
          entry.key.toString(): [
            for (final d in (entry.value as List? ?? const [])) d.toString(),
          ],
      },
      users: [
        for (final u in (json['users'] as List? ?? const []))
          InsightUser.fromJson(u as Map<String, dynamic>),
      ],
    );
  }
}

/// Account states shown in the status filter and chart, in display order.
const List<String> insightStatuses = ['active', 'pending', 'deactivated'];

String insightStatusLabel(String status) => switch (status) {
      'active' => 'Active',
      'pending' => 'Waiting approval',
      'deactivated' => 'Deactivated',
      _ => status,
    };

/// "Joined" filter choices: key -> (label, how many days back; null = all).
const Map<String, (String, int?)> insightJoinedRanges = {
  'all': ('Any time', null),
  'week': ('Last 7 days', 7),
  'month': ('Last 30 days', 30),
  'quarter': ('Last 3 months', 91),
  'year': ('Last 12 months', 365),
};

/// The users that match an area filter and a search. A null [province]
/// means island-wide (everyone, including users whose area is not known);
/// a null [district] means every district in the province. A null [role]
/// or [status] means all of them; [joinedWithinDays] keeps only users who
/// joined that recently.
List<InsightUser> filterInsightUsers(
  List<InsightUser> users, {
  String? province,
  String? district,
  String query = '',
  String? role,
  String? status,
  int? joinedWithinDays,
  DateTime? now,
}) {
  final text = query.trim().toLowerCase();
  final since = joinedWithinDays == null
      ? null
      : (now ?? DateTime.now()).subtract(Duration(days: joinedWithinDays));
  return users.where((user) {
    if (province != null && user.province != province) return false;
    if (district != null && user.district != district) return false;
    if (role != null && user.role != role) return false;
    if (status != null && user.status != status) return false;
    if (since != null) {
      final joined = user.createdAt;
      if (joined == null || joined.isBefore(since)) return false;
    }
    if (text.isEmpty) return true;
    return user.fullName.toLowerCase().contains(text) ||
        user.email.toLowerCase().contains(text);
  }).toList();
}

/// How many of [users] have each role.
Map<String, int> countByRole(List<InsightUser> users) {
  final counts = {for (final role in insightRoles) role: 0};
  for (final user in users) {
    if (counts.containsKey(user.role)) counts[user.role] = counts[user.role]! + 1;
  }
  return counts;
}

/// New users per calendar month for the last [months] months (oldest
/// first), each split by role -- for the "New users per month" chart.
List<({String label, Map<String, int> counts})> joinsByMonth(
  List<InsightUser> users, {
  int months = 6,
  DateTime? now,
}) {
  const names = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final today = (now ?? DateTime.now()).toLocal();
  final rows = <({String label, Map<String, int> counts})>[];
  for (var back = months - 1; back >= 0; back--) {
    final month = DateTime(today.year, today.month - back);
    final inMonth = users.where((user) {
      final joined = user.createdAt?.toLocal();
      return joined != null &&
          joined.year == month.year &&
          joined.month == month.month;
    }).toList();
    final label = month.year == today.year
        ? names[month.month - 1]
        : "${names[month.month - 1]} '${(month.year % 100).toString().padLeft(2, '0')}";
    rows.add((label: label, counts: countByRole(inMonth)));
  }
  return rows;
}

/// How many of [users] are in each of [insightStatuses].
Map<String, int> countByStatus(List<InsightUser> users) {
  final counts = {for (final status in insightStatuses) status: 0};
  for (final user in users) {
    counts[user.status] = (counts[user.status] ?? 0) + 1;
  }
  return counts;
}

// ---------------------------------------------------------------------------
// Tab
// ---------------------------------------------------------------------------

class _AdminUserInsightsTabState extends State<AdminUserInsightsTab>
    with AutomaticKeepAliveClientMixin {
  ViewState<UserInsights> _state = const ViewLoading();
  final _searchController = TextEditingController();

  String? _province; // null = island-wide
  String? _district; // null = all districts in the province
  String _query = '';
  String? _role; // null = every role
  String? _status; // null = every status
  String _joined = 'all'; // a key of insightJoinedRanges

  /// How many matching users the list shows before "Show more".
  static const int _pageSize = 30;
  int _shown = _pageSize;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/admin/user-insights');
      if (!mounted) return;
      setState(() => _state = ViewData(
            UserInsights.fromJson(response as Map<String, dynamic>),
          ));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load user insights.'));
    }
  }

  Color _roleColor(BuildContext context, String role) {
    final scheme = Theme.of(context).colorScheme;
    return switch (role) {
      'customer' => scheme.primary,
      'shop_owner' => scheme.tertiary,
      _ => context.appColors.success,
    };
  }

  String get _scopeLabel {
    if (_district != null) return '$_district District';
    if (_province != null) return '$_province Province';
    return 'All of Sri Lanka';
  }

  Color _statusColor(BuildContext context, String status) => switch (status) {
        'active' => context.appColors.success,
        'pending' => context.appColors.warning,
        _ => Theme.of(context).colorScheme.error,
      };

  bool get _anyExtraFilter => _role != null || _status != null || _joined != 'all';

  void _resetFilters() => setState(() {
        _province = null;
        _district = null;
        _role = null;
        _status = null;
        _joined = 'all';
        _query = '';
        _searchController.clear();
        _shown = _pageSize;
      });

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<UserInsights>(
        state: _state,
        onRetry: _load,
        builder: (context, data) => _buildContent(context, data),
      ),
    );
  }

  Widget _buildContent(BuildContext context, UserInsights data) {
    final textTheme = Theme.of(context).textTheme;
    final secondary = context.appColors.textSecondary;

    final matching = filterInsightUsers(
      data.users,
      province: _province,
      district: _district,
      query: _query,
      role: _role,
      status: _status,
      joinedWithinDays: insightJoinedRanges[_joined]?.$2,
    );
    final roleCounts = countByRole(matching);
    final statusCounts = countByStatus(matching);
    // The month chart ignores the "joined" filter on purpose: it is the
    // filter's picture over time, so cutting it to one week would leave
    // five empty months.
    final monthRows = joinsByMonth(
      filterInsightUsers(
        data.users,
        province: _province,
        district: _district,
        query: _query,
        role: _role,
        status: _status,
      ),
    );
    final visibleRoles = _role == null ? insightRoles : [_role!];

    // The area chart: provinces island-wide, districts inside a province.
    final List<({String label, Map<String, int> counts})> areaRows;
    final String? areaTitle;
    if (_district != null) {
      areaRows = const [];
      areaTitle = null;
    } else if (_province != null) {
      areaTitle = 'Districts in $_province Province';
      areaRows = [
        for (final district in data.districts[_province] ?? const <String>[])
          (
            label: district,
            counts: countByRole(
              matching.where((u) => u.district == district).toList(),
            ),
          ),
      ];
    } else {
      areaTitle = 'Provinces';
      areaRows = [
        for (final province in data.provinces)
          (
            label: province,
            counts: countByRole(
              matching.where((u) => u.province == province).toList(),
            ),
          ),
        (
          label: unknownAreaLabel,
          counts: countByRole(matching.where((u) => u.province == null).toList()),
        ),
      ];
    }

    return ListView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      children: [
        // --- Totals for the whole system ---
        Text(
          'All users',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            for (final role in insightRoles) ...[
              if (role != insightRoles.first) const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _TotalCard(
                  icon: switch (role) {
                    'customer' => Icons.people_alt_outlined,
                    'shop_owner' => Icons.storefront_outlined,
                    _ => Icons.delivery_dining_outlined,
                  },
                  color: _roleColor(context, role),
                  value: data.totals[role] ?? 0,
                  label: insightRoleLabel(role),
                  newThisWeek: data.newThisWeek[role] ?? 0,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '${data.totals['total'] ?? 0} users in total (admins not counted).',
          style: textTheme.bodySmall?.copyWith(color: secondary),
        ),

        // --- Filters ---
        const SizedBox(height: AppSpacing.xl),
        Text(
          'Filter',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.sm),
        // Role
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.xs,
          children: [
            ChoiceChip(
              label: const Text('All roles'),
              selected: _role == null,
              onSelected: (_) => setState(() {
                _role = null;
                _shown = _pageSize;
              }),
            ),
            for (final role in insightRoles)
              ChoiceChip(
                label: Text(insightRoleLabel(role)),
                selected: _role == role,
                onSelected: (_) => setState(() {
                  _role = _role == role ? null : role;
                  _shown = _pageSize;
                }),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String?>(
                key: ValueKey('status-$_status'),
                initialValue: _status,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  prefixIcon: Icon(Icons.verified_user_outlined),
                ),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('All')),
                  for (final status in insightStatuses)
                    DropdownMenuItem<String?>(
                      value: status,
                      child: Text(insightStatusLabel(status)),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _status = value;
                  _shown = _pageSize;
                }),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: ValueKey('joined-$_joined'),
                initialValue: _joined,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Joined',
                  prefixIcon: Icon(Icons.event_outlined),
                ),
                items: [
                  for (final entry in insightJoinedRanges.entries)
                    DropdownMenuItem<String>(
                      value: entry.key,
                      child: Text(entry.value.$1),
                    ),
                ],
                onChanged: (value) => setState(() {
                  _joined = value ?? 'all';
                  _shown = _pageSize;
                }),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        DropdownButtonFormField<String?>(
          // Rebuilt by "Clear filters", so it shows the reset value.
          key: ValueKey('province-$_province'),
          initialValue: _province,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Area',
            prefixIcon: Icon(Icons.public),
          ),
          items: [
            const DropdownMenuItem<String?>(
              value: null,
              child: Text('Island-wide (all of Sri Lanka)'),
            ),
            for (final province in data.provinces)
              DropdownMenuItem<String?>(
                value: province,
                child: Text('$province Province'),
              ),
          ],
          onChanged: (value) => setState(() {
            _province = value;
            _district = null;
            _shown = _pageSize;
          }),
        ),
        const SizedBox(height: AppSpacing.md),
        DropdownButtonFormField<String?>(
          // Rebuilt when the province changes, so it starts from "All".
          key: ValueKey('district-$_province'),
          initialValue: _district,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'District',
            prefixIcon: const Icon(Icons.location_city_outlined),
            helperText: _province == null ? 'Choose a province first' : null,
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(
                _province == null ? 'All districts' : 'All districts in $_province',
              ),
            ),
            for (final district in data.districts[_province] ?? const <String>[])
              DropdownMenuItem<String?>(value: district, child: Text(district)),
          ],
          onChanged: _province == null
              ? null
              : (value) => setState(() {
                    _district = value;
                    _shown = _pageSize;
                  }),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _searchController,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: 'Search by name or email',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close),
                    onPressed: () => setState(() {
                      _searchController.clear();
                      _query = '';
                      _shown = _pageSize;
                    }),
                  ),
          ),
          onChanged: (value) => setState(() {
            _query = value;
            _shown = _pageSize;
          }),
        ),
        if (_province != null || _query.isNotEmpty || _anyExtraFilter)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _resetFilters,
              icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
              label: const Text('Clear filters'),
            ),
          ),

        // --- Chart: users by role for the current filter ---
        const SizedBox(height: AppSpacing.xl),
        Text(
          'Users by role · $_scopeLabel',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (_query.trim().isNotEmpty)
          Text(
            'Matching "${_query.trim()}"',
            style: textTheme.bodySmall?.copyWith(color: secondary),
          ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: _RoleBarChart(
            counts: roleCounts,
            colorFor: (role) => _roleColor(context, role),
          ),
        ),

        // --- Chart: account status ---
        const SizedBox(height: AppSpacing.xl),
        Text(
          'Users by status · $_scopeLabel',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: _RoleBarChart(
            counts: statusCounts,
            keys: insightStatuses,
            labelFor: insightStatusLabel,
            colorFor: (status) => _statusColor(context, status),
            onTap: (status) => setState(() {
              _status = _status == status ? null : status;
              _shown = _pageSize;
            }),
          ),
        ),

        // --- Chart: new users per month ---
        const SizedBox(height: AppSpacing.xl),
        Text(
          'New users per month · last 6 months',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: _MonthBarChart(
            rows: monthRows,
            roles: visibleRoles,
            colorFor: (role) => _roleColor(context, role),
          ),
        ),

        // --- Chart: by province / district ---
        if (areaTitle != null) ...[
          const SizedBox(height: AppSpacing.xl),
          Text(
            'Users by area · $areaTitle',
            style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: _AreaBarChart(
              rows: areaRows,
              colorFor: (role) => _roleColor(context, role),
              onTap: (label) {
                if (label == unknownAreaLabel) return;
                setState(() {
                  if (_province == null) {
                    _province = label;
                  } else {
                    _district = label;
                  }
                  _shown = _pageSize;
                });
              },
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Tap a bar to look inside that area. Areas are estimated from '
            'shop locations, delivery agents\' live locations, customers\' '
            'last delivery addresses, and where people suggested a shop or '
            'reported a road problem.',
            style: textTheme.bodySmall?.copyWith(color: secondary),
          ),
        ],

        // --- Matching users ---
        const SizedBox(height: AppSpacing.xl),
        Text(
          'Users (${matching.length})',
          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (matching.isEmpty)
          Text(
            'No users match these filters.',
            style: textTheme.bodyMedium?.copyWith(color: secondary),
          )
        else ...[
          for (final user in matching.take(_shown))
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _UserRow(
                user: user,
                color: _roleColor(context, user.role),
              ),
            ),
          if (matching.length > _shown)
            Center(
              child: TextButton(
                onPressed: () => setState(() => _shown += _pageSize),
                child: Text('Show more (${matching.length - _shown} left)'),
              ),
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

class _TotalCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final int value;
  final String label;
  final int newThisWeek;

  const _TotalCard({
    required this.icon,
    required this.color,
    required this.value,
    required this.label,
    required this.newThisWeek,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '$value',
            style: textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
          ),
          const SizedBox(height: 2),
          Text(
            '+$newThisWeek this week',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.labelSmall?.copyWith(
              color: newThisWeek > 0 ? context.appColors.success : context.appColors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Vertical bars, one per key: by default customers, shop owners and
/// delivery agents; the status chart passes its own keys and labels. A bar
/// can be tapped when [onTap] is given (the status chart uses it as a filter).
class _RoleBarChart extends StatelessWidget {
  final Map<String, int> counts;
  final Color Function(String role) colorFor;
  final List<String> keys;
  final String Function(String key) labelFor;
  final void Function(String key)? onTap;

  const _RoleBarChart({
    required this.counts,
    required this.colorFor,
    this.keys = insightRoles,
    this.labelFor = insightRoleLabel,
    this.onTap,
  });

  static const double _chartHeight = 160;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final highest = counts.values.fold<int>(0, (a, b) => a > b ? a : b);

    return Column(
      children: [
        SizedBox(
          height: _chartHeight + 24,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final role in keys)
                Expanded(
                  child: InkWell(
                    onTap: onTap == null ? null : () => onTap!(role),
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          '${counts[role] ?? 0}',
                          style: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                          // A thin sliver even at zero, so the bar's place is visible.
                          height: highest == 0
                              ? 3.0
                              : ((counts[role] ?? 0) / highest * _chartHeight)
                                  .clamp(3.0, _chartHeight),
                          decoration: BoxDecoration(
                            color: colorFor(role),
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: context.appColors.textSecondary.withValues(alpha: 0.3)),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            for (final role in keys)
              Expanded(
                child: Text(
                  labelFor(role),
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// One vertical bar per month, stacked by role, with the total on top.
class _MonthBarChart extends StatelessWidget {
  final List<({String label, Map<String, int> counts})> rows;
  final List<String> roles;
  final Color Function(String role) colorFor;

  const _MonthBarChart({
    required this.rows,
    required this.roles,
    required this.colorFor,
  });

  static const double _chartHeight = 140;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    int total(Map<String, int> counts) =>
        roles.fold<int>(0, (sum, role) => sum + (counts[role] ?? 0));
    final highest = rows.fold<int>(0, (best, row) {
      final value = total(row.counts);
      return value > best ? value : best;
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (roles.length > 1) ...[
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: AppSpacing.xs,
            children: [
              for (final role in roles)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: colorFor(role),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(insightRoleLabel(role), style: textTheme.bodySmall),
                  ],
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        SizedBox(
          height: _chartHeight + 24,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final row in rows)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          '${total(row.counts)}',
                          style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                          child: SizedBox(
                            height: highest == 0 || total(row.counts) == 0
                                ? 3.0
                                : (total(row.counts) / highest * _chartHeight)
                                    .clamp(3.0, _chartHeight),
                            child: total(row.counts) == 0
                                ? Container(
                                    color: context.appColors.textSecondary
                                        .withValues(alpha: 0.2),
                                  )
                                : Column(
                                    children: [
                                      // Top to bottom, so the first role sits on the axis.
                                      for (final role in roles.reversed)
                                        if ((row.counts[role] ?? 0) > 0)
                                          Expanded(
                                            flex: row.counts[role]!,
                                            child: Container(color: colorFor(role)),
                                          ),
                                    ],
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        Divider(height: 1, color: context.appColors.textSecondary.withValues(alpha: 0.3)),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            for (final row in rows)
              Expanded(
                child: Text(
                  row.label,
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// One horizontal bar per area, split by role, longest = most users.
class _AreaBarChart extends StatelessWidget {
  final List<({String label, Map<String, int> counts})> rows;
  final Color Function(String role) colorFor;
  final void Function(String label) onTap;

  const _AreaBarChart({
    required this.rows,
    required this.colorFor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    int total(Map<String, int> counts) => counts.values.fold(0, (a, b) => a + b);
    final highest = rows.fold<int>(0, (best, row) {
      final value = total(row.counts);
      return value > best ? value : best;
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Legend
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.xs,
          children: [
            for (final role in insightRoles)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: colorFor(role),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(insightRoleLabel(role), style: textTheme.bodySmall),
                ],
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        for (final row in rows)
          InkWell(
            onTap: () => onTap(row.label),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  SizedBox(
                    width: 104,
                    child: Text(
                      row.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final rowTotal = total(row.counts);
                        final width = highest == 0
                            ? 0.0
                            : constraints.maxWidth * rowTotal / highest;
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: SizedBox(
                              width: width,
                              height: 14,
                              child: Row(
                                children: [
                                  for (final role in insightRoles)
                                    if ((row.counts[role] ?? 0) > 0)
                                      Expanded(
                                        flex: row.counts[role]!,
                                        child: Container(color: colorFor(role)),
                                      ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  SizedBox(
                    width: 32,
                    child: Text(
                      '${total(row.counts)}',
                      textAlign: TextAlign.right,
                      style: textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _UserRow extends StatelessWidget {
  final InsightUser user;
  final Color color;

  const _UserRow({required this.user, required this.color});

  String _joined(DateTime? time) {
    if (time == null) return '';
    final days = DateTime.now().difference(time).inDays;
    if (days <= 0) return 'Joined today';
    if (days == 1) return 'Joined yesterday';
    if (days < 30) return 'Joined $days days ago';
    final local = time.toLocal();
    return 'Joined ${local.day}/${local.month}/${local.year}';
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final secondary = context.appColors.textSecondary;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.15),
            child: Text(
              user.fullName.isEmpty ? '?' : user.fullName[0].toUpperCase(),
              style: textTheme.titleSmall?.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user.fullName.isEmpty ? user.email : user.fullName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  '${insightRoleLabel(user.role).replaceAll(RegExp(r's$'), '')}'
                  ' · ${user.areaLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodySmall?.copyWith(color: secondary),
                ),
                Text(
                  [
                    _joined(user.createdAt),
                    if (!user.isActive) 'Deactivated',
                    if (user.isActive && !user.isVerified) 'Waiting approval',
                  ].where((part) => part.isNotEmpty).join(' · '),
                  style: textTheme.labelSmall?.copyWith(color: secondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
