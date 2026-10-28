import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/media_url.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../../../core/widgets/stagger_in.dart';
import '../../../core/widgets/branded_app_bar.dart';
import '../../crowdsourcing/widgets/suggestion_comments.dart';
import '../widgets/admin_document_row.dart';

/// The admin's moderation desk: everything waiting on a decision, plus the
/// live system monitor.
///
/// One screen with tabs rather than four entries on the dashboard, because
/// these are the same job done against different queues -- the admin works
/// through them in one sitting.
class AdminReviewScreen extends StatelessWidget {
  const AdminReviewScreen({super.key, this.initialTab = 0});

  /// Index of the tab to open on. Tab 1 is the shop suggestions queue,
  /// which a "new shop suggested" notification opens straight onto.
  static const int suggestionsTab = 1;
  final int initialTab;

  /// Height of one tab (icon + label). Flutter's default for a tab with both
  /// an icon and text is 72, which is taller than the space the header gave
  /// it, so the tab strip spilled upward over the title. Setting it here and
  /// sizing the header from it keeps the two in step.
  static const double _tabHeight = 50;

  /// Everything the tab strip takes up: the tab, the strip's 4px padding
  /// top and bottom, its 1px border top and bottom, and the 8px gap below.
  static const double _tabStripHeight =
      _tabHeight + (4 * 2) + (1 * 2) + AppSpacing.sm;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 5,
      initialIndex: initialTab.clamp(0, 4),
      child: Scaffold(
        appBar: BrandedAppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
                ),
                child: const Icon(
                  Icons.fact_check_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Review & Monitor',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                      letterSpacing: 0.2,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    'Admin Moderation Desk',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ],
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(_tabStripHeight),
            child: Container(
              margin: const EdgeInsets.fromLTRB(AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
              child: TabBar(
                isScrollable: false,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [
                    BoxShadow(
                      color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                labelColor: Colors.white,
                unselectedLabelColor: Theme.of(context).colorScheme.onSurface,
                labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                dividerColor: Colors.transparent,
                // The default 16px side padding leaves too little room for
                // "Corrections" and "Applicants" when five tabs share a phone
                // screen, so their labels got cut off.
                labelPadding: const EdgeInsets.symmetric(horizontal: 4),
                tabs: const [
                  Tab(
                    icon: Icon(Icons.storefront_outlined, size: 18),
                    text: 'Shops',
                    iconMargin: EdgeInsets.only(bottom: 2),
                    height: _tabHeight,
                  ),
                  Tab(
                    icon: Icon(Icons.add_location_alt_outlined, size: 18),
                    text: 'Suggestions',
                    iconMargin: EdgeInsets.only(bottom: 2),
                    height: _tabHeight,
                  ),
                  Tab(
                    icon: Icon(Icons.people_outline, size: 18),
                    text: 'Applicants',
                    iconMargin: EdgeInsets.only(bottom: 2),
                    height: _tabHeight,
                  ),
                  Tab(
                    icon: Icon(Icons.edit_note_outlined, size: 18),
                    text: 'Corrections',
                    iconMargin: EdgeInsets.only(bottom: 2),
                    height: _tabHeight,
                  ),
                  Tab(
                    icon: Icon(Icons.speed_outlined, size: 18),
                    text: 'Monitor',
                    iconMargin: EdgeInsets.only(bottom: 2),
                    height: _tabHeight,
                  ),
                ],
              ),
            ),
          ),
        ),
        body: const TabBarView(
          children: [
            _ShopQueueTab(),
            _SuggestionQueueTab(),
            _ApplicantQueueTab(),
            _CorrectionQueueTab(),
            _MonitorTab(),
          ],
        ),
      ),
    );
  }
}

/// Shared loading/error plumbing for the four tabs.
abstract class _QueueTabState<T extends StatefulWidget> extends State<T> {
  ViewState<List<Map<String, dynamic>>> state = const ViewLoading();

  String get endpoint;
  String get emptyTitle;
  String get emptyMessage;

  /// Term typed into the search box, applied by the queues that support it.
  String searchTerm = '';

