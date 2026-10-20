import 'package:flutter/material.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/document_opener.dart';
import '../../../core/utils/media_url.dart';
import '../../account/document_types.dart';

/// One verification document as the admin sees it: a thumbnail (or a PDF
/// icon), what it is, and a way to open it full size.
///
/// Shared by the Users tab and the Applicants queue, so the admin can read
/// the documents wherever they are asked to approve someone.
class AdminDocumentRow extends StatelessWidget {
  final Map<String, dynamic> document;

  const AdminDocumentRow({super.key, required this.document});

  /// Item 9: fetch the file with the admin's token and let the device open
  /// it. This row used to say "PDF preview is not available in the app",
  /// which left the admin unable to read the very documents they are being
  /// asked to approve.
  Future<void> _open(BuildContext context) async {
    try {
      await DocumentOpener.open(
        path: '/users/documents/${document['id']}/file',
        fileName: document['file_name'] as String?,
        contentType: document['content_type'] as String?,
      );
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  String get _label {
    final value = document['doc_type'] as String? ?? '';
    return kAllDocTypes.where((t) => t.value == value).firstOrNull?.label ??
        value.replaceAll('_', ' ');
  }

  @override
  Widget build(BuildContext context) {
    final isPdf = isPdfContentType(document['content_type'] as String?);
    final url = mediaUrl('/users/documents/${document['id']}/file');
    final fileName = document['file_name'] as String?;

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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_label, style: Theme.of(context).textTheme.bodyMedium),
                if (fileName != null && fileName.isNotEmpty)
                  Text(
                    fileName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: context.appColors.textSecondary),
                  ),
              ],
            ),
          ),
          // A PDF has nothing to show in a dialog, so it is opened in the
          // device's own viewer instead.
          if (isPdf)
            IconButton(
              tooltip: 'Open PDF',
              visualDensity: VisualDensity.compact,
              onPressed: () => _open(context),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
            )
          else
            IconButton(
              tooltip: 'Open full size',
              visualDensity: VisualDensity.compact,
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => Dialog(
                  child: InteractiveViewer(
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
