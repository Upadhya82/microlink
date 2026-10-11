import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';

/// Admin tab for approving shop owner and delivery agent accounts.
///
/// Backed by user-service through the gateway: `GET /users?is_verified=...`
/// lists accounts and `PATCH /users/{id}/verify` approves one. Shop owners
/// cannot create shops and delivery agents cannot accept orders until an
/// admin has verified them here.
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

  const _VerifiableUser({
    required this.id,
    required this.fullName,
    required this.email,
    required this.phone,
    required this.role,
    required this.isVerified,
    required this.isActive,
    required this.createdAt,
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
    );
  }

  bool get isShopOwner => role == 'shop_owner';

  String get roleLabel => isShopOwner ? 'Shop owner' : 'Delivery agent';
}

class _AdminUsersTabState extends State<AdminUsersTab> with AutomaticKeepAliveClientMixin {
  ViewState<List<_VerifiableUser>> _state = const ViewLoading();
  bool _showPending = true;
  String? _verifyingId;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get(
        '/users',
        query: {'is_verified': _showPending ? 'false' : 'true'},
      );
      // Only shop owners and delivery agents ever need verification.
      final items = (response as List<dynamic>)
          .map((e) => _VerifiableUser.fromJson(e as Map<String, dynamic>))
          .where((u) => u.role == 'shop_owner' || u.role == 'delivery_agent')
          .toList();
      if (!mounted) return;
      setState(() => _state = ViewData(items));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load users.'));
    }
  }

  void _setFilter(bool pending) {
    if (_showPending == pending) return;
    _showPending = pending;
    _load();
  }

  Future<void> _verify(_VerifiableUser user) async {
    setState(() => _verifyingId = user.id);
    try {
      await ApiClient.instance.patch('/users/${user.id}/verify');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${user.fullName} has been verified.')));
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not verify the user.')));
    } finally {
      if (mounted) setState(() => _verifyingId = null);
    }
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
            onRefresh: _load,
            child: AsyncStateView<List<_VerifiableUser>>(
              state: _state,
              onRetry: _load,
              isEmpty: (data) => data.isEmpty,
              emptyTitle: _showPending ? 'No pending accounts' : 'No verified accounts',
              emptyMessage: _showPending
                  ? 'New shop owner and delivery agent sign-ups waiting for approval appear here.'
                  : 'Verified shop owners and delivery agents appear here.',
              emptyIcon: Icons.verified_user_outlined,
              builder: (context, items) {
                return ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
                  itemBuilder: (context, index) {
                    final user = items[index];
                    final verifying = _verifyingId == user.id;
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
                            Text(
                              'Joined ${_joined(user.createdAt!)}',
                              style: textTheme.bodySmall?.copyWith(color: appColors.textSecondary),
                            ),
                          ],
                          if (!user.isVerified) ...[
                            const SizedBox(height: AppSpacing.md),
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                onPressed: verifying ? null : () => _verify(user),
                                icon: verifying
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.verified_outlined, size: 18),
                                label: const Text('Verify'),
                              ),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