  /// Whether this queue offers a search box at all.
  bool get searchable => false;
  String get searchHint => 'Search by name';

  Timer? _searchDebounce;

  /// Re-queries after a short pause, so a five-letter name is one request
  /// rather than five.
  void onSearchChanged(String value) {
    searchTerm = value.trim();
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) load();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  /// [quiet] refreshes in the background: the list stays on screen (no
  /// skeleton flash) and a failed refresh keeps the last good data, so a
  /// live-updating queue never blanks out on one dropped request.
  Future<void> load({bool quiet = false}) async {
    if (!quiet) setState(() => state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get(endpoint);
      final rows = (response as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (!mounted) return;
      setState(() => state = ViewData(rows));
    } on ApiException catch (e) {
      if (!mounted || quiet) return;
      setState(() => state = ViewError(e.message));
    } catch (_) {
      if (!mounted || quiet) return;
      setState(() => state = const ViewError('Could not load this queue.'));
    }
  }

  void toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget buildList(Widget Function(BuildContext, Map<String, dynamic>, int) itemBuilder) {
    final list = _buildListBody(itemBuilder);
    if (!searchable) return list;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
          child: TextField(
            onChanged: onSearchChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: searchHint,
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.input),
              ),
            ),
          ),
        ),
        Expanded(child: list),
      ],
    );
  }

  Widget _buildListBody(
      Widget Function(BuildContext, Map<String, dynamic>, int) itemBuilder) {
    return RefreshIndicator(
      onRefresh: load,
      child: AsyncStateView<List<Map<String, dynamic>>>(
        state: state,
        onRetry: load,
        isEmpty: (data) => data.isEmpty,
        emptyTitle: emptyTitle,
        emptyMessage: emptyMessage,
        emptyIcon: Icons.inbox_outlined,
        loadingSkeleton: const SkeletonList(itemCount: 4),
        builder: (context, rows) => ListView.builder(
          padding: const EdgeInsets.all(AppSpacing.lg),
          itemCount: rows.length,
          itemBuilder: (context, index) => StaggerIn(
            index: index,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: itemBuilder(context, rows[index], index),
            ),
          ),
        ),
      ),
    );
  }
}

// --------------------------------------------------------------- shops

class _ShopQueueTab extends StatefulWidget {
  const _ShopQueueTab();

  @override
  State<_ShopQueueTab> createState() => _ShopQueueTabState();
}

class _ShopQueueTabState extends _QueueTabState<_ShopQueueTab> {
  @override
  String get endpoint => '/shops?unverified_only=true&limit=100';
  @override
  String get emptyTitle => 'Nothing waiting';
  @override
  String get emptyMessage => 'Every registered shop has been reviewed.';

  Future<void> _verify(Map<String, dynamic> shop, bool approve, {String? reason}) async {
    try {
      await ApiClient.instance.patch(
        '/shops/${shop['id']}/verify',
        body: {'is_verified': approve, if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim()},
      );
      toast(approve ? '${shop['name']} verified successfully' : '${shop['name']} marked as Pending (Under Review)');
      await load();
    } on ApiException catch (e) {
      toast(e.message);
    }
  }

  Future<void> _promptLeavePending(Map<String, dynamic> shop) async {
    final listed = (shop['listable_product_count'] as num?)?.toInt() ?? 0;
    final defaultReason = listed < AppConstants.minProductsToVerify
        ? 'Awaiting owner to list at least 5 products (currently has $listed)'
        : 'Pending administrator review and verification';
    final controller = TextEditingController(text: defaultReason);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Leave Shop Pending'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Set the pending status note for "${shop['name']}":',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              maxLines: 2,
              maxLength: 150,
              decoration: const InputDecoration(
                labelText: 'Status Reason',
                hintText: 'e.g. Waiting for products, awaiting call...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save Pending Status'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _verify(shop, false, reason: controller.text.trim());
    }
  }

