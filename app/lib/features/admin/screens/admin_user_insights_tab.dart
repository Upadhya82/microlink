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

  const InsightUser({
    required this.id,
    required this.fullName,
    required this.email,
    required this.role,
    required this.isActive,
    required this.createdAt,
    required this.district,
    required this.province,
  });

  factory InsightUser.fromJson(Map<String, dynamic> json) => InsightUser(
        id: json['id']?.toString() ?? '',
        fullName: json['full_name']?.toString() ?? '',
        email: json['email']?.toString() ?? '',
        role: json['role']?.toString() ?? '',
        isActive: json['is_active'] != false,
        createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
        district: json['district'] as String?,
        province: json['province'] as String?,
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

/// The users that match an area filter and a search. A null [province]
/// means island-wide (everyone, including users whose area is not known);
/// a null [district] means every district in the province.
List<InsightUser> filterInsightUsers(
  List<InsightUser> users, {
  String? province,
  String? district,
  String query = '',
}) {
  final text = query.trim().toLowerCase();
  return users.where((user) {
    if (province != null && user.province != province) return false;
    if (district != null && user.district != district) return false;
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
    );
    final roleCounts = countByRole(matching);

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
        DropdownButtonFormField<String?>(
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
            'shop locations, delivery agents\' live locations and customers\' '
            'last delivery addresses.',
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

/// Three vertical bars: customers, shop owners, delivery agents.
class _RoleBarChart extends StatelessWidget {
  final Map<String, int> counts;
  final Color Function(String role) colorFor;

  const _RoleBarChart({required this.counts, required this.colorFor});

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
              for (final role in insightRoles)
                Expanded(
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
            ],
          ),
        ),
        Divider(height: 1, color: context.appColors.textSecondary.withValues(alpha: 0.3)),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            for (final role in insightRoles)
              Expanded(
                child: Text(
                  insightRoleLabel(role),
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
