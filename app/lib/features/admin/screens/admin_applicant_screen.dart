import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/branded_app_bar.dart';
import '../../../core/widgets/status_badge.dart';
import '../../account/document_types.dart';
import '../widgets/admin_document_preview.dart';

/// One shop owner or delivery agent application, as the admin reviews it.
///
/// The Users tab used to put a Verify button straight on each card, so an
/// account could be approved without the admin ever opening the documents,
/// and there was no way to turn one down. Here the profile, the documents
/// (with a checklist of what the role must supply) and, for an agent, the
/// vehicle all come first; Verify and Reject sit at the bottom, after them.
///
/// Pops with a short message describing the decision, or null when the
/// admin backed out without deciding.
class AdminApplicantScreen extends StatefulWidget {
  /// The account as `GET /users` returned it.
  final Map<String, dynamic> user;

  const AdminApplicantScreen({super.key, required this.user});

  @override
  State<AdminApplicantScreen> createState() => _AdminApplicantScreenState();
}

class _AdminApplicantScreenState extends State<AdminApplicantScreen> {
  ViewState<List<Map<String, dynamic>>> _documents = const ViewLoading();

  /// The agent's delivery profile. Null while loading or for a shop owner;
  /// [_agentProfileMissing] says when an agent never filled one in.
  Map<String, dynamic>? _agentProfile;
  bool _agentProfileMissing = false;

  /// 'verify' or 'reject' while that request is in flight.
  String? _deciding;

  Map<String, dynamic> get _user => widget.user;
  String get _id => _user['id'].toString();
  String get _role => _user['role']?.toString() ?? '';
  String get _name => _user['full_name']?.toString() ?? 'This applicant';
  bool get _isAgent => _role == 'delivery_agent';
  bool get _isVerified => _user['is_verified'] == true;
  String get _roleLabel => _isAgent ? 'delivery agent' : 'shop owner';

  String? get _rejectionReason {
    final reason = _user['rejection_reason']?.toString().trim();
    return reason == null || reason.isEmpty ? null : reason;
  }

  @override
  void initState() {
    super.initState();
    _loadDocuments();
    if (_isAgent) _loadAgentProfile();
  }

  Future<void> _loadDocuments() async {
    setState(() => _documents = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/users/$_id/documents');
      final rows = (response as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (!mounted) return;
      setState(() => _documents = ViewData(rows));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _documents = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _documents = const ViewError('Could not load the documents.'));
    }
  }

