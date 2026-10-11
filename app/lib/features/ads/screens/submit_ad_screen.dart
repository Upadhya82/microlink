import 'package:flutter/material.dart';
import '../../../core/widgets/photo_picker_field.dart';
import '../../../core/network/multipart_upload.dart';

import '../../../core/utils/media_url.dart';
import '../../../core/models/ad.dart';
import '../../../core/models/shop.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/route_args.dart';
import '../../../core/utils/validators.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/app_text_field.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/status_badge.dart';

/// Lets a shop owner (or a company) submit a sponsored banner to run on the
/// customer Home screen. Submits to `POST /ads`; every submission starts
/// `pending` and only an admin can approve it (Admin Dashboard -> Ads tab).
///
/// The screen doubles as a status tracker: below the form it lists the
/// signed-in user's own submissions (`GET /ads`) with their review state, so
/// an advertiser can see when a banner goes live without asking an admin.
class SubmitAdScreen extends StatefulWidget {
  final SubmitAdArgs args;

  const SubmitAdScreen({super.key, this.args = const SubmitAdArgs()});

  @override
  State<SubmitAdScreen> createState() => _SubmitAdScreenState();
}

class _SubmitAdScreenState extends State<SubmitAdScreen> {
  final _formKey = GlobalKey<FormState>();
  final _advertiserController = TextEditingController();
  final _titleController = TextEditingController();
  final _subtitleController = TextEditingController();
  PickedFile? _banner;

  /// `null` = the ad promotes an outside company with no MicroLink shop.
  String? _linkedShopId;
  List<Shop> _myShops = const [];

  DateTime? _startDate;
  DateTime? _endDate;

  bool _submitting = false;
  ViewState<List<Ad>> _submissionsState = const ViewLoading();

  @override
  void initState() {
    super.initState();
    _advertiserController.text = widget.args.shopName ?? '';
    _linkedShopId = widget.args.shopId;
    _loadMyShops();
    _loadSubmissions();
  }

  @override
  void dispose() {
    _advertiserController.dispose();
    _titleController.dispose();
    _subtitleController.dispose();

    super.dispose();
  }

  Future<void> _loadMyShops() async {
    try {
      final response = await ApiClient.instance.get('/shops/owner/me') as List;
      final shops =
          response.map((e) => Shop.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() {
        _myShops = shops;
        // Drop a stale prefill if the caller passed a shop this account
        // doesn't actually own.
        if (_linkedShopId != null && !shops.any((s) => s.id == _linkedShopId)) {
          _linkedShopId = null;
        }
      });
    } on ApiException {
      // Non-fatal: the "link to a shop" picker just stays empty and the ad
      // can still be submitted for an outside company.
    }
  }