  Future<void> _rejectShop(Map<String, dynamic> shop) async {
    final controller = TextEditingController(text: 'Registration rejected by administrator');
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reject Shop Registration'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Confirm rejection of "${shop['name']}". It will be removed from the pending review queue.',
              style: Theme.of(ctx).textTheme.bodyMedium,
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: controller,
              maxLines: 2,
              maxLength: 200,
              decoration: const InputDecoration(
                labelText: 'Rejection Reason',
                hintText: 'e.g. Invalid documents, duplicate',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Reject Shop'),
          ),
        ],
      ),
    );
    if (reason == null) return;
    try {
      await ApiClient.instance.patch(
        '/shops/${shop['id']}/status',
        body: {'status': 'closed', 'reason': reason},
      );
      toast('Rejected ${shop['name']}');
      await load();
    } on ApiException catch (e) {
      toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildList((context, shop, _) {
      final colors = context.appColors;
      final listed = (shop['listable_product_count'] as num?)?.toInt() ?? 0;
      final canVerify = listed >= AppConstants.minProductsToVerify;
      final statusReason = shop['status_reason'] as String?;
      final hasLeftPending = statusReason != null && statusReason.trim().isNotEmpty;
      final statusBadge = Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: hasLeftPending
              ? Colors.amber.shade50
              : (canVerify ? Colors.blue.shade50 : Colors.orange.shade50),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: hasLeftPending
                ? Colors.amber.shade400
                : (canVerify ? Colors.blue.shade300 : Colors.orange.shade300),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasLeftPending
                  ? Icons.schedule_outlined
                  : (canVerify ? Icons.check_circle_outline : Icons.pending_outlined),
              size: 13,
              color: hasLeftPending
                  ? Colors.amber.shade900
                  : (canVerify ? Colors.blue.shade800 : Colors.orange.shade900),
            ),
            const SizedBox(width: 4),
            Text(
              hasLeftPending
                  ? 'Status: Left Pending'
                  : (canVerify ? 'Ready to Verify' : 'Status: Needs Products'),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: hasLeftPending
                  ? Colors.amber.shade900
                  : (canVerify ? Colors.blue.shade900 : Colors.orange.shade900),
              ),
            ),
          ],
        ),
      );
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              shop['name'] as String? ?? 'Unnamed shop',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '${shop['category'] ?? ''} · ${shop['address'] ?? ''}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.textSecondary),
            ),
            if ((shop['phone'] as String?)?.isNotEmpty ?? false)
              Text(
                shop['phone'] as String,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: colors.textSecondary),
              ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                statusBadge,
              ],
            ),
            if (hasLeftPending) ...[
              const SizedBox(height: AppSpacing.xs),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.amber.shade200),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 14, color: Colors.amber.shade800),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        'Note: $statusReason',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: Colors.amber.shade900,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(
                  listed >= AppConstants.minProductsToVerify
                      ? Icons.check_circle_outline
                      : Icons.inventory_2_outlined,
                  size: 16,
                  color: canVerify ? colors.success : colors.warning,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  '$listed of ${AppConstants.minProductsToVerify} products listed',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: canVerify ? colors.success : colors.warning,
                      ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    child: const Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.schedule, size: 16), SizedBox(width: 4), Text('Leave pending')]),
                    onPressed: () => _promptLeavePending(shop),
                  ),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  flex: 0,
                  child: IconButton.outlined(
                    tooltip: 'Reject shop registration',
                    onPressed: () => _rejectShop(shop),
                    icon: Icon(Icons.close_rounded, size: 18, color: Colors.red.shade700),
                    style: IconButton.styleFrom(
                      side: BorderSide(color: Colors.red.shade300),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Tooltip(
                    message: canVerify
                        ? ''
                        : 'This shop needs at least '
                            '${AppConstants.minProductsToVerify} products with '
                            '${AppConstants.minListableStock} or more in stock.',
                    child: FilledButton.icon(
                      onPressed: canVerify ? () => _verify(shop, true) : null,
                      icon: const Icon(Icons.verified_rounded, size: 18),
                      label: const Text('Verify'),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    });
  }
}

// --------------------------------------------------------- suggestions

class _SuggestionQueueTab extends StatefulWidget {
  const _SuggestionQueueTab();

  @override
  State<_SuggestionQueueTab> createState() => _SuggestionQueueTabState();
}

