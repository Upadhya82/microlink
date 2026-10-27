import 'dart:async';
import 'package:flutter/material.dart';

import '../../../core/l10n/app_strings.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/models/app_notification.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/offline_cache.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/app_router.dart' show DeliveryTrackingArgs, ShopDetailArgs;
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/list_filter_bar.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../unread_count_controller.dart';
import '../../../core/widgets/branded_app_bar.dart';

/// The notification centre, available to every role (the use-case diagram's
/// "View Notifications"). Rows are produced backend-side by admin-service's
/// event subscriber, so this screen is read-only apart from marking rows read.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

/// Which filter chip a notification kind belongs under.
String notificationGroup(String kind) => switch (kind) {
      'order' => 'orders',
      'shop' || 'shop_alert' => 'shops',
      'crowdsource' || 'report' => 'community',
      _ => 'other',
    };

/// The notifications that match a filter ('all', 'unread', or a group from
/// [notificationGroup]) and a search.
List<AppNotification> filterNotifications(
  List<AppNotification> items, {
  String filter = 'all',
  String query = '',
}) {
  return items.where((n) {
    if (filter == 'unread' && n.isRead) return false;
    if (filter != 'all' && filter != 'unread' && notificationGroup(n.kind) != filter) {
      return false;
    }
    return matchesQuery(query, [n.title, n.body]);
  }).toList();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  String _filter = 'all';
  String _query = '';

  ViewState<List<AppNotification>> _state = const ViewLoading();
  bool _markingAll = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/notifications/me', query: {'limit': 100});
      final rows = (response as List)
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final items = rows.map(AppNotification.fromJson).toList();
      if (!mounted) return;
      setState(() => _state = ViewData(items));
      UnreadCountController.instance.setUnread(items.where((n) => !n.isRead).length);
      // Item 14: readable again next time there is no signal.
      unawaited(OfflineCache.save(OfflineCache.notificationsKey, rows));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (!await _showCached()) {
        if (mounted) setState(() => _state = ViewError(e.message));
      }
    } catch (_) {
      if (!mounted) return;
      if (!await _showCached()) {
        if (mounted) {
          setState(
            () => _state = const ViewError('Could not load your notifications.'),
          );
        }
      }
    }
  }

  /// Item 14: the last notifications this phone saw. True when there was
  /// something to show.
  Future<bool> _showCached() async {
    final cached = await OfflineCache.loadList(OfflineCache.notificationsKey);
    if (cached == null || cached.rows.isEmpty || !mounted) return false;
    setState(
      () => _state = ViewData(cached.rows.map(AppNotification.fromJson).toList()),
    );
    return true;
  }

  /// Marks one row read locally and on the server. The local update happens
  /// first so tapping feels instant; a failed call is not worth interrupting
  /// the navigation that triggered it, and the next load corrects the state.
  Future<void> _markRead(AppNotification notification) async {
    if (notification.isRead) return;
    final current = _state;
    if (current is ViewData<List<AppNotification>>) {
      setState(() {
        _state = ViewData(
          current.data
              .map((n) => n.id == notification.id ? n.copyWith(isRead: true) : n)
              .toList(),
        );
      });
    }
    UnreadCountController.instance.decrement();
    try {
      await ApiClient.instance.patch('/notifications/${notification.id}/read');
    } catch (_) {
      // Ignored on purpose -- see above.
    }
  }

  Future<void> _markAllRead() async {
    setState(() => _markingAll = true);
    try {
      await ApiClient.instance.post('/notifications/me/read-all');
      UnreadCountController.instance.setUnread(0);
      final current = _state;
      if (current is ViewData<List<AppNotification>> && mounted) {
        setState(() {
          _state = ViewData(current.data.map((n) => n.copyWith(isRead: true)).toList());
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not mark them read.')));
    } finally {
      if (mounted) setState(() => _markingAll = false);
    }
  }

  /// Maps the backend's `link.route` hint onto a real app route. Unknown
  /// routes (or rows with no hint) are simply not tappable.
  void _openTarget(AppNotification notification) {
    final route = notification.linkRoute;
    final id = notification.linkId;
    switch (route) {
      case 'shop':
        if (id != null) {
          Navigator.pushNamed(context, AppRoutes.shopDetail, arguments: ShopDetailArgs(id));
        }
      case 'order':
        if (id != null) {
          Navigator.pushNamed(
            context,
            AppRoutes.deliveryTracking,
            arguments: DeliveryTrackingArgs(id),
          );
        } else {
          Navigator.pushNamed(context, AppRoutes.myOrders);
        }
      case 'orders':
        Navigator.pushNamed(context, AppRoutes.myOrders);
      case 'favorites':
        Navigator.pushNamed(context, AppRoutes.myFavorites);
      case 'driver_home':
        Navigator.pushNamed(context, AppRoutes.driverHome);
      case 'admin':
        Navigator.pushNamed(context, AppRoutes.adminDashboard);
      case 'shop_owner':
        // Low-stock and sold-out alerts: the owner's Products tab is where
        // they restock and unhide.
        Navigator.pushNamed(context, AppRoutes.shopOwnerDashboard);
      case 'home':
        // "New shop near you": it is on Home, under User Suggestions.
        Navigator.popUntil(context, (route) => route.isFirst);
      case 'confirm_shops':
      case 'confirmShops':
        Navigator.pushNamed(context, AppRoutes.confirmShops);
      case 'login':
        // An account-verified notification: the user needs a fresh token, so
        // there is nowhere useful to send them from here.
        break;
      default:
        break;
    }
  }

  bool _isTappable(AppNotification notification) {
    final route = notification.linkRoute;
    return route != null && route != 'login';
  }

  (IconData, Color) _kindStyle(BuildContext context, String kind) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    return switch (kind) {
      'order' => (Icons.receipt_long_outlined, colorScheme.primary),
      'delivery_request' => (Icons.two_wheeler_outlined, colorScheme.primary),
      'shop_alert' => (Icons.campaign_outlined, colors.warning),
      'review' => (Icons.star_outline_rounded, colors.warning),
      'report' => (Icons.report_gmailerrorred_outlined, colorScheme.error),
      'account' => (Icons.verified_user_outlined, colors.success),
      _ => (Icons.notifications_none_rounded, colors.textSecondary),
    };
  }

  String _relativeTime(DateTime time) {
    final diff = DateTime.now().difference(time);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final hasUnread =
        state is ViewData<List<AppNotification>> && state.data.any((n) => !n.isRead);

    return Scaffold(
      appBar: BrandedAppBar(
        title: Text(tr('notifications.title')),
        actions: [
          if (hasUnread)
            TextButton(
              onPressed: _markingAll ? null : _markAllRead,
              child: Text(tr('notifications.mark_all_read')),
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: AsyncStateView<List<AppNotification>>(
          state: _state,
          onRetry: _load,
          isEmpty: (data) => data.isEmpty,
          emptyTitle: tr('notifications.empty_title'),
          emptyMessage:
              'Updates about your orders, shops and reports will show up here.',
          emptyIcon: Icons.notifications_none_rounded,
          loadingSkeleton: const SkeletonList(),
          builder: (context, all) {
            final items = filterNotifications(all, filter: _filter, query: _query);
            final groups = countBy(all, (AppNotification n) => notificationGroup(n.kind));
            return Column(
              children: [
                ListFilterBar<String>(
                  searchHint: 'Search notifications',
                  onSearchChanged: (value) => setState(() => _query = value),
                  selected: _filter,
                  onSelected: (value) => setState(() => _filter = value),
                  options: [
                    FilterOption('all', 'All', count: all.length),
                    FilterOption('unread', 'Unread', count: all.where((n) => !n.isRead).length),
                    if ((groups['orders'] ?? 0) > 0)
                      FilterOption('orders', 'Orders', count: groups['orders']),
                    if ((groups['shops'] ?? 0) > 0)
                      FilterOption('shops', 'Shops', count: groups['shops']),
                    if ((groups['community'] ?? 0) > 0)
                      FilterOption('community', 'Community', count: groups['community']),
                    if ((groups['other'] ?? 0) > 0)
                      FilterOption('other', 'Account & other', count: groups['other']),
                  ],
                ),
                Expanded(
                  child: items.isEmpty
                      ? ListView(
                          padding: const EdgeInsets.all(AppSpacing.xl),
                          children: const [
                            Center(child: Text('No notifications match this filter.')),
                          ],
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          itemCount: items.length,
                          separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
                          itemBuilder: (context, index) => _NotificationTile(
                            notification: items[index],
                            style: _kindStyle(context, items[index].kind),
                            timeLabel: _relativeTime(items[index].createdAt),
                            onTap: () {
                              final notification = items[index];
                              _markRead(notification);
                              if (_isTappable(notification)) _openTarget(notification);
                            },
                          ),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification notification;
  final (IconData, Color) style;
  final String timeLabel;
  final VoidCallback onTap;

  const _NotificationTile({
    required this.notification,
    required this.style,
    required this.timeLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;
    final (icon, tint) = style;
    final unread = !notification.isRead;

    return AppCard(
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.sm),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 20, color: tint),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        notification.title,
                        style: textTheme.titleSmall?.copyWith(
                          // Unread rows read as bold with a dot; read rows go
                          // quiet rather than disappearing.
                          fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                          color: unread ? null : colors.textSecondary,
                        ),
                      ),
                    ),
                    if (unread)
                      Container(
                        margin: const EdgeInsets.only(left: AppSpacing.sm),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
                if (notification.body.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    notification.body,
                    style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
                  ),
                ],
                const SizedBox(height: AppSpacing.xs),
                Text(
                  timeLabel,
                  style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
