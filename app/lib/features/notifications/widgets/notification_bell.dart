import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../unread_count_controller.dart';

/// Bell icon with an unread-count badge, for an app bar or a list row.
///
/// Starts the shared [UnreadCountController] polling while mounted and
/// refreshes once more when the user comes back from the notifications
/// screen, so the badge reflects anything they just read.
class NotificationBell extends StatefulWidget {
  /// Shown in a bottom sheet / list context instead of an app bar.
  final bool asListTile;

  /// Run just before navigating -- used by the account sheet to close itself
  /// first, the same way its other rows do.
  final VoidCallback? onBeforeOpen;

  const NotificationBell({super.key, this.asListTile = false, this.onBeforeOpen});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  @override
  void initState() {
    super.initState();
    UnreadCountController.instance.start();
  }

  Future<void> _open() async {
    // Captured before onBeforeOpen runs: closing the sheet this bell lives in
    // would otherwise leave `context` unusable for navigating.
    final navigator = Navigator.of(context);
    widget.onBeforeOpen?.call();
    await navigator.pushNamed(AppRoutes.notifications);
    await UnreadCountController.instance.refresh();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: UnreadCountController.instance,
      builder: (context, _) {
        final unread = UnreadCountController.instance.unread;
        if (widget.asListTile) {
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.notifications_none_rounded),
            title: const Text('Notifications'),
            trailing: unread > 0 ? _CountPill(count: unread) : const Icon(Icons.chevron_right),
            onTap: _open,
          );
        }
        return IconButton(
          tooltip: unread > 0 ? 'Notifications ($unread unread)' : 'Notifications',
          onPressed: _open,
          icon: Badge(
            isLabelVisible: unread > 0,
            label: Text(unread > 99 ? '99+' : '$unread'),
            child: const Icon(Icons.notifications_none_rounded),
          ),
        );
      },
    );
  }
}

class _CountPill extends StatelessWidget {
  final int count;

  const _CountPill({required this.count});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: colorScheme.error,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: colorScheme.onError, fontWeight: FontWeight.w700),
      ),
    );
  }
}
