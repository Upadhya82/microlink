import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../theme/app_colors_extension.dart';
import '../theme/app_spacing.dart';

/// "Fields marked * are required." (item 5)
///
/// Goes at the top of every form, above the first field, so the asterisks
/// below it mean something. Before this, forms marked nothing and people
/// found out which fields mattered by being refused.
///
/// Translated (English and Sinhala) through [tr], like the rest of the form
/// copy.
class RequiredFieldsNote extends StatelessWidget {
  /// Space below the note. Zero when the caller lays out its own spacing.
  final double bottomSpacing;

  const RequiredFieldsNote({super.key, this.bottomSpacing = AppSpacing.md});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: bottomSpacing),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 14,
            color: context.appColors.textSecondary,
          ),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              tr('form.required_note'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: context.appColors.textSecondary,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