  Future<void> _loadSubmissions() async {
    setState(() => _submissionsState = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/ads') as List;
      final ads =
          response.map((e) => Ad.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() => _submissionsState = ViewData(ads));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submissionsState = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() =>
          _submissionsState = const ViewError('Could not load your submissions.'));
    }
  }

  Future<void> _pickDate({required bool isStart}) async {
    final now = DateTime.now();
    final initial = (isStart ? _startDate : _endDate) ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 2),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
        if (_endDate != null && _endDate!.isBefore(picked)) _endDate = null;
      } else {
        _endDate = picked;
      }
    });
  }

  Future<void> _submit() async {
    final formState = _formKey.currentState;
    if (formState == null || !formState.validate()) return;
    if (_startDate != null && _endDate != null && _endDate!.isBefore(_startDate!)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The end date must be after the start date.')),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      final subtitle = _subtitleController.text.trim();
      final created = await ApiClient.instance.post('/ads', body: {
        'advertiser_name': _advertiserController.text.trim(),
        'title': _titleController.text.trim(),
        if (subtitle.isNotEmpty) 'subtitle': subtitle,
        if (_linkedShopId != null) 'shop_id': _linkedShopId,
        if (_startDate != null) 'start_date': _startDate!.toUtc().toIso8601String(),
        if (_endDate != null) 'end_date': _endDate!.toUtc().toIso8601String(),
      }) as Map<String, dynamic>;

      // The copy is saved; the banner follows as its own call.
      final banner = _banner;
      if (banner != null) {
        await MultipartUpload.send(
          path: '/ads/${created['id']}/image',
          file: banner,
        );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Submitted for review. An admin will approve it before it goes live.'),
        ),
      );
      _titleController.clear();
      _subtitleController.clear();
      _banner = null;
      setState(() {
        _startDate = null;
        _endDate = null;
      });
      await _loadSubmissions();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not submit the ad. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text('Promote on MicroLink'),
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _loadSubmissions,
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.xl),
            children: [
              Text(
                'Run a sponsored banner in the customer Home feed. Submissions '
                'are reviewed by an admin before they appear.',
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: context.appColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.xl),
              _buildForm(context),
              const SizedBox(height: AppSpacing.xxl),
              Text(
                'Your submissions',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.md),
              _buildSubmissions(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppTextField(
            controller: _advertiserController,
            label: 'Advertiser name',
            hint: 'e.g. Perera Super Grocers',
            validator: (v) => Validators.required(v, field: 'Advertiser name'),
          ),
          const SizedBox(height: AppSpacing.md),
          AppTextField(
            controller: _titleController,
            label: 'Headline',
            hint: 'e.g. Fresh vegetables, restocked daily',
            validator: (v) => Validators.required(v, field: 'Headline'),
          ),
          const SizedBox(height: AppSpacing.md),
          AppTextField(
            controller: _subtitleController,
            label: 'Supporting line (optional)',
            hint: 'A short second line under the headline',
            maxLines: 2,
          ),
          const SizedBox(height: AppSpacing.md),
          PhotoPickerField(
            file: _banner,
            label: 'Banner image',
            hint: 'The picture customers see on the Home screen',
            enabled: !_submitting,
            onChanged: (f) => setState(() => _banner = f),
          ),
          const SizedBox(height: AppSpacing.md),
          DropdownButtonFormField<String?>(
            // Re-key when the owner's shops finish loading so the field
            // re-reads `_linkedShopId` (a stale prefill may have been cleared).
            key: ValueKey('linked-shop-picker-${_myShops.length}'),
            initialValue: _linkedShopId,
            decoration: const InputDecoration(labelText: 'Link to one of my shops (optional)'),
            items: [
              const DropdownMenuItem<String?>(
                value: null,
                child: Text('No shop — external company'),
              ),
              ..._myShops.map(
                (s) => DropdownMenuItem<String?>(value: s.id, child: Text(s.name)),
              ),
            ],
            onChanged: (value) => setState(() => _linkedShopId = value),
          ),
          if (_linkedShopId != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Tapping the banner will open this shop.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: context.appColors.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Text('Run dates (optional)', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _DateField(
                  label: 'Starts',
                  date: _startDate,
                  onTap: () => _pickDate(isStart: true),
                  onClear: _startDate == null ? null : () => setState(() => _startDate = null),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _DateField(
                  label: 'Ends',
                  date: _endDate,
                  onTap: () => _pickDate(isStart: false),
                  onClear: _endDate == null ? null : () => setState(() => _endDate = null),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Leave both blank to run the banner until you take it down.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: context.appColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xxl),
          AppButton(
            label: 'Submit for Review',
            isLoading: _submitting,
            onPressed: _submitting ? null : _submit,
          ),
        ],
      ),
    );
  }

  Widget _buildSubmissions(BuildContext context) {
    return AsyncStateView<List<Ad>>(
      state: _submissionsState,
      onRetry: _loadSubmissions,
      isEmpty: (data) => data.isEmpty,
      emptyTitle: 'No submissions yet',
      emptyMessage: 'Ads you submit will show here with their review status.',
      emptyIcon: Icons.campaign_outlined,
      builder: (context, ads) {
        return Column(
          children: [
            for (final ad in ads) ...[
              _SubmissionCard(ad: ad),
              const SizedBox(height: AppSpacing.md),
            ],
          ],
        );
      },
    );
  }
}

/// One row in the "Your submissions" list: banner thumbnail, advertiser and
/// headline, and a status pill (Pending / Approved / Rejected) using the same
/// colour language as the admin moderation queue.
class _SubmissionCard extends StatelessWidget {
  final Ad ad;

  const _SubmissionCard({required this.ad});

  (Color, Color) _statusColors(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final appColors = context.appColors;
    return switch (ad.status) {
      'pending' => (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer),
      'approved' => (appColors.success.withValues(alpha: 0.18), appColors.success),
      'rejected' => (colorScheme.errorContainer, colorScheme.onErrorContainer),
      _ => (colorScheme.surfaceContainerHighest, appColors.textSecondary),
    };
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final (bg, fg) = _statusColors(context);
    final label = ad.status.isEmpty
        ? 'Pending'
        : ad.status[0].toUpperCase() + ad.status.substring(1);

    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
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
                  style: textTheme.bodySmall?.copyWith(
                    color: context.appColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  ad.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                if (ad.status == 'approved')
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Live on the Home feed',
                      style: textTheme.bodySmall
                          ?.copyWith(color: context.appColors.success),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          StatusBadge(label: label, background: bg, foreground: fg),
        ],
      ),
    );
  }
}

/// A tap-to-pick date field styled like the app's inputs, with an optional
/// clear affordance once a date is set.
class _DateField extends StatelessWidget {
  final String label;
  final DateTime? date;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _DateField({
    required this.label,
    required this.date,
    required this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: textTheme.labelLarge),
        const SizedBox(height: AppSpacing.xs),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.input),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.md),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(AppRadius.input),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  date != null
                      ? '${date!.year}-${date!.month.toString().padLeft(2, '0')}-${date!.day.toString().padLeft(2, '0')}'
                      : 'Any time',
                  style: textTheme.bodyMedium?.copyWith(
                    color: date != null
                        ? colorScheme.onSurface
                        : context.appColors.textSecondary,
                  ),
                ),
                InkWell(
                  onTap: onClear ?? onTap,
                  child: Icon(
                    onClear != null ? Icons.close : Icons.calendar_today_outlined,
                    size: 18,
                    color: context.appColors.textSecondary,
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