class _SuggestionQueueTabState extends _QueueTabState<_SuggestionQueueTab> {
  @override
  String get endpoint => '/crowdsource/shop-reports';
  @override
  String get emptyTitle => 'No shop suggestions waiting';
  @override
  String get emptyMessage => 'New shops suggested by community users appear here for review.';

  /// How often the queue re-reads itself while this tab is on screen, so the
  /// neighbours' confirmations show up live without pulling to refresh.
  /// (TabBarView disposes a tab that is scrolled away, which stops it.)
  static const Duration _liveInterval = Duration(seconds: 5);
  Timer? _live;

  /// Suggestions whose phone-number request is on its way, so the button
  /// cannot be pressed twice and send the neighbours two messages.
  final Set<String> _asking = {};

  @override
  void initState() {
    super.initState();
    _live = Timer.periodic(_liveInterval, (_) {
      if (mounted) load(quiet: true);
    });
  }

  @override
  void dispose() {
    _live?.cancel();
    super.dispose();
  }

  /// Opens the phone's dialler on the shop's number.
  Future<void> _callShop(String phone) async {
    final digits = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    final uri = Uri(scheme: 'tel', path: digits);
    try {
      final opened = await launchUrl(uri);
      if (!opened) toast('Could not open the dialler. Number: $phone');
    } catch (_) {
      toast('Could not open the dialler. Number: $phone');
    }
  }

