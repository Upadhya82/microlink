import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/list_filter_bar.dart';

/// Admin tab: product categories.
///
/// Shop owners pick a product's category from a predefined list, or choose
/// "Others" and type one. Those typed categories wait here: the admin can add
/// one to the main list (its products move onto it) or dismiss it (the
/// products keep their text). Backed by shop-service's
/// `/shops/product-categories` endpoints.
class AdminProductCategoriesTab extends StatefulWidget {
  const AdminProductCategoriesTab({super.key});

  @override
  State<AdminProductCategoriesTab> createState() => _AdminProductCategoriesTabState();
}

class CategorySuggestion {
  final String name;
  final int productCount;
  final int shopCount;
  final List<String> examples;

  const CategorySuggestion({
    required this.name,
    required this.productCount,
    required this.shopCount,
    required this.examples,
  });

  factory CategorySuggestion.fromJson(Map<String, dynamic> json) => CategorySuggestion(
        name: json['name']?.toString() ?? '',
        productCount: (json['product_count'] as num?)?.toInt() ?? 0,
        shopCount: (json['shop_count'] as num?)?.toInt() ?? 0,
        examples: [
          for (final e in (json['example_products'] as List? ?? const [])) e.toString(),
        ],
      );
}

class _CategoriesData {
  final List<CategorySuggestion> suggestions;
  final List<String> labels;
  const _CategoriesData(this.suggestions, this.labels);
}

/// "pet food" -> "Pet food": a tidy default for the label box.
String suggestedLabel(String name) {
  final text = name.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (text.isEmpty) return text;
  return text[0].toUpperCase() + text.substring(1);
}

class _AdminProductCategoriesTabState extends State<AdminProductCategoriesTab>
    with AutomaticKeepAliveClientMixin {
  ViewState<_CategoriesData> _state = const ViewLoading();
  bool _busy = false;
  String _query = '';

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
      final results = await Future.wait([
        ApiClient.instance.get('/shops/product-categories/suggestions'),
        ApiClient.instance.get('/shops/product-categories'),
      ]);
      final suggestions = [
        for (final item in results[0] as List)
          CategorySuggestion.fromJson(item as Map<String, dynamic>),
      ];
      final labels = [
        for (final item in results[1] as List) (item as Map)['label'].toString(),
      ];
      if (!mounted) return;
      setState(() => _state = ViewData(_CategoriesData(suggestions, labels)));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load product categories.'));
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _add({CategorySuggestion? from}) async {
    final label = await showDialog<String>(
      context: context,
      builder: (_) => _CategoryNameDialog(
        title: from == null ? 'Add a category' : 'Add "${from.name}" to the list',
        initial: from == null ? '' : suggestedLabel(from.name),
        note: from == null
            ? null
            : 'Its ${from.productCount} product(s) will be moved into this category. '
                'You can tidy the name first.',
      ),
    );
    if (label == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final result = await ApiClient.instance.post(
        '/shops/product-categories',
        body: {
          'label': label,
          if (from != null) 'from_suggestion': from.name,
        },
      ) as Map;
      if (!mounted) return;
      final moved = (result['products_moved'] as num?)?.toInt() ?? 0;
      final existed = result['already_existed'] == true;
      _say(
        existed
            ? '"${from?.name}" is now filed under "${result['label']}" ($moved product(s) moved).'
            : from == null
                ? 'Added "${result['label']}".'
                : 'Added "${result['label']}". $moved product(s) moved into it.',
      );
      await _load();
    } on ApiException catch (e) {
      if (mounted) _say(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _dismiss(CategorySuggestion suggestion) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Dismiss "${suggestion.name}"?'),
        content: const Text(
          'It will not be added to the list. The products keep the category '
          'their owners typed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Dismiss'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ApiClient.instance.post(
        '/shops/product-categories/suggestions/dismiss',
        body: {'name': suggestion.name},
      );
      if (!mounted) return;
      _say('Dismissed "${suggestion.name}".');
      await _load();
    } on ApiException catch (e) {
      if (mounted) _say(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final textTheme = Theme.of(context).textTheme;
    final secondary = context.appColors.textSecondary;

    return RefreshIndicator(
      onRefresh: _load,
      child: AsyncStateView<_CategoriesData>(
        state: _state,
        onRetry: _load,
        builder: (context, all) {
          final data = _CategoriesData(
            [for (final s in all.suggestions) if (matchesQuery(_query, [s.name, ...s.examples])) s],
            [for (final l in all.labels) if (matchesQuery(_query, [l])) l],
          );
          return ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            if (_busy) const LinearProgressIndicator(),
            ListFilterBar<String>(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              searchHint: 'Search categories',
              onSearchChanged: (value) => setState(() => _query = value),
            ),
            Text(
              'Waiting for review (${data.suggestions.length})',
              style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              'Categories shop owners typed under "Others".',
              style: textTheme.bodySmall?.copyWith(color: secondary),
            ),
            const SizedBox(height: AppSpacing.md),
            if (data.suggestions.isEmpty)
              AppCard(
                child: Row(
                  children: [
                    Icon(Icons.check_circle_outline, color: context.appColors.success),
                    const SizedBox(width: AppSpacing.md),
                    const Expanded(child: Text('Nothing to review right now.')),
                  ],
                ),
              )
            else
              for (final suggestion in data.suggestions)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.md),
                  child: AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          suggestion.name,
                          style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Used by ${suggestion.productCount} product(s) in '
                          '${suggestion.shopCount} shop(s)',
                          style: textTheme.bodySmall?.copyWith(color: secondary),
                        ),
                        if (suggestion.examples.isNotEmpty)
                          Text(
                            'e.g. ${suggestion.examples.join(', ')}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodySmall?.copyWith(color: secondary),
                          ),
                        const SizedBox(height: AppSpacing.md),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _busy ? null : () => _dismiss(suggestion),
                                child: const Text('Dismiss'),
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              flex: 2,
                              child: FilledButton.icon(
                                onPressed: _busy ? null : () => _add(from: suggestion),
                                icon: const Icon(Icons.playlist_add, size: 18),
                                label: const Text('Add to categories'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            const SizedBox(height: AppSpacing.xl),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Main categories (${data.labels.length})',
                    style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : () => _add(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ],
            ),
            Text(
              'What shop owners choose from when they add a product.',
              style: textTheme.bodySmall?.copyWith(color: secondary),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [for (final label in data.labels) Chip(label: Text(label))],
            ),
          ],
          );
        },
      ),
    );
  }
}

/// Asks for a category name. Pops the trimmed name, or null.
class _CategoryNameDialog extends StatefulWidget {
  final String title;
  final String initial;
  final String? note;

  const _CategoryNameDialog({required this.title, required this.initial, this.note});

  @override
  State<_CategoryNameDialog> createState() => _CategoryNameDialogState();
}

class _CategoryNameDialogState extends State<_CategoryNameDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.pop(context, _controller.text.trim().replaceAll(RegExp(r'\s+'), ' '));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: _controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'Category name'),
              validator: (value) {
                final text = value?.trim() ?? '';
                if (text.length < 2) return 'Use at least 2 letters';
                if (text.length > 80) return 'Keep it under 80 letters';
                return null;
              },
              onFieldSubmitted: (_) => _submit(),
            ),
            if (widget.note != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                widget.note!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: context.appColors.textSecondary,
                    ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}
