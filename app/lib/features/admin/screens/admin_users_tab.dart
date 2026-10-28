import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/list_filter_bar.dart';
import '../../../core/widgets/status_badge.dart';
import '../../../core/utils/route_args.dart';

/// Admin tab for approving shop owner and delivery agent accounts.
///
/// Backed by user-service through the gateway: `GET /users?is_verified=...`
/// lists accounts. Each card opens the applicant's profile and documents
/// (AdminApplicantScreen), and the Verify / Reject decision is made there,
/// after the admin has looked -- a Verify button on the card itself let an
/// account be approved unseen. Shop owners cannot create shops and delivery
/// agents cannot accept orders until an admin has verified them.
class AdminUsersTab extends StatefulWidget {
  const AdminUsersTab({super.key});

  @override
  State<AdminUsersTab> createState() => _AdminUsersTabState();
}

class _VerifiableUser {
  final String id;
  final String fullName;
  final String email;
  final String? phone;
  final String role;
  final bool isVerified;
  final bool isActive;
  final DateTime? createdAt;
  final String? rejectionReason;

  /// The row as the server sent it, handed to the review screen whole.
  final Map<String, dynamic> raw;

  const _VerifiableUser({
    required this.id,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.role,
    required this.isVerified,
    required this.isActive,
    required this.createdAt,
    required this.rejectionReason,
    required this.raw,
  });

  factory _VerifiableUser.fromJson(Map<String, dynamic> json) {
    return _VerifiableUser(
      id: json['id'].toString(),
      fullName: json['full_name']?.toString() ?? '',
      email: json['email']?.toString() ?? '',
      phone: json['phone']?.toString(),
      role: json['role']?.toString() ?? '',
      isVerified: json['is_verified'] == true,
      isActive: json['is_active'] != false,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      rejectionReason: json['rejection_reason']?.toString(),
      raw: json,
    );
  }

  bool get isShopOwner => role == 'shop_owner';

  String get roleLabel => isShopOwner ? 'Shop owner' : 'Delivery agent';
}

class _AdminUsersTabState extends State<AdminUsersTab> with AutomaticKeepAliveClientMixin {
  ViewState<List<_VerifiableUser>> _state = const ViewLoading();
  bool _showPending = true;
  String _role = 'all';
  String _query = '';

