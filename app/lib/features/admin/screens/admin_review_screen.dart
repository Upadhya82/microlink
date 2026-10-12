import 'dart:async';

import 'package:flutter/material.dart';

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

/// The admin's moderation desk: everything waiting on a decision, plus the
/// live system monitor.
///
/// One screen with tabs rather than four entries on the dashboard, because
/// these are the same job done against different queues -- the admin works
/// through them in one sitting.
class AdminReviewScreen extends StatelessWidget {
  const AdminReviewScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: BrandedAppBar(
          title: const Text('Review & monitor'),
          // Not isScrollable: with four short labels a scrollable TabBar
          // lays its hit areas out narrower than the painted labels, which
          // left the last tab visually present but untappable.
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Shops'),
              Tab(text: 'Applicants'),
              Tab(text: 'Corrections'),
              Tab(text: 'Monitor'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _ShopQueueTab(),
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

  Future<void> load() async {
    setState(() => state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get(endpoint);
      final rows = (response as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
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

  Future<void> _verify(Map<String, dynamic> shop, bool approve) async {
    try {
      await ApiClient.instance.patch(
        '/shops/${shop['id']}/verify',
        body: {'is_verified': approve},
      );
      toast(approve ? '${shop['name']} verified' : '${shop['name']} left unverified');
      await load();
    } on ApiException catch (e) {
      toast(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildList((context, shop, _) {
      final colors = context.appColors;
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
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _verify(shop, false),
                    child: const Text('Leave pending'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _verify(shop, true),
                    icon: const Icon(Icons.verified_rounded, size: 18),
                    label: const Text('Verify'),
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
  Widget build(BuildContext context) {
    return buildList((context, user, _) {
      final colors = context.appColors;
      final userId = user['id'] as String;
      final documents = _documents[userId];

      return AppCard(
        padding: EdgeInsets.zero,
        child: ExpansionTile(
          shape: const Border(),
          onExpansionChanged: (open) {
            if (open) _loadDocuments(userId);
          },
          title: Text(
            user['full_name'] as String? ?? 'Unnamed',
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700),
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
              ...documents.map((d) => _DocumentRow(document: d)),
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

class _DocumentRow extends StatelessWidget {
  final Map<String, dynamic> document;

  const _DocumentRow({required this.document});

  @override
  Widget build(BuildContext context) {
    final isPdf = (document['content_type'] as String? ?? '').contains('pdf');
    final url = mediaUrl('/users/documents/${document['id']}/file');

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          // PDFs have no thumbnail, so show the type instead of a broken box.
          if (isPdf)
            const Icon(Icons.picture_as_pdf_rounded, size: 44)
          else
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.input),
              child: Image.network(
                url!,
                headers: authImageHeaders(),
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined, size: 44),
              ),
            ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              (document['doc_type'] as String? ?? '').replaceAll('_', ' '),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          IconButton(
            tooltip: 'Open full size',
            visualDensity: VisualDensity.compact,
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => Dialog(
                child: isPdf
                    ? const Padding(
                        padding: EdgeInsets.all(AppSpacing.xl),
                        child: Text('PDF preview is not available in the app.'),
                      )
                    : InteractiveViewer(
                        child: Image.network(url!, headers: authImageHeaders()),
                      ),
              ),
            ),
            icon: const Icon(Icons.open_in_full_rounded, size: 18),
          ),
        ],
      ),
    );
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
    try {
      await ApiClient.instance.patch(
        '/crowdsource/shop-corrections/${report['id']}/status',
        body: {'status': approve ? 'approved' : 'rejected'},
      );
      toast(approve ? 'Correction applied' : 'Correction rejected');
      await load();
    } on ApiException catch (e) {
      toast(e.message);
    }
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
