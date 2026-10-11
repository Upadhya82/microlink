import 'package:flutter/material.dart';
import '../../../core/widgets/photo_picker_field.dart';
import '../../../core/network/multipart_upload.dart';

import '../../../core/utils/media_url.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';

/// The Admin Dashboard: independently-loading tabs backed by admin-service
/// (`/admin/*` and `/ads/*` through the gateway) and crowdsource-service
/// (`/crowdsource/*` through the gateway) -- platform analytics, a raw
/// activity log, user complaints triage, crowdsourced shop and road report
/// moderation, ad approvals, and subscription plan management.
class AdminDashboardScreen extends StatefulWidget {
  const AdminDashboardScreen({super.key});

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 7,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.shield_outlined, size: 20, color: colorScheme.primary),
              const SizedBox(width: AppSpacing.sm),
              const Text('Admin Dashboard'),
            ],
          ),
          bottom: TabBar(
            isScrollable: true,
            indicatorColor: colorScheme.primary,
            indicatorWeight: 2,
            labelColor: colorScheme.primary,
            unselectedLabelColor: context.appColors.textSecondary,
            labelStyle: const TextStyle(fontWeight: FontWeight.w700),
            unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
            tabs: const [
              Tab(text: 'Overview', icon: Icon(Icons.insights_outlined)),
              Tab(text: 'Activity Log', icon: Icon(Icons.history)),
              Tab(text: 'Complaints', icon: Icon(Icons.report_problem_outlined)),
              Tab(text: 'Shop Reports', icon: Icon(Icons.storefront_outlined)),
              Tab(text: 'Road Reports', icon: Icon(Icons.warning_amber_outlined)),
              Tab(text: 'Ads', icon: Icon(Icons.campaign_outlined)),
              Tab(text: 'Plans', icon: Icon(Icons.workspace_premium_outlined)),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            _OverviewTab(),
            _ActivityLogTab(),
            _ComplaintsTab(),
            _ShopReportsTab(),
            _RoadReportsTab(),
            _AdsTab(),
            _PlansTab(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

String _timeAgo(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inSeconds < 60) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
}

DateTime? _tryParseDate(String? value) {
  if (value == null) return null;
  return DateTime.tryParse(value);
}

/// Maps an activity-log event type (e.g. `shop.status_changed`) to an icon
/// and a foreground/background tint pair, categorized by the event's
/// namespace prefix so the feed reads like the approved mockup.
(IconData, Color, Color) _activityVisuals(BuildContext context, String eventType) {
  final colorScheme = Theme.of(context).colorScheme;
  final category = eventType.split('.').first;
  return switch (category) {
    'shop' => (Icons.storefront_outlined, colorScheme.primary, colorScheme.primaryContainer),
    'user' => (Icons.person_outline, colorScheme.tertiary, colorScheme.tertiaryContainer),
    'order' => (Icons.receipt_long_outlined, colorScheme.secondary, colorScheme.secondaryContainer),
    'delivery' => (Icons.local_shipping_outlined, colorScheme.secondary, colorScheme.secondaryContainer),
    _ => (Icons.bolt_outlined, context.appColors.textSecondary, colorScheme.surfaceContainerHighest),
  };
}

// ---------------------------------------------------------------------------
// Tab 1: Overview
// ---------------------------------------------------------------------------

class _DayCount {
  final String date;
  final int count;
  const _DayCount(this.date, this.count);
}

class _OverviewData {
  final int totalEvents;
  final Map<String, int> eventsByType;
  final List<_DayCount> eventsLast30Days;

  const _OverviewData({
    required this.totalEvents,
    required this.eventsByType,
    required this.eventsLast30Days,
  });
}

/// A compact metric card used in the stat row at the top of the Overview
/// tab -- icon, big value, small label, matching the approved mockup's
/// "stat tile" visual language.
class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String value;
  final String label;

  const _StatTile({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Expanded(
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(height: AppSpacing.sm),
            Text(
              value,
              style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _OverviewTab extends StatefulWidget {
  const _OverviewTab();

  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> with AutomaticKeepAliveClientMixin {
  ViewState<_OverviewData> _state = const ViewLoading();

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
      final response = await ApiClient.instance.get('/admin/analytics/overview') as Map<String, dynamic>;
      final eventsByType = <String, int>{};
      final rawByType = response['events_by_type'];
      if (rawByType is Map) {
        rawByType.forEach((key, value) {
          eventsByType[key.toString()] = (value as num).toInt();
        });
      }
      final rawDaily = response['events_last_30_days'];
      final daily = <_DayCount>[
        if (rawDaily is List)
          ...rawDaily.map((e) {
            final map = e as Map<String, dynamic>;
            return _DayCount(map['date'].toString(), (map['count'] as num).toInt());
          }),
      ];
      final data = _OverviewData(
        totalEvents: (response['total_events'] as num?)?.toInt() ?? 0,
        eventsByType: eventsByType,
        eventsLast30Days: daily,
      );
      if (!mounted) return;
      setState(() => _state = ViewData(data));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load analytics.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<_OverviewData>(
        state: _state,
        onRetry: _load,
        builder: (context, data) {
          final sortedTypes = data.eventsByType.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value));
          final maxDaily = data.eventsLast30Days.isEmpty
              ? 1
              : data.eventsLast30Days.map((d) => d.count).reduce((a, b) => a > b ? a : b).clamp(1, 1 << 30);
          final last30Total = data.eventsLast30Days.fold<int>(0, (sum, day) => sum + day.count);

          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Row(
                children: [
                  _StatTile(
                    icon: Icons.history_rounded,
                    iconColor: colorScheme.primary,
                    value: '${data.totalEvents}',
                    label: 'Total Events',
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  _StatTile(
                    icon: Icons.category_outlined,
                    iconColor: colorScheme.tertiary,
                    value: '${sortedTypes.length}',
                    label: 'Event Types',
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  _StatTile(
                    icon: Icons.calendar_month_outlined,
                    iconColor: colorScheme.secondary,
                    value: '$last30Total',
                    label: 'Last 30 Days',
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xl),
              Text('Events by Type', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: AppSpacing.sm),
              if (sortedTypes.isEmpty)
                Text(
                  'No events recorded yet.',
                  style: textTheme.bodyMedium?.copyWith(color: context.appColors.textSecondary),
                )
              else
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: sortedTypes.map((entry) {
                    return Chip(
                      label: Text('${entry.key}: ${entry.value}'),
                    );
                  }).toList(),
                ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Last 30 Days',
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (data.eventsLast30Days.isEmpty)
                AppCard(
                  child: Text(
                    'No activity in the last 30 days.',
                    style: textTheme.bodyMedium?.copyWith(color: context.appColors.textSecondary),
                  ),
                )
              else
                AppCard(
                  child: SizedBox(
                    height: 140,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: data.eventsLast30Days.map((day) {
                        final barHeight = (day.count / maxDaily) * 110;
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 1.5),
                            child: Tooltip(
                              message: '${day.date}: ${day.count}',
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  Container(
                                    height: barHeight < 3.0 ? 3.0 : barHeight,
                                    decoration: BoxDecoration(
                                      color: colorScheme.primary,
                                      borderRadius: const BorderRadius.vertical(
                                        top: Radius.circular(2),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              if (data.eventsLast30Days.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      data.eventsLast30Days.first.date,
                      style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                    ),
                    Text(
                      data.eventsLast30Days.last.date,
                      style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 2: Activity Log
// ---------------------------------------------------------------------------

class _ActivityItem {
  final String id;
  final String eventType;
  final String sourceService;
  final Map<String, dynamic> payload;
  final DateTime? createdAt;

  const _ActivityItem({
    required this.id,
    required this.eventType,
    required this.sourceService,
    required this.payload,
    required this.createdAt,
  });

  factory _ActivityItem.fromJson(Map<String, dynamic> json) {
    return _ActivityItem(
      id: json['id'].toString(),
      eventType: json['event_type']?.toString() ?? 'unknown',
      sourceService: json['source_service']?.toString() ?? 'unknown',
      payload: (json['payload'] is Map)
          ? Map<String, dynamic>.from(json['payload'] as Map)
          : <String, dynamic>{},
      createdAt: _tryParseDate(json['created_at']?.toString()),
    );
  }
}

class _ActivityLogTab extends StatefulWidget {
  const _ActivityLogTab();

  @override
  State<_ActivityLogTab> createState() => _ActivityLogTabState();
}

class _ActivityLogTabState extends State<_ActivityLogTab> with AutomaticKeepAliveClientMixin {
  ViewState<List<_ActivityItem>> _state = const ViewLoading();

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
      final response = await ApiClient.instance.get('/admin/activity-log', query: {'limit': 100});
      final items = (response as List<dynamic>)
          .map((e) => _ActivityItem.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _state = ViewData(items));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load the activity log.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final textTheme = Theme.of(context).textTheme;

    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<List<_ActivityItem>>(
        state: _state,
        onRetry: _load,
        isEmpty: (data) => data.isEmpty,
        emptyTitle: 'No activity yet',
        emptyMessage: 'Platform events will show up here as they happen.',
        emptyIcon: Icons.history,
        builder: (context, items) {
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (context, index) {
              final item = items[index];
              final payloadText = item.payload.entries.map((e) => '${e.key}: ${e.value}').join(', ');
              final (icon, iconColor, iconBackground) = _activityVisuals(context, item.eventType);
              final caption = [
                if (item.createdAt != null) _timeAgo(item.createdAt!),
                item.sourceService,
              ].join(' · ');
              return AppCard(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: iconBackground,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(icon, size: 16, color: iconColor),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text.rich(
                            TextSpan(
                              style: textTheme.bodyMedium,
                              children: [
                                TextSpan(
                                  text: item.eventType,
                                  style: const TextStyle(fontWeight: FontWeight.w700),
                                ),
                                if (payloadText.isNotEmpty) TextSpan(text: '  —  $payloadText'),
                              ],
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            caption,
                            style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 3: Complaints
// ---------------------------------------------------------------------------

const List<String> _complaintStatuses = ['open', 'in_review', 'resolved', 'dismissed'];

String _formatStatusLabel(String status) {
  return switch (status) {
    'open' => 'Open',
    'in_review' => 'In Review',
    'resolved' => 'Resolved',
    'dismissed' => 'Dismissed',
    _ => status,
  };
}

String _formatCategoryLabel(String category) {
  return switch (category) {
    'shop' => 'Shop',
    'delivery' => 'Delivery',
    'agent' => 'Agent',
    'other' => 'Other',
    _ => category,
  };
}

class _Complaint {
  final String id;
  final String complainantId;
  final String subject;
  final String description;
  final String category;
  final String status;
  final String? adminResponse;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const _Complaint({
    required this.id,
    required this.complainantId,
    required this.subject,
    required this.description,
    required this.category,
    required this.status,
    required this.adminResponse,
    required this.createdAt,
    required this.updatedAt,
  });

  factory _Complaint.fromJson(Map<String, dynamic> json) {
    return _Complaint(
      id: json['id'].toString(),
      complainantId: json['complainant_id']?.toString() ?? '',
      subject: json['subject']?.toString() ?? '(no subject)',
      description: json['description']?.toString() ?? '',
      category: json['category']?.toString() ?? 'other',
      status: json['status']?.toString() ?? 'open',
      adminResponse: json['admin_response']?.toString(),
      createdAt: _tryParseDate(json['created_at']?.toString()),
      updatedAt: _tryParseDate(json['updated_at']?.toString()),
    );
  }
}

class _ComplaintsTab extends StatefulWidget {
  const _ComplaintsTab();

  @override
  State<_ComplaintsTab> createState() => _ComplaintsTabState();
}

class _ComplaintsTabState extends State<_ComplaintsTab> with AutomaticKeepAliveClientMixin {
  ViewState<List<_Complaint>> _state = const ViewLoading();

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
      final response = await ApiClient.instance.get('/admin/complaints');
      final items =
          (response as List<dynamic>).map((e) => _Complaint.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() => _state = ViewData(items));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load complaints.'));
    }
  }

  (Color, Color) _statusColors(BuildContext context, String status) {
    final colorScheme = Theme.of(context).colorScheme;
    final appColors = context.appColors;
    return switch (status) {
      'open' => (colorScheme.errorContainer, colorScheme.onErrorContainer),
      'in_review' => (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer),
      'resolved' => (appColors.success.withValues(alpha: 0.18), appColors.success),
      'dismissed' => (colorScheme.surfaceContainerHighest, appColors.textSecondary),
      _ => (colorScheme.surfaceContainerHighest, appColors.textSecondary),
    };
  }

  Future<void> _openEditSheet(_Complaint complaint) async {
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _ComplaintEditSheet(complaint: complaint),
    );
    if (updated == true) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final textTheme = Theme.of(context).textTheme;

    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<List<_Complaint>>(
        state: _state,
        onRetry: _load,
        isEmpty: (data) => data.isEmpty,
        emptyTitle: 'No complaints',
        emptyMessage: 'Complaints submitted by users will appear here.',
        emptyIcon: Icons.forum_outlined,
        builder: (context, items) {
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (context, index) {
              final complaint = items[index];
              final (bg, fg) = _statusColors(context, complaint.status);
              return AppCard(
                onTap: () => _openEditSheet(complaint),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            complaint.subject,
                            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        StatusBadge(
                          label: _formatStatusLabel(complaint.status),
                          background: bg,
                          foreground: fg,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      _formatCategoryLabel(complaint.category),
                      style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      complaint.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodyMedium,
                    ),
                    if (complaint.adminResponse != null && complaint.adminResponse!.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Response: ${complaint.adminResponse}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: context.appColors.textSecondary,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                    if (complaint.createdAt != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        _timeAgo(complaint.createdAt!),
                        style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _ComplaintEditSheet extends StatefulWidget {
  final _Complaint complaint;

  const _ComplaintEditSheet({required this.complaint});

  @override
  State<_ComplaintEditSheet> createState() => _ComplaintEditSheetState();
}

class _ComplaintEditSheetState extends State<_ComplaintEditSheet> {
  late String _status;
  late final TextEditingController _responseController;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _status = widget.complaint.status;
    _responseController = TextEditingController(text: widget.complaint.adminResponse ?? '');
  }

  @override
  void dispose() {
    _responseController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _isSubmitting = true);
    try {
      await ApiClient.instance.patch(
        '/admin/complaints/${widget.complaint.id}',
        body: {
          'status': _status,
          'admin_response': _responseController.text.trim().isEmpty
              ? null
              : _responseController.text.trim(),
        },
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      setState(() => _isSubmitting = false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not update the complaint.')));
      setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.complaint.subject,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              widget.complaint.description,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: context.appColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            DropdownButtonFormField<String>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: 'Status'),
              items: _complaintStatuses
                  .map((s) => DropdownMenuItem(value: s, child: Text(_formatStatusLabel(s))))
                  .toList(),
              onChanged: _isSubmitting ? null : (value) => setState(() => _status = value ?? _status),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppTextField(
              controller: _responseController,
              label: 'Admin Response',
              hint: 'Reply visible to the user',
              maxLines: 3,
              enabled: !_isSubmitting,
            ),
            const SizedBox(height: AppSpacing.xl),
            AppButton(
              label: 'Save',
              isLoading: _isSubmitting,
              onPressed: _isSubmitting ? null : _submit,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab: Shop Reports (crowdsourced new-shop submissions -- admin approve/reject)
// ---------------------------------------------------------------------------

class _ShopReport {
  final String id;
  final String reporterId;
  final String shopName;
  final String category;
  final String address;
  final String description;
  final String status;
  final DateTime? createdAt;

  const _ShopReport({
    required this.id,
    required this.reporterId,
    required this.shopName,
    required this.category,
    required this.address,
    required this.description,
    required this.status,
    required this.createdAt,
  });

  factory _ShopReport.fromJson(Map<String, dynamic> json) {
    return _ShopReport(
      id: json['id'].toString(),
      reporterId: json['reporter_id']?.toString() ?? '',
      shopName: json['shop_name']?.toString() ?? '',
      category: json['category']?.toString() ?? '',
      address: json['address']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      createdAt: _tryParseDate(json['created_at']?.toString()),
    );
  }
}

class _ShopReportsTab extends StatefulWidget {
  const _ShopReportsTab();

  @override
  State<_ShopReportsTab> createState() => _ShopReportsTabState();
}

class _ShopReportsTabState extends State<_ShopReportsTab> with AutomaticKeepAliveClientMixin {
  ViewState<List<_ShopReport>> _state = const ViewLoading();

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
      final response = await ApiClient.instance.get('/crowdsource/shop-reports');
      final items = (response as List<dynamic>)
          .map((e) => _ShopReport.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _state = ViewData(items));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load shop reports.'));
    }
  }

  Future<void> _setStatus(_ShopReport report, String status) async {
    try {
      await ApiClient.instance.patch('/crowdsource/shop-reports/${report.id}/status', body: {'status': status});
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not update the shop report.')));
    }
  }

  (Color, Color) _statusColors(BuildContext context, String status) {
    final colorScheme = Theme.of(context).colorScheme;
    final appColors = context.appColors;
    return switch (status) {
      'pending' => (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer),
      'approved' => (appColors.success.withValues(alpha: 0.18), appColors.success),
      'rejected' => (colorScheme.errorContainer, colorScheme.onErrorContainer),
      _ => (colorScheme.surfaceContainerHighest, appColors.textSecondary),
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<List<_ShopReport>>(
        state: _state,
        onRetry: _load,
        isEmpty: (data) => data.isEmpty,
        emptyTitle: 'No shop reports',
        emptyMessage: 'New shops reported by users will appear here for review.',
        emptyIcon: Icons.storefront_outlined,
        builder: (context, items) {
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (context, index) {
              final report = items[index];
              final (bg, fg) = _statusColors(context, report.status);
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
                                report.shopName,
                                style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                              ),
                              Text(
                                report.category,
                                style: textTheme.bodySmall
                                    ?.copyWith(color: context.appColors.textSecondary, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                        StatusBadge(
                          label: report.status[0].toUpperCase() + report.status.substring(1),
                          background: bg,
                          foreground: fg,
                        ),
                      ],
                    ),
                    if (report.address.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(report.address, style: textTheme.bodyMedium),
                    ],
                    if (report.description.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(report.description, style: textTheme.bodySmall),
                    ],
                    if (report.createdAt != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        _timeAgo(report.createdAt!),
                        style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                      ),
                    ],
                    if (report.status == 'pending') ...[
                      const SizedBox(height: AppSpacing.md),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _setStatus(report, 'rejected'),
                              icon: Icon(Icons.close, color: colorScheme.error, size: 18),
                              label: Text('Reject', style: TextStyle(color: colorScheme.error)),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _setStatus(report, 'approved'),
                              icon: const Icon(Icons.check, size: 18),
                              label: const Text('Approve'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab: Road Reports (crowdsourced road-condition reports -- admin verify/reject)
// ---------------------------------------------------------------------------

class _RoadReport {
  final String id;
  final String reporterId;
  final String conditionType;
  final String severity;
  final String description;
  final String status;
  final DateTime? createdAt;

  const _RoadReport({
    required this.id,
    required this.reporterId,
    required this.conditionType,
    required this.severity,
    required this.description,
    required this.status,
    required this.createdAt,
  });

  factory _RoadReport.fromJson(Map<String, dynamic> json) {
    return _RoadReport(
      id: json['id'].toString(),
      reporterId: json['reporter_id']?.toString() ?? '',
      conditionType: json['condition_type']?.toString() ?? '',
      severity: json['severity']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      createdAt: _tryParseDate(json['created_at']?.toString()),
    );
  }
}

class _RoadReportsTab extends StatefulWidget {
  const _RoadReportsTab();

  @override
  State<_RoadReportsTab> createState() => _RoadReportsTabState();
}

class _RoadReportsTabState extends State<_RoadReportsTab> with AutomaticKeepAliveClientMixin {
  ViewState<List<_RoadReport>> _state = const ViewLoading();

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
      final response = await ApiClient.instance.get('/crowdsource/road-reports');
      final items = (response as List<dynamic>)
          .map((e) => _RoadReport.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      setState(() => _state = ViewData(items));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load road reports.'));
    }
  }

  // The backend status update only accepts "verified", "resolved", or
  // "rejected" (never "approved") -- "verified" is what bumps the
  // reporter's trust score, so that is what the Approve button sends.
  Future<void> _setStatus(_RoadReport report, String status) async {
    try {
      await ApiClient.instance.patch('/crowdsource/road-reports/${report.id}/status', body: {'status': status});
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not update the road report.')));
    }
  }

  (Color, Color) _statusColors(BuildContext context, String status) {
    final colorScheme = Theme.of(context).colorScheme;
    final appColors = context.appColors;
    return switch (status) {
      'pending' => (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer),
      'verified' || 'resolved' => (appColors.success.withValues(alpha: 0.18), appColors.success),
      'rejected' => (colorScheme.errorContainer, colorScheme.onErrorContainer),
      _ => (colorScheme.surfaceContainerHighest, appColors.textSecondary),
    };
  }

  (Color, Color) _severityColors(BuildContext context, String severity) {
    final colorScheme = Theme.of(context).colorScheme;
    final appColors = context.appColors;
    return switch (severity) {
      'high' => (colorScheme.errorContainer, colorScheme.onErrorContainer),
      'medium' => (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer),
      _ => (colorScheme.surfaceContainerHighest, appColors.textSecondary),
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<List<_RoadReport>>(
        state: _state,
        onRetry: _load,
        isEmpty: (data) => data.isEmpty,
        emptyTitle: 'No road reports',
        emptyMessage: 'Road issues reported by users will appear here for review.',
        emptyIcon: Icons.warning_amber_outlined,
        builder: (context, items) {
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (context, index) {
              final report = items[index];
              final (statusBg, statusFg) = _statusColors(context, report.status);
              final (sevBg, sevFg) = _severityColors(context, report.severity);
              return AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            report.conditionType[0].toUpperCase() + report.conditionType.substring(1),
                            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        StatusBadge(
                          label: report.severity[0].toUpperCase() + report.severity.substring(1),
                          background: sevBg,
                          foreground: sevFg,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        StatusBadge(
                          label: report.status[0].toUpperCase() + report.status.substring(1),
                          background: statusBg,
                          foreground: statusFg,
                        ),
                      ],
                    ),
                    if (report.description.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(report.description, style: textTheme.bodyMedium),
                    ],
                    if (report.createdAt != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        _timeAgo(report.createdAt!),
                        style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                      ),
                    ],
                    if (report.status == 'pending') ...[
                      const SizedBox(height: AppSpacing.md),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _setStatus(report, 'rejected'),
                              icon: Icon(Icons.close, color: colorScheme.error, size: 18),
                              label: Text('Reject', style: TextStyle(color: colorScheme.error)),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => _setStatus(report, 'verified'),
                              icon: const Icon(Icons.check, size: 18),
                              label: const Text('Verify'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab: Ads (shop/company sponsor banners -- submit, admin approve/reject)
// ---------------------------------------------------------------------------

class _Ad {
  final String id;
  final String? shopId;
  final String advertiserName;
  final String submittedByUserId;
  final String title;
  final String subtitle;
  final String imageUrl;
  final String status;
  final DateTime? createdAt;

  const _Ad({
    required this.id,
    required this.shopId,
    required this.advertiserName,
    required this.submittedByUserId,
    required this.title,
    required this.subtitle,
    required this.imageUrl,
    required this.status,
    required this.createdAt,
  });

  factory _Ad.fromJson(Map<String, dynamic> json) {
    return _Ad(
      id: json['id'].toString(),
      shopId: json['shop_id']?.toString(),
      advertiserName: json['advertiser_name']?.toString() ?? '',
      submittedByUserId: json['submitted_by_user_id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      subtitle: json['subtitle']?.toString() ?? '',
      imageUrl: json['image_url']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      createdAt: _tryParseDate(json['created_at']?.toString()),
    );
  }
}

class _AdsTab extends StatefulWidget {
  const _AdsTab();

  @override
  State<_AdsTab> createState() => _AdsTabState();
}

class _AdsTabState extends State<_AdsTab> with AutomaticKeepAliveClientMixin {
  ViewState<List<_Ad>> _state = const ViewLoading();

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
      final response = await ApiClient.instance.get('/ads');
      final items = (response as List<dynamic>).map((e) => _Ad.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() => _state = ViewData(items));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load ads.'));
    }
  }

  Future<void> _setStatus(_Ad ad, String status) async {
    try {
      await ApiClient.instance.patch('/ads/${ad.id}/status', body: {'status': status});
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not update the ad.')));
    }
  }

  Future<void> _openEditSheet(_Ad ad) async {
    final updated = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _AdEditSheet(ad: ad),
    );
    if (updated == true) await _load();
  }

  (Color, Color) _statusColors(BuildContext context, String status) {
    final colorScheme = Theme.of(context).colorScheme;
    final appColors = context.appColors;
    return switch (status) {
      'pending' => (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer),
      'approved' => (appColors.success.withValues(alpha: 0.18), appColors.success),
      'rejected' => (colorScheme.errorContainer, colorScheme.onErrorContainer),
      _ => (colorScheme.surfaceContainerHighest, appColors.textSecondary),
    };
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<List<_Ad>>(
        state: _state,
        onRetry: _load,
        isEmpty: (data) => data.isEmpty,
        emptyTitle: 'No ad submissions',
        emptyMessage: 'Ads submitted by shop owners or companies will appear here for review.',
        emptyIcon: Icons.campaign_outlined,
        builder: (context, items) {
          return ListView.separated(
            padding: const EdgeInsets.all(AppSpacing.lg),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
            itemBuilder: (context, index) {
              final ad = items[index];
              final (bg, fg) = _statusColors(context, ad.status);
              return AppCard(
                onTap: () => _openEditSheet(ad),
                padding: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(AppRadius.input),
                            child: Image.network(
                              mediaUrl(ad.imageUrl) ?? ad.imageUrl,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) => Container(
                                width: 56,
                                height: 56,
                                color: colorScheme.surfaceContainerHighest,
                                alignment: Alignment.center,
                                child: Icon(Icons.campaign_outlined, color: colorScheme.outline),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  ad.advertiserName,
                                  style: textTheme.bodySmall
                                      ?.copyWith(color: context.appColors.textSecondary, fontWeight: FontWeight.w600),
                                ),
                                Text(
                                  ad.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ],
                            ),
                          ),
                          StatusBadge(label: ad.status[0].toUpperCase() + ad.status.substring(1), background: bg, foreground: fg),
                        ],
                      ),
                      if (ad.createdAt != null) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          _timeAgo(ad.createdAt!),
                          style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
                        ),
                      ],
                      if (ad.status == 'pending') ...[
                        const SizedBox(height: AppSpacing.md),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () => _setStatus(ad, 'rejected'),
                                icon: Icon(Icons.close, color: colorScheme.error, size: 18),
                                label: Text('Reject', style: TextStyle(color: colorScheme.error)),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () => _setStatus(ad, 'approved'),
                                icon: const Icon(Icons.check, size: 18),
                                label: const Text('Approve'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AdEditSheet extends StatefulWidget {
  final _Ad ad;

  const _AdEditSheet({required this.ad});

  @override
  State<_AdEditSheet> createState() => _AdEditSheetState();
}

class _AdEditSheetState extends State<_AdEditSheet> {
  late final TextEditingController _advertiserController;
  late final TextEditingController _titleController;
  late final TextEditingController _subtitleController;
  PickedFile? _banner;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _advertiserController = TextEditingController(text: widget.ad.advertiserName);
    _titleController = TextEditingController(text: widget.ad.title);
    _subtitleController = TextEditingController(text: widget.ad.subtitle);

  }

  @override
  void dispose() {
    _advertiserController.dispose();
    _titleController.dispose();
    _subtitleController.dispose();

    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _isSubmitting = true);
    try {
      await ApiClient.instance.patch(
        '/ads/${widget.ad.id}',
        body: {
          'advertiser_name': _advertiserController.text.trim(),
          'title': _titleController.text.trim(),
          'subtitle': _subtitleController.text.trim(),
        },
      );
      // Only sent when the admin actually chose a new banner, so saving a
      // copy change does not disturb the image already on the ad.
      final banner = _banner;
      if (banner != null) {
        await MultipartUpload.send(
          path: '/ads/${widget.ad.id}/image',
          file: banner,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      setState(() => _isSubmitting = false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not save this ad.')));
      setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit ad',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Polish the copy or image to match the advertiser\'s brand before approving.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: context.appColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppTextField(controller: _advertiserController, label: 'Advertiser name'),
            const SizedBox(height: AppSpacing.md),
            AppTextField(controller: _titleController, label: 'Title'),
            const SizedBox(height: AppSpacing.md),
            AppTextField(controller: _subtitleController, label: 'Subtitle'),
            const SizedBox(height: AppSpacing.md),
            PhotoPickerField(
              file: _banner,
              label: 'Banner image',
              hint: 'Choose a file to replace the current banner',
              enabled: !_isSubmitting,
              onChanged: (f) => setState(() => _banner = f),
            ),
            const SizedBox(height: AppSpacing.lg),
            AppButton(
              label: 'Save',
              isLoading: _isSubmitting,
              onPressed: _isSubmitting ? null : _save,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tab 4: Subscription Plans
// ---------------------------------------------------------------------------

class _Plan {
  final String id;
  final String name;
  final String description;
  final double priceMonthly;
  final List<String> features;

  const _Plan({
    required this.id,
    required this.name,
    required this.description,
    required this.priceMonthly,
    required this.features,
  });

  factory _Plan.fromJson(Map<String, dynamic> json) {
    return _Plan(
      id: json['id'].toString(),
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      priceMonthly: (json['price_monthly'] as num?)?.toDouble() ?? 0,
      features: (json['features'] is List)
          ? (json['features'] as List).map((e) => e.toString()).toList()
          : <String>[],
    );
  }
}

class _PlansTab extends StatefulWidget {
  const _PlansTab();

  @override
  State<_PlansTab> createState() => _PlansTabState();
}

class _PlansTabState extends State<_PlansTab> with AutomaticKeepAliveClientMixin {
  ViewState<List<_Plan>> _state = const ViewLoading();

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
      final response = await ApiClient.instance.get('/admin/subscription-plans');
      final items = (response as List<dynamic>).map((e) => _Plan.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() => _state = ViewData(items));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load subscription plans.'));
    }
  }

  Future<void> _openAddSheet() async {
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => const _AddPlanSheet(),
    );
    if (created == true) {
      await _load();
    }
  }

  Future<void> _confirmDelete(_Plan plan) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete plan?'),
        content: Text('"${plan.name}" will be deactivated and hidden from users.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('Delete', style: TextStyle(color: Theme.of(dialogContext).colorScheme.error)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ApiClient.instance.delete('/admin/subscription-plans/${plan.id}');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final textTheme = Theme.of(context).textTheme;

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _load,
          child: AsyncStateView<List<_Plan>>(
            state: _state,
            onRetry: _load,
            isEmpty: (data) => data.isEmpty,
            emptyTitle: 'No plans yet',
            emptyMessage: 'Add a subscription plan to get started.',
            emptyIcon: Icons.workspace_premium_outlined,
            builder: (context, items) {
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.lg,
                  AppSpacing.xxxl + AppSpacing.xl,
                ),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.md),
                itemBuilder: (context, index) {
                  final plan = items[index];
                  return AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                plan.name,
                                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline, color: Theme.of(context).colorScheme.error),
                              tooltip: 'Delete plan',
                              onPressed: () => _confirmDelete(plan),
                            ),
                          ],
                        ),
                        Text(
                          '\$${plan.priceMonthly.toStringAsFixed(2)}/mo',
                          style: textTheme.titleSmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (plan.description.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.sm),
                          Text(plan.description, style: textTheme.bodyMedium),
                        ],
                        if (plan.features.isNotEmpty) ...[
                          const SizedBox(height: AppSpacing.md),
                          Wrap(
                            spacing: AppSpacing.sm,
                            runSpacing: AppSpacing.sm,
                            children: plan.features
                                .map((f) => Chip(
                                      visualDensity: VisualDensity.compact,
                                      label: Text(f),
                                    ))
                                .toList(),
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
        Positioned(
          right: AppSpacing.lg,
          bottom: AppSpacing.lg,
          child: FloatingActionButton(
            onPressed: _openAddSheet,
            child: const Icon(Icons.add),
          ),
        ),
      ],
    );
  }
}

class _AddPlanSheet extends StatefulWidget {
  const _AddPlanSheet();

  @override
  State<_AddPlanSheet> createState() => _AddPlanSheetState();
}

class _AddPlanSheetState extends State<_AddPlanSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _priceController = TextEditingController();
  final _featuresController = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _priceController.dispose();
    _featuresController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;

    setState(() => _isSubmitting = true);
    try {
      final features = _featuresController.text
          .split(',')
          .map((f) => f.trim())
          .where((f) => f.isNotEmpty)
          .toList();
      await ApiClient.instance.post(
        '/admin/subscription-plans',
        body: {
          'name': _nameController.text.trim(),
          'description': _descriptionController.text.trim(),
          'price_monthly': double.tryParse(_priceController.text.trim()) ?? 0,
          'features': features,
        },
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      setState(() => _isSubmitting = false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not create the plan.')));
      setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.sm,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'New Subscription Plan',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppTextField(
                controller: _nameController,
                label: 'Name',
                enabled: !_isSubmitting,
                validator: (value) =>
                    (value == null || value.trim().isEmpty) ? 'Name is required' : null,
              ),
              const SizedBox(height: AppSpacing.lg),
              AppTextField(
                controller: _descriptionController,
                label: 'Description',
                maxLines: 2,
                enabled: !_isSubmitting,
              ),
              const SizedBox(height: AppSpacing.lg),
              AppTextField(
                controller: _priceController,
                label: 'Price per month',
                hint: 'e.g. 9.99',
                keyboardType: TextInputType.numberWithOptions(decimal: true),
                enabled: !_isSubmitting,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) return 'Price is required';
                  if (double.tryParse(value.trim()) == null) return 'Enter a valid number';
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.lg),
              AppTextField(
                controller: _featuresController,
                label: 'Features',
                hint: 'Comma-separated, e.g. Priority support, No ads',
                maxLines: 2,
                enabled: !_isSubmitting,
              ),
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                label: 'Create Plan',
                isLoading: _isSubmitting,
                onPressed: _isSubmitting ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}