  /// Bumped on every load; a response whose id is no longer current (the admin
  /// switched filter meanwhile) is dropped instead of overwriting the list.
  int _requestId = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// [quiet] keeps the current list on screen while reloading (pull-to-refresh,
  /// after verifying someone) instead of flashing a full-screen spinner.
  Future<void> _load({bool quiet = false}) async {
    final requestId = ++_requestId;
    if (!quiet || _state is! ViewData) {
      setState(() => _state = const ViewLoading());
    }
    try {
      final response = await ApiClient.instance.get(
        '/users',
        query: {'is_verified': _showPending ? 'false' : 'true'},
      );
      // Accept a bare list or a paged `{items: [...]}` envelope.
      final rows = response is Map<String, dynamic> ? response['items'] : response;
      // Only shop owners and delivery agents ever need verification, and a
      // deactivated account cannot log in, so it is not worth approving.
      final items = (rows as List<dynamic>)
          .map((e) => _VerifiableUser.fromJson(e as Map<String, dynamic>))
          .where((u) => u.role == 'shop_owner' || u.role == 'delivery_agent')
          .where((u) => !_showPending || u.isActive)
          .toList();
      if (_showPending) {
        items.sort((a, b) {
          final da = a.createdAt ?? DateTime.now();
          final db = b.createdAt ?? DateTime.now();
          return da.compareTo(db);
        });
      }
      if (!mounted || requestId != _requestId) return;
      setState(() => _state = ViewData(items));
    } on ApiException catch (e) {
      if (!mounted || requestId != _requestId) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() => _state = const ViewError('Could not load users.'));
    }
  }

  void _setFilter(bool pending) {
    if (_showPending == pending) return;
    _showPending = pending;
    _load();
  }

  /// Opens the applicant's profile and documents. The decision is made
  /// there; this only reports it and refreshes the list.
  Future<void> _openReview(_VerifiableUser user) async {
    final outcome = await Navigator.pushNamed(
      context,
      AppRoutes.adminApplicant,
      arguments: AdminApplicantArgs(user.raw),
    );
    if (!mounted || outcome is! String) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(outcome)));
    await _load(quiet: true);
  }

  String _joined(DateTime time) =>
      '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final appColors = context.appColors;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('Pending'),
                selected: _showPending,
                onSelected: (_) => _setFilter(true),
              ),
              const SizedBox(width: AppSpacing.sm),
              ChoiceChip(
                label: const Text('Verified'),
                selected: !_showPending,
                onSelected: (_) => _setFilter(false),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => _load(quiet: true),
            child: AsyncStateView<List<_VerifiableUser>>(
              state: _state,
              onRetry: _load,
              isEmpty: (data) => data.isEmpty,
              emptyTitle: _showPending ? 'No pending accounts' : 'No verified accounts',
              emptyMessage: _showPending
                  ? 'New shop owner and delivery agent sign-ups waiting for approval appear here.'
                  : 'Verified shop owners and delivery agents appear here.',
              emptyIcon: Icons.verified_user_outlined,
              builder: (context, allItems) {
                final items = allItems.where((user) {
                  if (_role != 'all' && user.role != _role) return false;
                  return matchesQuery(_query, [user.fullName, user.email, user.phone]);
                }).toList();
                return Column(
                  children: [
                    ListFilterBar<String>(
                      searchHint: 'Search name, email or phone',
                      onSearchChanged: (value) => setState(() => _query = value),
                      options: [
                        FilterOption('all', 'All', count: allItems.length),
                        FilterOption('shop_owner', 'Shop owners',
                            count: allItems.where((u) => u.role == 'shop_owner').length),
                        FilterOption('delivery_agent', 'Delivery agents',
                            count: allItems.where((u) => u.role == 'delivery_agent').length),
                      ],
                      selected: _role,
                      onSelected: (value) => setState(() => _role = value),
                    ),
                    if (items.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(AppSpacing.xl),
                        child: Text('No accounts match this filter.'),
                      ),
                    Expanded(
                      child: ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
                  itemBuilder: (context, index) {
                    final user = items[index];
                    return AppCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                user.isShopOwner
                                    ? Icons.storefront_outlined
                                    : Icons.local_shipping_outlined,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(width: AppSpacing.md),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      user.fullName,
                                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                    ),
                                    Text(user.email, style: textTheme.bodySmall),
                                    if (user.phone != null && user.phone!.isNotEmpty)
                                      Text(user.phone!, style: textTheme.bodySmall),
                                  ],
                                ),
                              ),
                              StatusBadge(
                                label: user.roleLabel,
                                background: colorScheme.secondaryContainer,
                                foreground: colorScheme.onSecondaryContainer,
                              ),
                            ],
                          ),
                          if (user.createdAt != null) ...[
                            const SizedBox(height: AppSpacing.sm),
                            Row(
                              children: [
                                Text(
                                  'Applied ${_joined(user.createdAt!)}',
                                  style: textTheme.bodySmall?.copyWith(color: appColors.textSecondary),
                                ),
                                if (_showPending) ...[
                                  const Spacer(),
                                  _buildDelayBadge(context, user.createdAt!),
                                ],
                              ],
                            ),
                          ],
                          if (_showPending && user.rejectionReason != null && user.rejectionReason!.isNotEmpty) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              'Rejected: ${user.rejectionReason}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
                            ),
                          ],
                          const SizedBox(height: AppSpacing.md),
                          SizedBox(
                            width: double.infinity,
                            child: _showPending
                                ? FilledButton.icon(
                                    onPressed: () => _openReview(user),
                                    icon: const Icon(Icons.badge_outlined, size: 18),
                                    label: const Text('View profile & documents'),
                                  )
                                : OutlinedButton.icon(
                                    onPressed: () => _openReview(user),
                                    icon: const Icon(Icons.badge_outlined, size: 18),
                                    label: const Text('View profile & documents'),
                                  ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDelayBadge(BuildContext context, DateTime createdAt) {
    final diff = DateTime.now().difference(createdAt);
    final isDelayed = diff.inHours >= 24;
    final waitText = diff.inDays > 0
        ? '${diff.inDays}d waiting'
        : (diff.inHours > 0 ? '${diff.inHours}h waiting' : '${diff.inMinutes}m waiting');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isDelayed ? Colors.red.shade50 : Colors.amber.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDelayed ? Colors.red.shade400 : Colors.amber.shade400,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isDelayed ? Icons.warning_amber_rounded : Icons.schedule,
            size: 13,
            color: isDelayed ? Colors.red.shade700 : Colors.amber.shade800,
          ),
          const SizedBox(width: 4),
          Text(
            isDelayed ? 'Delayed: $waitText' : waitText,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isDelayed ? Colors.red.shade800 : Colors.amber.shade900,
            ),
          ),
        ],
      ),
    );
  }
}
