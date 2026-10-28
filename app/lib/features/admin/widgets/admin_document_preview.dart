import 'package:flutter/material.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/document_opener.dart';
import '../../../core/utils/media_url.dart';

/// A verification document shown large enough to actually check.
///
/// [AdminDocumentRow] gives a 44px thumbnail, which is fine in a queue but
/// not for reading a national ID number off a photo. On the applicant
/// review screen each document sits under its own heading at full width;
/// tapping an image opens it full screen with pinch-zoom, and a PDF (which
/// has no picture to show) gets a button that opens it in the device's
/// viewer.
class AdminDocumentPreview extends StatelessWidget {
  final Map<String, dynamic> document;

  const AdminDocumentPreview({super.key, required this.document});

  static const double previewHeight = 220;

  String get _path => '/users/documents/${document['id']}/file';

  Future<void> _openPdf(BuildContext context) async {
    try {
      await DocumentOpener.open(
        path: _path,
        fileName: document['file_name'] as String?,
        contentType: document['content_type'] as String?,
      );
    } on ApiException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  void _openFullScreen(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(AppSpacing.md),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            InteractiveViewer(
              maxScale: 6,
              child: Center(child: Image.network(url, headers: authImageHeaders())),
            ),
            Positioned(
              top: AppSpacing.xs,
              right: AppSpacing.xs,
              child: IconButton.filledTonal(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(dialogContext),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// "smoke_doc.png · 245 KB · 2026-10-18" -- what the file is and when it came.
  String get _caption {
    final parts = <String>[];
    final name = document['file_name'] as String?;
    if (name != null && name.isNotEmpty) parts.add(name);
    final size = document['size_bytes'];
    if (size is num && size > 0) {
      parts.add(size >= 1024 * 1024
          ? '${(size / (1024 * 1024)).toStringAsFixed(1)} MB'
          : '${(size / 1024).ceil()} KB');
    }
    final created = DateTime.tryParse(document['created_at']?.toString() ?? '');
    if (created != null) {
      final local = created.toLocal();
      parts.add('${local.year}-${local.month.toString().padLeft(2, '0')}-'
          '${local.day.toString().padLeft(2, '0')}');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    final isPdf = isPdfContentType(document['content_type'] as String?);
    final url = mediaUrl(_path)!;
    final radius = BorderRadius.circular(AppRadius.input);

    final Widget preview;
    if (isPdf) {
      preview = Container(
        height: 120,
        decoration: BoxDecoration(color: colorScheme.surfaceContainerHighest, borderRadius: radius),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.picture_as_pdf_rounded, size: 40, color: colorScheme.error),
              const SizedBox(height: AppSpacing.sm),
              FilledButton.tonalIcon(
                onPressed: () => _openPdf(context),
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('Open PDF'),
              ),
            ],
          ),
        ),
      );
    } else {
      preview = Material(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _openFullScreen(context, url),
          child: SizedBox(
            height: previewHeight,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // contain, not cover: cropping an ID card hides the very
                // details the admin is checking.
                Image.network(
                  url,
                  headers: authImageHeaders(),
                  fit: BoxFit.contain,
                  loadingBuilder: (context, child, progress) => progress == null
                      ? child
                      : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  errorBuilder: (_, _, _) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.broken_image_outlined, size: 36, color: colors.textSecondary),
                        const SizedBox(height: AppSpacing.xs),
                        Text('Could not load this image', style: textTheme.bodySmall),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  right: AppSpacing.sm,
                  bottom: AppSpacing.sm,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.55),
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.zoom_in_rounded, size: 16, color: Colors.white),
                        SizedBox(width: 4),
                        Text('Tap to zoom', style: TextStyle(color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        preview,
        if (_caption.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xs),
          Text(
            _caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
        ],
      ],
    );
  }
}