  /// Vehicle and phone live in delivery-service, not with the account.
  /// Best effort: the documents are what the decision rests on.
  Future<void> _loadAgentProfile() async {
    try {
      final response = await ApiClient.instance.get('/delivery/agents/$_id');
      if (!mounted) return;
      setState(() => _agentProfile = Map<String, dynamic>.from(response as Map));
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.isNotFound) setState(() => _agentProfileMissing = true);
    } catch (_) {
      // Leave the vehicle section saying it is still loading-free and empty.
    }
  }

  List<String> get _requiredDocs => kRequiredDocsByRole[_role] ?? const <String>[];

  /// Required document types this applicant has not uploaded.
  List<String> _missing(List<Map<String, dynamic>> documents) {
    final uploaded = documents.map((d) => d['doc_type']?.toString()).toSet();
    return _requiredDocs.where((t) => !uploaded.contains(t)).toList();
  }

  /// Records the same decision on the agent's delivery profile, so its
  /// application status matches the account. Best effort: what lets an
  /// agent work is the account's verified flag, which has already been set.
  Future<void> _recordAgentReview(String decision, {String? reason}) async {
    if (!_isAgent) return;
    try {
      await ApiClient.instance.patch(
        '/delivery/agents/$_id/review',
        body: {'decision': decision, 'reason': ?reason},
      );
    } catch (_) {
      // A missing delivery profile must not undo the account decision.
    }
  }

  Future<void> _verify() async {
    final documents = _documents is ViewData<List<Map<String, dynamic>>>
        ? (_documents as ViewData<List<Map<String, dynamic>>>).data
        : const <Map<String, dynamic>>[];
    final missing = _missing(documents);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Verify $_name?'),
        content: Text(
          missing.isEmpty
              ? 'They will be approved as a $_roleLabel and told '
                  '"Congratulations! You are verified" when they next sign in.'
              : 'Still missing: ${missing.map((v) => docTypeFor(v).label).join(', ')}.\n\n'
                  'Verify anyway? They will be approved as a $_roleLabel.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Verify'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deciding = 'verify');
    try {
      await ApiClient.instance.patch('/users/$_id/verify');
      await _recordAgentReview('approved');
      if (!mounted) return;
      Navigator.pop(context, '$_name has been verified. They have been sent a congratulations message.');
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _deciding = null);
    }
  }

  Future<void> _reject() async {
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => _RejectDialog(name: _name),
    );
    if (reason == null || !mounted) return;

    setState(() => _deciding = 'reject');
    try {
      await ApiClient.instance.patch('/users/$_id/reject', body: {'reason': reason});
      await _recordAgentReview('rejected', reason: reason);
      if (!mounted) return;
      Navigator.pop(context, '$_name was rejected. They have been told the reason.');
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _deciding = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;

    return Scaffold(
      appBar: BrandedAppBar(title: const Text('Review applicant')),
      bottomNavigationBar: _isVerified ? null : _buildDecisionBar(context),
      body: RefreshIndicator(
        onRefresh: _loadDocuments,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            _buildProfileCard(context),
            if (_rejectionReason != null && !_isVerified) ...[
              const SizedBox(height: AppSpacing.md),
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(AppRadius.input),
                ),
                child: Text(
                  'Rejected before. Reason given: $_rejectionReason',
                  style: textTheme.bodySmall?.copyWith(color: colorScheme.onErrorContainer),
                ),
              ),
            ],
            if (_isAgent) ...[
              const SizedBox(height: AppSpacing.lg),
              Text('Vehicle', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: AppSpacing.sm),
              _buildVehicleCard(context),
            ],
            const SizedBox(height: AppSpacing.lg),
            Text('Documents', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Each document is shown under its name. Tap a picture to zoom in, and check every one before deciding.',
              style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.sm),
            _buildDocuments(context),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileCard(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final created = DateTime.tryParse(_user['created_at']?.toString() ?? '');
    final phone = _user['phone']?.toString();
    final business = _user['business_name']?.toString();

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: colorScheme.primaryContainer,
                child: Icon(
                  _isAgent ? Icons.local_shipping_outlined : Icons.storefront_outlined,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_name, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: AppSpacing.xs),
                    StatusBadge(
                      label: _isVerified ? 'Verified' : 'Pending review',
                      background: _isVerified
                          ? context.appColors.success.withValues(alpha: 0.18)
                          : colorScheme.secondaryContainer,
                      foreground: _isVerified
                          ? context.appColors.success
                          : colorScheme.onSecondaryContainer,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _InfoLine(icon: Icons.badge_outlined, label: 'Account type', value: _isAgent ? 'Delivery agent' : 'Shop owner'),
          if (business != null && business.isNotEmpty)
            _InfoLine(icon: Icons.store_mall_directory_outlined, label: 'Business name', value: business),
          _InfoLine(icon: Icons.email_outlined, label: 'Email', value: _user['email']?.toString() ?? '-'),
          _InfoLine(
            icon: Icons.phone_outlined,
            label: 'Phone',
            value: phone == null || phone.isEmpty ? 'Not given' : phone,
          ),
          if (created != null)
            _InfoLine(icon: Icons.event_outlined, label: 'Applied', value: _formatDate(created)),
        ],
      ),
    );
  }

  Widget _buildVehicleCard(BuildContext context) {
    final profile = _agentProfile;
    if (profile == null) {
      return AppCard(
        child: Text(
          _agentProfileMissing ? 'No vehicle details submitted yet.' : 'Loading vehicle details…',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    final plate = profile['license_plate']?.toString();
    final phone = profile['phone']?.toString();
    final vehicle = profile['vehicle_type']?.toString() ?? '-';
    return AppCard(
      child: Column(
        children: [
          _InfoLine(
            icon: Icons.two_wheeler_outlined,
            label: 'Vehicle',
            value: vehicle.isEmpty ? '-' : vehicle[0].toUpperCase() + vehicle.substring(1),
          ),
          _InfoLine(
            icon: Icons.pin_outlined,
            label: 'Licence plate',
            value: plate == null || plate.isEmpty ? 'Not given' : plate,
          ),
          if (phone != null && phone.isNotEmpty)
            _InfoLine(icon: Icons.phone_android_outlined, label: 'Driver phone', value: phone),
        ],
      ),
    );
  }

  Widget _buildDocuments(BuildContext context) {
    final state = _documents;

    return switch (state) {
      ViewLoading() => const Padding(
          padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
          child: Center(child: CircularProgressIndicator()),
        ),
      ViewError(:final message) => AppCard(
          child: Row(
            children: [
              Expanded(child: Text(message)),
              TextButton(onPressed: _loadDocuments, child: const Text('Retry')),
            ],
          ),
        ),
      ViewData(:final data) => ApplicantDocumentsSection(
          requiredTypes: _requiredDocs,
          documents: data,
        ),
    };
  }

  Widget _buildDecisionBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final busy = _deciding != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : _reject,
                style: OutlinedButton.styleFrom(
                  foregroundColor: colorScheme.error,
                  side: BorderSide(color: colorScheme.error),
                  minimumSize: const Size.fromHeight(48),
                ),
                icon: _deciding == 'reject'
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.close_rounded, size: 18),
                label: const Text('Reject'),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : _verify,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                icon: _deciding == 'verify'
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.verified_outlined, size: 18),
                label: const Text('Verify'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime time) {
    final local = time.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }
}

