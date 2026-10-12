import 'package:flutter/material.dart';

import '../network/multipart_upload.dart';
import '../theme/app_colors_extension.dart';
import '../theme/app_spacing.dart';

/// Pick one photo to upload, with a thumbnail of what was chosen.
///
/// Replaces the "Image URL" boxes that used to be scattered across the app.
/// Asking someone to paste a public link to a photo of their own shop front
/// is asking them to host it somewhere first, which nobody standing in a
/// shop with a phone is going to do.
///
/// The file is held in memory and uploaded by the caller once the record it
/// belongs to exists, so a failed upload never loses the typed-in form.
class PhotoPickerField extends StatelessWidget {
  final PickedFile? file;
  final String label;
  final String hint;
  final bool enabled;
  final ValueChanged<PickedFile?> onChanged;

  const PhotoPickerField({
    super.key,
    required this.file,
    required this.onChanged,
    this.label = 'Photo',
    this.hint = 'JPG, PNG or WebP, up to 8MB',
    this.enabled = true,
  });

  Future<void> _pick(BuildContext context) async {
    try {
      final picked = await MultipartUpload.pick();
      if (picked != null) onChanged(picked);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is Exception ? '$e'.replaceFirst('Exception: ', '') : 'Could not read that file.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;
    final chosen = file;

    return Material(
      color: colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(AppRadius.input),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.input),
        onTap: enabled ? () => _pick(context) : null,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Row(
            children: [
              if (chosen == null)
                Icon(Icons.add_a_photo_outlined, color: colors.textSecondary)
              else
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  child: Image.memory(
                    chosen.bytes,
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        const Icon(Icons.broken_image_outlined, size: 44),
                  ),
                ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      chosen == null
                          ? hint
                          : '${chosen.name} (${(chosen.sizeBytes / 1024).round()} KB)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.labelSmall?.copyWith(color: colors.textSecondary),
                    ),
                  ],
                ),
              ),
              if (chosen == null)
                Text(
                  'Choose',
                  style: textTheme.labelMedium?.copyWith(color: colorScheme.primary),
                )
              else
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close, size: 18),
                  onPressed: enabled ? () => onChanged(null) : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
