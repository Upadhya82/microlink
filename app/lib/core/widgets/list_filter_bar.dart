import 'package:flutter/material.dart';

import '../theme/app_spacing.dart';

/// One choice in a [ListFilterBar]: a value, its label, and (optionally) how
/// many items it would show.
class FilterOption<T> {
  final T value;
  final String label;
  final int? count;
  final IconData? icon;

  const FilterOption(this.value, this.label, {this.count, this.icon});
}

/// Whether [query] appears in any of [fields] (case-insensitive). An empty
/// query matches everything. Used by every list that has a search box.
bool matchesQuery(String query, Iterable<String?> fields) {
  final text = query.trim().toLowerCase();
  if (text.isEmpty) return true;
  for (final field in fields) {
    if (field != null && field.toLowerCase().contains(text)) return true;
  }
  return false;
}

/// How many of [items] fall under each filter value, for the chip counts.
Map<T, int> countBy<T, E>(Iterable<E> items, T Function(E item) keyOf) {
  final counts = <T, int>{};
  for (final item in items) {
    final key = keyOf(item);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return counts;
}

/// A search box and a row of filter chips, shown above a list.
///
/// Purely presentational: the screen keeps the selected value and the search
/// text, and filters its already-loaded list with them. Nothing is sent to the
/// server, so adding this to a screen changes nothing about how it loads.
/// Either part can be left out: pass no [options] for search only, or no
/// [onSearchChanged] for chips only.
class ListFilterBar<T> extends StatelessWidget {
  final List<FilterOption<T>> options;
  final T? selected;
  final ValueChanged<T>? onSelected;

  final TextEditingController? searchController;
  final ValueChanged<String>? onSearchChanged;
  final String searchHint;

  final EdgeInsetsGeometry padding;

  const ListFilterBar({
    super.key,
    this.options = const [],
    this.selected,
    this.onSelected,
    this.searchController,
    this.onSearchChanged,
    this.searchHint = 'Search',
    this.padding = const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.lg, 0),
  });

  @override
  Widget build(BuildContext context) {
    final hasSearch = onSearchChanged != null;
    final hasChips = options.isNotEmpty && onSelected != null;

    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasSearch)
            _SearchField(
              controller: searchController,
              hint: searchHint,
              onChanged: onSearchChanged!,
            ),
          if (hasSearch && hasChips) const SizedBox(height: AppSpacing.sm),
          if (hasChips)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final option in options)
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.sm),
                      child: ChoiceChip(
                        avatar: option.icon == null ? null : Icon(option.icon, size: 16),
                        label: Text(
                          option.count == null
                              ? option.label
                              : '${option.label} (${option.count})',
                        ),
                        selected: option.value == selected,
                        onSelected: (_) => onSelected!(option.value),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SearchField extends StatefulWidget {
  final TextEditingController? controller;
  final String hint;
  final ValueChanged<String> onChanged;

  const _SearchField({required this.controller, required this.hint, required this.onChanged});

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  TextEditingController? _own;
  TextEditingController get _controller => widget.controller ?? (_own ??= TextEditingController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: widget.hint,
        isDense: true,
        prefixIcon: const Icon(Icons.search),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, _) => value.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Clear',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _controller.clear();
                    widget.onChanged('');
                  },
                ),
        ),
      ),
      onChanged: widget.onChanged,
    );
  }
}

/// "All" plus one chip per distinct value in [values] (in first-seen order),
/// each with how many items have it. For filtering a list by a status or
/// type field whose possible values come from the data itself.
List<FilterOption<String>> valueFilterOptions(
  Iterable<String> values, {
  String Function(String value)? label,
  String allLabel = 'All',
}) {
  final list = values.toList();
  final counts = countBy(list, (String v) => v);
  return [
    FilterOption('all', allLabel, count: list.length),
    for (final value in counts.keys)
      if (value.isNotEmpty)
        FilterOption(value, label == null ? value : label(value), count: counts[value]),
  ];
}