class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoLine({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: context.appColors.textSecondary),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 104,
            child: Text(label, style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary)),
          ),
          Expanded(child: Text(value, style: textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// Asks why the application is being turned down. The applicant is shown
/// this reason, so it is required -- the server refuses an empty one too.
class _RejectDialog extends StatefulWidget {
  final String name;

  const _RejectDialog({required this.name});

  @override
  State<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends State<_RejectDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Reject ${widget.name}?'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('They will be told this reason, so say what is wrong with the documents.'),
            const SizedBox(height: AppSpacing.md),
            TextFormField(
              controller: _controller,
              autofocus: true,
              maxLength: 300,
              maxLines: 3,
              minLines: 2,
              decoration: const InputDecoration(
                labelText: 'Reason',
                hintText: 'e.g. The NIC photo is blurred. Please upload a clear copy.',
              ),
              validator: (value) =>
                  (value ?? '').trim().length < 3 ? 'Please give a reason.' : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: () {
            if (_formKey.currentState?.validate() ?? false) {
              Navigator.pop(context, _controller.text.trim());
            }
          },
          child: const Text('Reject'),
        ),
      ],
    );
  }
}


/// The applicant's documents, one card per type: the heading (with whether
/// it arrived), what it should show, and the document itself underneath at
/// a size the admin can read. Every type the role must supply gets a card
/// even when it is missing, so a gap cannot hide; anything else they
/// uploaded follows under "Other documents".
class ApplicantDocumentsSection extends StatelessWidget {
  /// Document types the role must supply, in the order to show them.
  final List<String> requiredTypes;

  /// Rows from `GET /users/{id}/documents`.
  final List<Map<String, dynamic>> documents;

  const ApplicantDocumentsSection({
    super.key,
    required this.requiredTypes,
    required this.documents,
  });

  Map<String, dynamic>? _documentOf(String type) =>
      documents.where((d) => d['doc_type']?.toString() == type).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final others = documents
        .where((d) => !requiredTypes.contains(d['doc_type']?.toString()))
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final type in requiredTypes) ...[
          _DocumentCard(type: type, document: _documentOf(type)),
          const SizedBox(height: AppSpacing.md),
        ],
        if (others.isNotEmpty) ...[
          Text('Other documents',
              style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.sm),
          for (final document in others) ...[
            _DocumentCard(type: document['doc_type']?.toString() ?? '', document: document),
            const SizedBox(height: AppSpacing.md),
          ],
        ],
      ],
    );
  }
}

class _DocumentCard extends StatelessWidget {
  final String type;
  final Map<String, dynamic>? document;

  const _DocumentCard({required this.type, required this.document});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final known = kAllDocTypes.where((t) => t.value == type).firstOrNull;
    final label = known?.label ?? type.replaceAll('_', ' ');
    final uploaded = document != null;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(known?.icon ?? Icons.description_outlined, color: colorScheme.primary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(label,
                    style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              ),
              StatusBadge(
                label: uploaded ? 'Uploaded' : 'Missing',
                background: uploaded
                    ? colors.success.withValues(alpha: 0.18)
                    : colorScheme.errorContainer,
                foreground: uploaded ? colors.success : colorScheme.onErrorContainer,
              ),
            ],
          ),
          if (known != null) ...[
            const SizedBox(height: 2),
            Text(known.help, style: textTheme.bodySmall?.copyWith(color: colors.textSecondary)),
          ],
          const SizedBox(height: AppSpacing.sm),
          if (uploaded)
            AdminDocumentPreview(document: document!)
          else
            Container(
              height: 90,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.input),
                border: Border.all(color: colorScheme.error.withValues(alpha: 0.5)),
              ),
              child: Text('Not uploaded',
                  style: textTheme.bodyMedium?.copyWith(color: colorScheme.error)),
            ),
        ],
      ),
    );
  }
}
