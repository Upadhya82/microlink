import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import 'stretch_header.dart';

/// Whether the destination below is the one on screen.
///
/// Destinations are built once and kept alive, so one whose data goes stale
/// while hidden -- the driver's map, after a job is accepted on the Jobs tab
/// -- reads this in `didChangeDependencies` to reload when it is shown again.
class RoleNavVisibility extends InheritedWidget {
  final bool isActive;

  const RoleNavVisibility({super.key, required this.isActive, required super.child});

  /// True outside a [RoleNavScaffold], e.g. a screen pushed as its own route.
  static bool isActiveIn(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RoleNavVisibility>()?.isActive ?? true;

  @override
  bool updateShouldNotify(RoleNavVisibility oldWidget) => oldWidget.isActive != isActive;
}

/// One destination in a [RoleNavScaffold]'s bottom bar.
class RoleNavItem {
  /// Shown in the bar under the icon. Keep it to one short word -- the bar
  /// gives each destination an equal slice of the width.
  final String label;

  final IconData icon;

  /// Drawn once the destination is selected. Material's convention is the
  /// filled twin of [icon]; it is what makes the selection readable without
  /// relying on color alone.
  final IconData selectedIcon;

  /// Built the first time this destination is opened, then kept alive, so
  /// switching back does not refetch.
  final WidgetBuilder builder;

  /// A count drawn on the icon, for destinations with work waiting (pending
  /// approvals, unclaimed orders). Null or 0 draws nothing.
  final int? badgeCount;

  /// Title for the stretching colored header above this destination. Null
  /// gives the destination the full screen with no header, which is what a
  /// map or a full-bleed screen wants.
  final String? headerTitle;

  /// A line of context under the header title -- usually a count or status.
  final String? headerSubtitle;

  /// Trailing actions for the header, such as a notification bell.
  final List<Widget> headerActions;

  const RoleNavItem({
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.builder,
    this.badgeCount,
    this.headerTitle,
    this.headerSubtitle,
    this.headerActions = const [],
  });
}

/// A bottom-bar slot that performs an action rather than opening a
/// destination. See [RoleNavScaffold.trailingAction].
class RoleNavAction {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const RoleNavAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });
}

/// A scaffold with a bottom navigation bar, for the screens a role lands on
/// after logging in.
///
/// The role dashboards used to stack their sections into a scrollable
/// [TabBar] at the top -- eight of them for an admin -- which hid most of the
/// app behind a horizontal scroll a lot of people never tried. A bottom bar
/// shows the top-level sections at a glance and puts them within thumb reach.
///
/// Destinations keep their state: each one is built on first visit and then
/// left in the tree, so going back to a list does not throw away its scroll
/// position or refetch it.
class RoleNavScaffold extends StatefulWidget {
  final List<RoleNavItem> items;

  /// Destinations beyond the bar's capacity, reached from an overflow sheet.
  /// A bottom bar stops being readable past five, so a role with more
  /// sections keeps the rest here rather than shrinking every label.
  final List<RoleNavItem> overflowItems;

  /// A final slot that runs a callback instead of switching destination --
  /// an account sheet, typically.
  ///
  /// It has to live in the bar rather than in an app-bar corner because the
  /// account sheet is the only way out of the app: it holds Log Out. A role
  /// whose destinations fill the bar would otherwise strand people in it.
  final RoleNavAction? trailingAction;

  /// Index selected on first build.
  final int initialIndex;

  const RoleNavScaffold({
    super.key,
    required this.items,
    this.overflowItems = const [],
    this.trailingAction,
    this.initialIndex = 0,
  });

  @override
  State<RoleNavScaffold> createState() => _RoleNavScaffoldState();
}

