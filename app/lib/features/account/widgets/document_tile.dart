import 'package:flutter/material.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/document_opener.dart';
import '../../../core/widgets/app_card.dart';
import '../document_types.dart';

/// One verification document: what it is, the file sent for it (if any), and
/// Open / Replace / Remove -- or Upload while it is still missing.
///
/// Shared by the verification documents screen and the driver profile form,
/// so the same document looks and behaves the same in both places.
class DocumentTile extends StatelessWidget {
  final DocType type;
  final Map<String, dynamic>? document;
  final bool uploading;
  final void Function(DocType) onUpload;

  /// Null hides Remove: an approved driver may replace a document but not
  /// delete it (the server refuses once the account is verified).
  final void Function(Map<String, dynamic>)? onDelete;

  const DocumentTile({
    super.key,
    required this.type,
    required this.document,
    required this.uploading,
    required this.onUpload,
    this.onDelete,
  });

  String _sizeLabel(int bytes) {
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).round()} KB';
  }

  /// Item 9: let the applicant check what they actually uploaded. The file
  /// is fetched with their token -- these stay behind login -- and handed to
  /// the device, so a PDF opens in a real viewer.
  Future<void> _open(BuildContext context) async {
    final uploaded = document;
    if (uploaded == null) return;
    try {
      await DocumentOpener.open(
        path: '/users/documents/${uploaded['id']}/file',
        fileName: uploaded['file_name'] as String?,
        contentType: uploaded['content_type'] as String?,
      );
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final uploaded = document != null;
    final delete = onDelete;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: AppCard(
        child: Row(
          children: [
            AnimatedContainer(
              duration: AppMotion.medium,
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: uploaded
                    ? colors.success.withValues(alpha: 0.18)
                    : colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(AppRadius.input),
              ),
              alignment: Alignment.center,
              child: Icon(
                uploaded ? Icons.check_rounded : type.icon,
                color: uploaded ? colors.success : colors.textSecondary,
                size: 20,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    type.label,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    uploaded
                        ? '${document!['file_name']} · '
                            '${_sizeLabel((document!['size_bytes'] as num?)?.toInt() ?? 0)}'
                        : type.help,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: colors.textSecondary),
                  ),
                ],
              ),
            ),
            if (uploading)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            else if (uploaded)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: isPdfContentType(document!['content_type'] as String?)
                        ? 'Open PDF'
                        : 'Open',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _open(context),
                    icon: const Icon(Icons.open_in_new_rounded, size: 20),
                  ),
                  IconButton(
                    tooltip: 'Replace',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => onUpload(type),
                    icon: const Icon(Icons.upload_rounded, size: 20),
                  ),
                  if (delete != null)
                    IconButton(
                      tooltip: 'Remove',
                      visualDensity: VisualDensity.compact,
                      onPressed: () => delete(document!),
                      icon: Icon(Icons.delete_outline, size: 20, color: colorScheme.error),
                    ),
                ],
              )
            else
              FilledButton.tonal(
                onPressed: () => onUpload(type),
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                child: const Text('Upload'),
              ),
          ],
        ),
      ),
    );
  }
}
