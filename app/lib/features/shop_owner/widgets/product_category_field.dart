import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/app_text_field.dart';

/// One predefined product category (shop-service `GET /shops/product-categories`).
class ProductCategoryOption {
  final String slug;
  final String label;
  const ProductCategoryOption(this.slug, this.label);
}

/// How category names are compared: case, spacing and punctuation ignored.
/// Mirrors shop-service's `name_key`.
String categoryNameKey(String? text) => (text ?? '')
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

/// The predefined category [text] names (by slug or label), or null when it
/// is an "Others" category the owner typed.
String? matchCategoryOption(String? text, List<ProductCategoryOption> options) {
  final key = categoryNameKey(text);
  if (key.isEmpty) return null;
  for (final option in options) {
    if (key == categoryNameKey(option.slug) || key == categoryNameKey(option.label)) {
      return option.slug;
    }
  }
  return null;
}

/// The product form's category: a list of predefined categories plus
/// "Others", which opens a box to type a new one. An admin reviews what is
/// typed there and can add it to the list.
///
/// Writes the value to send into [controller] -- a predefined category's slug,
/// or the typed text -- so the form submits `controller.text` exactly as it
/// did when this was a plain text box. If the list cannot be loaded it falls
/// back to that plain text box, so adding a product never gets stuck.
class ProductCategoryField extends StatefulWidget {
  final TextEditingController controller;

  const ProductCategoryField({super.key, required this.controller});

  @override
  State<ProductCategoryField> createState() => _ProductCategoryFieldState();
}

class _ProductCategoryFieldState extends State<ProductCategoryField> {
  static const String _other = '__other__';

  List<ProductCategoryOption>? _options;
  bool _failed = false;
  String? _choice;
  late final TextEditingController _otherController;

  @override
  void initState() {
    super.initState();
    _otherController = TextEditingController();
    _load();
  }

  @override
  void dispose() {
    _otherController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final response = await ApiClient.instance.get('/shops/product-categories') as List;
      final options = [
        for (final item in response)
          ProductCategoryOption(
            (item as Map)['slug'].toString(),
            item['label'].toString(),
          ),
      ];
      if (!mounted) return;
      final current = widget.controller.text.trim();
      final matched = matchCategoryOption(current, options);
      setState(() {
        _options = options;
        if (matched != null) {
          _choice = matched;
          widget.controller.text = matched;
        } else if (current.isNotEmpty) {
          // An existing product with a category that is not on the list.
          _choice = _other;
          _otherController.text = current;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      // The list could not be loaded: the plain text box this used to be.
      return AppTextField(
        controller: widget.controller,
        label: 'Category',
        isRequired: true,
        validator: (v) => Validators.required(v, field: 'Category'),
      );
    }
    final options = _options;
    if (options == null) {
      return InputDecorator(
        decoration: InputDecoration(labelText: requiredLabel('Category')),
        child: const SizedBox(
          height: 20,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          initialValue: _choice,
          isExpanded: true,
          menuMaxHeight: 420,
          decoration: InputDecoration(labelText: requiredLabel('Category')),
          hint: const Text('Choose a category'),
          items: [
            for (final option in options)
              DropdownMenuItem(value: option.slug, child: Text(option.label)),
            const DropdownMenuItem(value: _other, child: Text('Others (not on the list)')),
          ],
          validator: (value) => value == null ? 'Category is required' : null,
          onChanged: (value) => setState(() {
            _choice = value;
            widget.controller.text =
                value == _other ? _otherController.text.trim() : (value ?? '');
          }),
        ),
        if (_choice == _other) ...[
          const SizedBox(height: AppSpacing.md),
          AppTextField(
            controller: _otherController,
            label: 'Your category',
            isRequired: true,
            onChanged: (value) => widget.controller.text = value.trim(),
            validator: (value) {
              final text = value?.trim() ?? '';
              if (text.isEmpty) return 'Type the category';
              if (text.length < 2) return 'Use at least 2 letters';
              return null;
            },
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'An admin will review it and may add it to the list for everyone.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: context.appColors.textSecondary,
                ),
          ),
        ],
      ],
    );
  }
}