class _RoleNavScaffoldState extends State<RoleNavScaffold>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.medium,
    // Starts settled: the first destination is already in place, so it must
    // not fade in behind the user.
    value: 1,
  );

  late int _index = widget.initialIndex;

  /// Destinations built so far. A destination is added on first visit and
  /// never removed, which is what keeps its state.
  late final Set<int> _visited = {widget.initialIndex};

  List<RoleNavItem> get _all => [...widget.items, ...widget.overflowItems];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() {
      _index = index;
      _visited.add(index);
    });
    _controller.forward(from: 0);
  }

  Future<void> _showOverflow() async {
    final selected = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.overflowItems.length; i++)
                Builder(
                  builder: (_) {
                    final item = widget.overflowItems[i];
                    final itemIndex = widget.items.length + i;
                    final isSelected = itemIndex == _index;
                    return ListTile(
                      leading: Icon(
                        isSelected ? item.selectedIcon : item.icon,
                        color: isSelected ? colorScheme.primary : null,
                      ),
                      title: Text(item.label),
                      trailing: _Badge(count: item.badgeCount),
                      selected: isSelected,
                      onTap: () => Navigator.pop(sheetContext, itemIndex),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
    if (selected != null) _select(selected);
  }

  @override
  Widget build(BuildContext context) {
    final hasOverflow = widget.overflowItems.isNotEmpty;
    // The overflow button occupies the last slot, so a destination hidden
    // behind it has to show as selected on that button instead.
    final inOverflow = _index >= widget.items.length;
    final barIndex = inOverflow ? widget.items.length : _index;

    final fade = CurvedAnimation(parent: _controller, curve: AppMotion.enter);

    return Scaffold(
      body: FadeTransition(
        opacity: fade,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.015),
            end: Offset.zero,
          ).animate(fade),
          child: IndexedStack(
            index: _index,
            children: [
              for (var i = 0; i < _all.length; i++)
                // Not yet visited: an empty box holds the slot so the indices
                // still line up, and costs nothing until it is opened.
                _visited.contains(i)
                    ? RoleNavVisibility(
                        isActive: i == _index,
                        child: _destination(_all[i], i),
                      )
                    : const SizedBox.shrink(),
            ],
          ),
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: barIndex,
        onDestinationSelected: (index) {
          // The slots after the destinations are, in order, the overflow
          // button (when there is one) and the trailing action.
          final overflowSlot = hasOverflow ? widget.items.length : -1;
          final actionSlot =
              widget.items.length + (hasOverflow ? 1 : 0);
          if (index == overflowSlot) {
            _showOverflow();
          } else if (widget.trailingAction != null && index == actionSlot) {
            widget.trailingAction!.onTap();
          } else {
            _select(index);
          }
        },
        destinations: [
          for (final item in widget.items)
            NavigationDestination(
              icon: _Badged(count: item.badgeCount, child: Icon(item.icon)),
              selectedIcon: _Badged(
                count: item.badgeCount,
                child: Icon(item.selectedIcon),
              ),
              label: item.label,
            ),
          if (hasOverflow)
            NavigationDestination(
              icon: _Badged(
                count: _overflowBadgeTotal(),
                child: const Icon(Icons.more_horiz),
              ),
              selectedIcon: const Icon(Icons.more_horiz),
              label: 'More',
            ),
          if (widget.trailingAction != null)
            NavigationDestination(
              icon: Icon(widget.trailingAction!.icon),
              label: widget.trailingAction!.label,
            ),
        ],
      ),
    );
  }

  /// A destination's content, under its stretching header when it asked for
  /// one.
  ///
  /// The header is a sliver and the tab bodies are ordinary scrolling lists,
  /// so [NestedScrollView] is what joins them: the list drives the header's
  /// collapse without the tab itself having to know a header exists. That is
  /// the point -- the eight admin tabs keep their existing
  /// `RefreshIndicator > ListView` and gain the header for free.
  ///
  /// The [PageStorageKey] keeps each destination's scroll offset separate;
  /// without it the destinations share one and jump to each other's position.
  Widget _destination(RoleNavItem item, int index) {
    final body = Builder(builder: item.builder);
    if (item.headerTitle == null) return body;

    return NestedScrollView(
      key: PageStorageKey<String>('role-nav-$index'),
      // Bouncing physics gives the overscroll the header stretches into;
      // Android's default clamping physics has none, so without this the
      // header would simply stop at its height.
      physics: kAppStretchPhysics,
      headerSliverBuilder: (context, innerBoxIsScrolled) => [
        AppStretchHeader(
          title: item.headerTitle!,
          subtitle: item.headerSubtitle,
          icon: item.selectedIcon,
          actions: item.headerActions,
        ),
      ],
      body: body,
    );
  }

  /// Work waiting behind the overflow button, so it is not invisible just
  /// because its destination is one tap further away.
  int? _overflowBadgeTotal() {
    var total = 0;
    for (final item in widget.overflowItems) {
      total += item.badgeCount ?? 0;
    }
    return total == 0 ? null : total;
  }
}

/// Wraps an icon with a count badge when there is something waiting.
class _Badged extends StatelessWidget {
  final int? count;
  final Widget child;

  const _Badged({required this.count, required this.child});

  @override
  Widget build(BuildContext context) {
    if (count == null || count == 0) return child;
    return Badge.count(count: count!, child: child);
  }
}

/// The same count as a standalone chip, for list rows in the overflow sheet.
class _Badge extends StatelessWidget {
  final int? count;

  const _Badge({required this.count});

  @override
  Widget build(BuildContext context) {
    if (count == null || count == 0) return const SizedBox.shrink();
    return Badge.count(count: count!);
  }
}
