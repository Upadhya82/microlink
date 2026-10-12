import 'package:flutter/material.dart';

import '../../../core/models/shop.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_button.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/branded_app_bar.dart';

/// Lets a shopper pick the shop categories they care about and how far they're
/// willing to travel. These are the *explicit* signals recommendation-service
/// blends with a user's browsing/favourite history when ranking the
/// "Recommended for You" rail. Backed by `GET`/`PUT /users/me/preferences`,
/// where `preferred_categories` is stored as one comma-separated string.
/// Pops with `true` when something was saved, so the caller can refresh.
class InterestsScreen extends StatefulWidget {
  const InterestsScreen({super.key});

  @override
  State<InterestsScreen> createState() => _InterestsScreenState();
}

class _Preferences {
  final Set<String> categories;
  final double maxDistanceKm;

  const _Preferences({required this.categories, required this.maxDistanceKm});
}

class _InterestsScreenState extends State<InterestsScreen> {
  ViewState<_Preferences> _state = const ViewLoading();

  final Set<String> _selected = {};
  double _maxDistanceKm = 5;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final response =
          await ApiClient.instance.get('/users/me/preferences') as Map<String, dynamic>;
      final raw = (response['preferred_categories'] as String?) ?? '';
      final categories = raw
          .split(',')
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty && shopCategories.contains(c))
          .toSet();
      final distance = (response['max_distance_km'] as num?)?.toDouble() ?? 5;
      if (!mounted) return;
      setState(() {
        _selected
          ..clear()
          ..addAll(categories);
        _maxDistanceKm = distance.clamp(1, 50).toDouble();
        _state = ViewData(_Preferences(categories: categories, maxDistanceKm: _maxDistanceKm));
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load your interests.'));
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ApiClient.instance.put(
        '/users/me/preferences',
        body: {
          'preferred_categories': _selected.join(','),
          'max_distance_km': _maxDistanceKm,
        },
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Interests saved.')));
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      setState(() => _saving = false);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Could not save your interests.')));
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: BrandedAppBar(title: const Text('My Interests')),
      body: AsyncStateView<_Preferences>(
        state: _state,
        onRetry: _load,
        builder: (context, _) {
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              Text(
                'What are you shopping for?',
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Pick the categories you care about. We use these — along with '
                'the shops you browse and favourite — to rank “Recommended for You”.',
                style: textTheme.bodySmall?.copyWith(color: context.appColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: shopCategories.map((category) {
                  final selected = _selected.contains(category);
                  return FilterChip(
                    label: Text(formatCategoryLabel(category)),
                    selected: selected,
                    onSelected: (value) => setState(() {
                      value ? _selected.add(category) : _selected.remove(category);
                    }),
                  );
                }).toList(),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'How far will you travel?',
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${_maxDistanceKm.round()} km',
                style: textTheme.bodyMedium?.copyWith(color: context.appColors.textSecondary),
              ),
              Slider(
                value: _maxDistanceKm,
                min: 1,
                max: 50,
                divisions: 49,
                label: '${_maxDistanceKm.round()} km',
                onChanged: (value) => setState(() => _maxDistanceKm = value),
              ),
              const SizedBox(height: AppSpacing.xl),
              AppButton(
                label: 'Save',
                isLoading: _saving,
                onPressed: _saving ? null : _save,
              ),
            ],
          );
        },
      ),
    );
  }
}