  Future<void> _setStatusSuggestion(Map<String, dynamic> item, String status) async {
    String? reason;
    if (status == 'rejected') {
      final controller = TextEditingController();
      reason = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Reason for Rejection'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Specify why suggestion for "${item['shop_name']}" is being rejected. The submitting user will be notified.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 2,
                maxLength: 200,
                decoration: const InputDecoration(
                  hintText: 'e.g. Inaccurate location, duplicate',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
              onPressed: () {
                final text = controller.text.trim();
                if (text.isEmpty) return;
                Navigator.pop(ctx, text);
              },
              child: const Text('Reject'),
            ),
          ],
        ),
      );
      if (reason == null) return;
    }
    try {
      await ApiClient.instance.patch(
        '/crowdsource/shop-reports/${item['id']}/status',
        body: {'status': status, if (reason != null && reason.isNotEmpty) 'reason': reason},
      );
      toast(status == 'approved' ? 'Shop suggestion approved' : 'Shop suggestion rejected');
      await load();
    } on ApiException catch (e) {
      toast(e.message);
    }
  }

  Future<void> _requestSuggestionPhone(Map<String, dynamic> item) async {
    final id = item['id'].toString();
    if (_asking.contains(id)) return;
    setState(() => _asking.add(id));
    try {
      final res = await ApiClient.instance.post(
        '/crowdsource/shop-reports/$id/request-phone',
      ) as Map<String, dynamic>;
      toast(res['message']?.toString() ?? 'Asked nearby users for the number');
    } on ApiException catch (e) {
      toast(e.message);
    } catch (_) {
      toast('Could not send the request');
    } finally {
      if (mounted) setState(() => _asking.remove(id));
    }
  }

  /// Green "Call" when the reporter gave a number; otherwise a plain grey
  /// button that asks the people near the shop for it.
  Widget _phoneAction(Map<String, dynamic> report, String status) {
    final phone = (report['phone'] as String?)?.trim() ?? '';
    if (phone.isNotEmpty) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.green.shade600,
            foregroundColor: Colors.white,
          ),
          onPressed: () => _callShop(phone),
          icon: const Icon(Icons.call_rounded, size: 18),
          label: Text('Call shop · $phone'),
        ),
      );
    }
    final id = report['id'].toString();
    final asking = _asking.contains(id);
    return SizedBox(
      width: double.infinity,
      child: Tooltip(
        message: 'No phone number was given. '
            'Tap to ask the people near this shop for it.',
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.grey.shade700,
            side: BorderSide(color: Colors.grey.shade400),
          ),
          onPressed: status == 'pending' && !asking
              ? () => _requestSuggestionPhone(report)
              : null,
          icon: asking
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.phone_disabled_outlined, size: 18),
          label: Text(
            asking ? 'Asking nearby users…' : 'Call · no number – ask nearby users',
          ),
        ),
      ),
    );
  }

  /// Everything the person who suggested the shop filled in.
  Widget _suggestionDetails(BuildContext context, Map<String, dynamic> report) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    String two(int n) => n.toString().padLeft(2, '0');
    String? when(Object? raw) {
      final d = DateTime.tryParse(raw?.toString() ?? '')?.toLocal();
      if (d == null) return null;
      return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
    }

    final open = report['opening_time']?.toString() ?? '';
    final close = report['closing_time']?.toString() ?? '';
    final lat = (report['latitude'] as num?)?.toDouble();
    final lng = (report['longitude'] as num?)?.toDouble();
    final phone = (report['phone'] as String?)?.trim() ?? '';
    final description = report['description']?.toString().trim() ?? '';
    final photo = mediaUrl(report['photo_path']?.toString() ??
        ((report['has_photo'] as bool? ?? false)
            ? '/crowdsource/shop-reports/${report['id']}/photo'
            : null));

    Widget line(IconData icon, String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 14, color: colors.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$label: ',
                        style: textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(text: value, style: textTheme.bodySmall),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (photo != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              photo,
              height: 150,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        line(Icons.person_outline, 'Suggested by',
            report['reporter_name']?.toString() ?? 'MicroLink user'),
        if (when(report['created_at']) != null)
          line(Icons.schedule_outlined, 'Submitted', when(report['created_at'])!),
        line(Icons.call_outlined, 'Phone', phone.isEmpty ? 'Not given' : phone),
        line(Icons.access_time, 'Hours',
            open.isNotEmpty && close.isNotEmpty ? '$open – $close' : 'Not given'),
        if (lat != null && lng != null)
          line(Icons.place_outlined, 'Location',
              '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}'),
        line(Icons.notes_outlined, 'Description',
            description.isEmpty ? 'Not given' : description),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return buildList((context, report, _) {
      final colors = context.appColors;
      final status = (report['status'] as String? ?? 'pending').toLowerCase();
      final ratio = (report['confirmed_ratio'] as num?)?.toDouble() ?? 0.0;
      final responses = (report['responses'] as num?)?.toInt() ?? 0;
      final confirmations = (report['confirmations'] as num?)?.toInt() ?? 0;
      final isHighVerification = ratio >= 0.75 && responses > 0;
      final comments = (report['comments'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
      // Who said each comment, when the server sends names.
      final commentDetail = (report['comments_detail'] as List<dynamic>? ?? const [])
          .whereType<Map>()
          .toList();

      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        report['shop_name'] as String? ?? 'Unnamed shop',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        '${report['category'] ?? ''} · ${report['address'] ?? ''}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                      ),
                      // The phone number belongs to a MicroLink account, so
                      // this skipped the neighbour check and can be decided now.
                      if (report['fast_track'] == true) ...[
                        const SizedBox(height: AppSpacing.xs),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '📞 Phone belongs to MicroLink user '
                            '${report['phone_user_name'] ?? ''} · ready to review',
                            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                                ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: status == 'approved'
                        ? Colors.green.shade50
                        : (status == 'rejected' ? Colors.red.shade50 : Colors.amber.shade50),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: status == 'approved'
                          ? Colors.green.shade300
                          : (status == 'rejected' ? Colors.red.shade300 : Colors.amber.shade400),
                    ),
                  ),
                  child: Text(
                    status[0].toUpperCase() + status.substring(1),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: status == 'approved'
                          ? Colors.green.shade900
                          : (status == 'rejected' ? Colors.red.shade900 : Colors.amber.shade900),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            _suggestionDetails(context, report),
            if (status != 'rejected') ...[
              const SizedBox(height: AppSpacing.sm),
              _phoneAction(report, status),
            ],
            const SizedBox(height: AppSpacing.sm),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: isHighVerification
                    ? Colors.green.shade50
                    : (responses > 0 ? Colors.red.shade50 : Colors.grey.shade100),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isHighVerification
                      ? Colors.green.shade300
                      : (responses > 0 ? Colors.red.shade300 : Colors.grey.shade300),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isHighVerification ? Icons.verified : (responses > 0 ? Icons.error_outline : Icons.info_outline),
                    size: 16,
                    color: isHighVerification ? Colors.green.shade800 : (responses > 0 ? Colors.red.shade800 : Colors.grey.shade700),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      responses > 0
                          ? '${(ratio * 100).toInt()}% Confirmed by neighbours ($confirmations of $responses votes)'
                          : 'Awaiting neighbour confirmations (0 votes yet)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isHighVerification ? Colors.green.shade900 : (responses > 0 ? Colors.red.shade900 : Colors.grey.shade800),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (status == 'pending' && report['fast_track'] != true) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: Colors.green.shade600,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Live – neighbours\' answers update automatically',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.textSecondary,
                        ),
                  ),
                ],
              ),
            ],
            if (comments.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text('Neighbour Comments:', style: Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 3),
              for (var i = 0; i < comments.length; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.chat_bubble_outline, size: 12, color: Colors.grey),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              if (i < commentDetail.length &&
                                  commentDetail[i]['author_name'] != null)
                                TextSpan(
                                  text: '${commentDetail[i]['author_name']}: ',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              TextSpan(
                                text: '"${comments[i]}"',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
                              ),
                              if (i < commentDetail.length &&
                                  ((commentDetail[i]['reply_count'] as num?) ?? 0) > 0)
                                TextSpan(
                                  text: '  · ${commentDetail[i]['reply_count']} repl'
                                      '${commentDetail[i]['reply_count'] == 1 ? 'y' : 'ies'}',
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => showSuggestionComments(
                  context,
                  reportId: report['id'].toString(),
                  shopName: report['shop_name']?.toString() ?? 'Suggested shop',
                ),
                icon: const Icon(Icons.forum_outlined, size: 16),
                label: const Text('View conversation'),
              ),
            ],
            if (status == 'pending') ...[
              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _setStatusSuggestion(report, 'rejected'),
                      icon: Icon(Icons.close, size: 16, color: Colors.red.shade700),
                      label: Text('Reject', style: TextStyle(color: Colors.red.shade700)),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => _setStatusSuggestion(report, 'approved'),
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Approve'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
    });
  }
}

