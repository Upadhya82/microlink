import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/multipart_upload.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../../../core/widgets/stagger_in.dart';
import '../document_types.dart';
import '../widgets/document_tile.dart';
import '../../../core/widgets/branded_app_bar.dart';

/// Upload the documents an admin needs before approving a shop owner or
/// delivery agent (REQ-AGENT-1, REQ-ADMIN-1/2).
class VerificationDocumentsScreen extends StatefulWidget {
  const VerificationDocumentsScreen({super.key});

  @override
  State<VerificationDocumentsScreen> createState() =>
      _VerificationDocumentsScreenState();
}

class _VerificationDocumentsScreenState extends State<VerificationDocumentsScreen> {
  ViewState<List<Map<String, dynamic>>> _state = const ViewLoading();
  final Set<String> _uploading = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final response = await ApiClient.instance.get('/users/me/documents');
      final rows = (response as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (!mounted) return;
      setState(() => _state = ViewData(rows));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load your documents.'));
    }
  }

  Future<void> _upload(DocType type) async {
    setState(() => _uploading.add(type.value));
    try {
      final picked = await MultipartUpload.pick(
        allowedExtensions: MultipartUpload.documentExtensions,
      );
      if (picked == null) return;
      await MultipartUpload.send(
        path: '/users/me/documents',
        file: picked,
        fields: {'doc_type': type.value},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${type.label} uploaded')),
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Could not upload that file.')));
    } finally {
      if (mounted) setState(() => _uploading.remove(type.value));
    }
  }

  Future<void> _delete(Map<String, dynamic> document) async {
    try {
      await ApiClient.instance.delete('/users/me/documents/${document['id']}');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Hand the application over and sign out.
  ///
  /// There is nothing useful an unapproved owner or agent can do in the app,
  /// and REQ-AUTH-4 blocks them at login anyway -- leaving them on a dead
  /// home screen would just look broken.
  Future<void> _submitForReview() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    await SessionManager.instance.clearSession();
    messenger.showSnackBar(
      const SnackBar(
        content: Text(
          'Documents submitted. We will let you know once an admin has '
          'reviewed your account.',
        ),
        duration: Duration(seconds: 6),
      ),
    );
    navigator.pushNamedAndRemoveUntil(AppRoutes.login, (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final role = SessionManager.instance.userRole ?? 'user';
    final required = kRequiredDocsByRole[role] ?? const <String>[];
    final optional =
        kAllDocTypes.where((t) => !required.contains(t.value)).map((t) => t.value).toList();

    return Scaffold(
      appBar: BrandedAppBar(title: const Text('Verification documents')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: AsyncStateView<List<Map<String, dynamic>>>(
          state: _state,
          onRetry: _load,
          loadingSkeleton: const SkeletonList(itemCount: 4),
          builder: (context, documents) {
            final byType = {
              for (final d in documents) d['doc_type'] as String? ?? '': d,
            };
            final outstanding =
                required.where((t) => !byType.containsKey(t)).length;

            return ListView(
              padding: const EdgeInsets.all(AppSpacing.lg),
              children: [
                StaggerIn(index: 0, child: _StatusBanner(outstanding: outstanding)),
                const SizedBox(height: AppSpacing.lg),
                if (required.isNotEmpty) ...[
                  Text(
                    'Required for your role',
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  for (var i = 0; i < required.length; i++)
                    StaggerIn(
                      index: i + 1,
                      child: DocumentTile(
                        type: docTypeFor(required[i]),
                        document: byType[required[i]],
                        uploading: _uploading.contains(required[i]),
                        onUpload: _upload,
                        onDelete: _delete,
                      ),
                    ),
                ],
                const SizedBox(height: AppSpacing.lg),
                Text(
                  'Other documents',
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: AppSpacing.sm),
                for (final value in optional)
                  DocumentTile(
                    type: docTypeFor(value),
                    document: byType[value],
                    uploading: _uploading.contains(value),
                    onUpload: _upload,
                    onDelete: _delete,
                  ),
                if (required.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xl),
                  FilledButton.icon(
                    // Enabled only once everything required is in: submitting
                    // an incomplete application just wastes the admin's time
                    // and the applicant's.
                    onPressed: outstanding == 0 ? _submitForReview : null,
                    icon: const Icon(Icons.send_rounded, size: 18),
                    label: const Text('Submit for review'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    outstanding == 0
                        ? 'You will be signed out until an admin approves your account.'
                        : 'Upload everything above to submit.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: context.appColors.textSecondary),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final int outstanding;

  const _StatusBanner({required this.outstanding});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final verified = SessionManager.instance.userRole != null &&
        outstanding == 0;
    final background =
        verified ? colorScheme.primaryContainer : colorScheme.secondaryContainer;
    final foreground =
        verified ? colorScheme.onPrimaryContainer : colorScheme.onSecondaryContainer;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppRadius.card),
      ),
      child: Row(
        children: [
          Icon(
            verified ? Icons.task_alt_rounded : Icons.pending_actions_rounded,
            color: foreground,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              verified
                  ? 'All required documents uploaded. An admin will review them shortly.'
                  : '$outstanding document${outstanding == 1 ? '' : 's'} still needed before '
                      'an admin can approve your account.',
              style: TextStyle(color: foreground, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