// ---------------------------------------------------------- applicants

class _ApplicantQueueTab extends StatefulWidget {
  const _ApplicantQueueTab();

  @override
  State<_ApplicantQueueTab> createState() => _ApplicantQueueTabState();
}

class _ApplicantQueueTabState extends _QueueTabState<_ApplicantQueueTab> {
  // Documents are fetched per applicant, only when their card is expanded --
  // loading every file list up front would make the queue crawl.
  final Map<String, List<Map<String, dynamic>>> _documents = {};

  @override
  bool get searchable => true;
  @override
  String get searchHint => 'Search applicants by name or e-mail';
  @override
  String get endpoint => '/users?is_verified=false&limit=100'
      '${searchTerm.isEmpty ? '' : '&q=${Uri.encodeQueryComponent(searchTerm)}'}';
  @override
  String get emptyTitle => 'No applications waiting';
  @override
  String get emptyMessage => 'Shop owners and agents awaiting approval appear here.';

  Future<void> _loadDocuments(String userId) async {
    if (_documents.containsKey(userId)) return;
    try {
      final response = await ApiClient.instance.get('/users/$userId/documents');
      final rows = (response as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (!mounted) return;
      setState(() => _documents[userId] = rows);
    } catch (_) {
      if (!mounted) return;
      setState(() => _documents[userId] = const []);
    }
  }

  Future<void> _decide(Map<String, dynamic> user, bool approve) async {
    try {
      if (approve) {
        await ApiClient.instance.patch('/users/${user['id']}/verify');
      } else {
        final reason = await _askReason();
        if (reason == null) return;
        await ApiClient.instance.patch(
          '/users/${user['id']}/reject',
          body: {'reason': reason},
        );
      }
      toast(approve ? 'Approved ${user['full_name']}' : 'Rejected ${user['full_name']}');
      await load();
    } on ApiException catch (e) {
      toast(e.message);
    }
  }

  Future<String?> _askReason() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reason for rejection'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 300,
          decoration: const InputDecoration(
            hintText: 'The applicant sees this, so be specific.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(dialogContext, text);
            },
            child: const Text('Reject'),
          ),
        ],
      ),
    );
  }

  @override
  Future<void> load({bool quiet = false}) async {
    if (!quiet) setState(() => state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get(endpoint);
      final rows = (response as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      // FIFO: prioritize oldest / delayed applications first
      rows.sort((a, b) {
        final da = DateTime.tryParse(a['created_at']?.toString() ?? '') ?? DateTime.now();
        final db = DateTime.tryParse(b['created_at']?.toString() ?? '') ?? DateTime.now();
        return da.compareTo(db);
      });
      if (!mounted) return;
      setState(() => state = ViewData(rows));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => state = const ViewError('Could not load this queue.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildList((context, user, _) {
      final colors = context.appColors;
      final userId = user['id'] as String;
      final documents = _documents[userId];

      final createdAt = DateTime.tryParse(user['created_at']?.toString() ?? '');
      Widget? delayBadge;
      if (createdAt != null) {
        final diff = DateTime.now().difference(createdAt);
        final isDelayed = diff.inHours >= 24;
        final waitString = diff.inDays > 0
            ? '${diff.inDays}d waiting'
            : (diff.inHours > 0 ? '${diff.inHours}h waiting' : '${diff.inMinutes}m waiting');
        delayBadge = Container(
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
                isDelayed ? 'Delayed: $waitString' : waitString,
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

      return AppCard(
        padding: EdgeInsets.zero,
        child: ExpansionTile(
          shape: const Border(),
          onExpansionChanged: (open) {
            if (open) _loadDocuments(userId);
          },
          title: Row(
            children: [
              Expanded(
                child: Text(
                  user['full_name'] as String? ?? 'Unnamed',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              ?delayBadge,
            ],
          ),
          subtitle: Text(
            '${user['role'] ?? ''} · ${user['email'] ?? ''}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colors.textSecondary),
          ),
          childrenPadding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            0,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          children: [
            if (documents == null)
              const Padding(
                padding: EdgeInsets.all(AppSpacing.md),
                child: LinearProgressIndicator(),
              )
            else if (documents.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Text(
                  'This applicant has not uploaded any documents yet.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colors.textSecondary),
                ),
              )
            else
              ...documents.map((d) => AdminDocumentRow(document: d)),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _decide(user, false),
                    child: const Text('Reject'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _decide(user, true),
                    child: const Text('Approve'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    });
  }
}

// --------------------------------------------------------- corrections

class _CorrectionQueueTab extends StatefulWidget {
  const _CorrectionQueueTab();

  @override
  State<_CorrectionQueueTab> createState() => _CorrectionQueueTabState();
}

class _CorrectionQueueTabState extends _QueueTabState<_CorrectionQueueTab> {
  @override
  String get endpoint => '/crowdsource/shop-corrections?status=pending';
  @override
  String get emptyTitle => 'No corrections waiting';
  @override
  String get emptyMessage => 'Suggested fixes to shop details appear here.';

  Future<void> _decide(Map<String, dynamic> report, bool approve) async {
    String? reason;
    if (!approve) {
      reason = await _askReason(report['shop_name'] as String? ?? 'this shop');
      if (reason == null) return;
    }
    try {
      await ApiClient.instance.patch(
        '/crowdsource/shop-corrections/${report['id']}/status',
        body: {
          'status': approve ? 'approved' : 'rejected',
          if (reason != null && reason.isNotEmpty) 'reason': reason,
        },
      );
      toast(approve ? 'Correction applied' : 'Correction rejected');
      await load();
    } on ApiException catch (e) {
      toast(e.message);
    }
  }

  Future<String?> _askReason(String target) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reason for Rejection'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Specify why this correction for "$target" is being rejected. The reporter will be notified.',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: controller,
              autofocus: true,
              maxLines: 2,
              maxLength: 200,
              decoration: const InputDecoration(
                hintText: 'e.g. Information could not be verified',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () {
              final text = controller.text.trim();
              if (text.isEmpty) return;
              Navigator.pop(dialogContext, text);
            },
            child: const Text('Reject'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return buildList((context, report, _) {
      final colors = context.appColors;
      final changes = Map<String, dynamic>.from(report['changes'] as Map? ?? {});
      return AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              report['shop_name'] as String? ?? 'A shop',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.sm),
            for (final entry in changes.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(
                        entry.key.replaceAll('_', ' '),
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: colors.textSecondary),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${entry.value}',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            if ((report['note'] as String?)?.isNotEmpty ?? false) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                '"${report['note']}"',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic, color: colors.textSecondary),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _decide(report, false),
                    child: const Text('Reject'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _decide(report, true),
                    child: const Text('Apply'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    });
  }
}

// ------------------------------------------------------------- monitor

class _MonitorTab extends StatefulWidget {
  const _MonitorTab();

  @override
  State<_MonitorTab> createState() => _MonitorTabState();
}

class _MonitorTabState extends State<_MonitorTab> {
  ViewState<Map<String, dynamic>> _state = const ViewLoading();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/admin/monitor');
      if (!mounted) return;
      setState(() => _state = ViewData(Map<String, dynamic>.from(response as Map)));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load the monitor.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<Map<String, dynamic>>(
        state: _state,
        onRetry: _load,
        loadingSkeleton: const SkeletonList(itemCount: 3),
        builder: (context, data) {
          final services = (data['services'] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          final errors = (data['recent_errors'] as List? ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              StaggerIn(
                index: 0,
                child: Row(
                  children: [
                    Expanded(
                      child: _Stat(
                        label: 'Active users',
                        value: '${data['active_users'] ?? 0}',
                        sub: 'last ${data['active_window_minutes'] ?? 15} min',
                      ),
                    ),
                    Expanded(
                      child: _Stat(
                        label: 'Orders/min',
                        value: '${data['orders_per_minute'] ?? 0}',
                        sub: '${data['orders_last_hour'] ?? 0} this hour',
                      ),
                    ),
                    Expanded(
                      child: _Stat(
                        label: 'Events/hr',
                        value: '${data['events_last_hour'] ?? 0}',
                        sub: 'across all services',
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              StaggerIn(
                index: 1,
                child: AppCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: _Stat(
                          label: 'CPU load',
                          value: '${data['load_average_1m'] ?? '--'}',
                          sub: '${data['cpu_count'] ?? '?'} cores',
                        ),
                      ),
                      Expanded(
                        child: _Stat(
                          label: 'Memory',
                          value: data['memory_used_percent'] == null
                              ? '--'
                              : '${data['memory_used_percent']}%',
                          sub: 'used',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Services',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.sm),
              for (var i = 0; i < services.length; i++)
                StaggerIn(
                  index: 2 + i,
                  child: _ServiceRow(service: services[i]),
                ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Recent errors',
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (errors.isEmpty)
                Text(
                  'Nothing has failed recently.',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colors.textSecondary),
                )
              else
                for (final error in errors)
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                    child: Text(
                      '${error['event_type']}  ·  ${error['source_service']}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final String sub;

  const _Stat({required this.label, required this.value, required this.sub});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    return Column(
      children: [
        Text(
          value,
          style: Theme.of(context)
              .textTheme
              .headlineSmall
              ?.copyWith(fontWeight: FontWeight.w800),
        ),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        Text(
          sub,
          textAlign: TextAlign.center,
          style: Theme.of(context)
              .textTheme
              .labelSmall
              ?.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

class _ServiceRow extends StatelessWidget {
  final Map<String, dynamic> service;

  const _ServiceRow({required this.service});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final healthy = service['healthy'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: healthy ? colors.success : Theme.of(context).colorScheme.error,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              service['name'] as String? ?? '',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          Text(
            healthy ? '${service['latency_ms'] ?? '--'} ms' : 'down',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: healthy ? colors.textSecondary : Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}
