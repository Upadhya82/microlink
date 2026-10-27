import 'package:flutter/material.dart';

import '../../../core/models/shop.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/category_style.dart';
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/list_filter_bar.dart';
import '../../../core/widgets/shop_filters.dart';
import '../../../core/widgets/shop_preview_card.dart';
import '../../../core/widgets/skeleton_list.dart';
import '../../../core/widgets/branded_app_bar.dart';

/// The user's saved shops, backed by the real `/recommendations/*/favorite`
/// endpoints (a proper toggle, unlike the old local-only heart button).
/// There's no "list shops by id" endpoint on shop-service, so this fetches
/// each favorited shop's detail individually -- fine at favorites-list
/// scale; a dedicated bulk endpoint would only be worth it if lists grew
/// large.
class MyFavoritesScreen extends StatefulWidget {
  const MyFavoritesScreen({super.key});

  @override
  State<MyFavoritesScreen> createState() => _MyFavoritesScreenState();
}

class _MyFavoritesScreenState extends State<MyFavoritesScreen> {
  ViewState<List<Shop>> _state = const ViewLoading();
  String _filter = 'all';
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _state = const ViewLoading());
    try {
      final favoritesResponse = await ApiClient.instance.get('/recommendations/favorites/me');
      final shopIds = (favoritesResponse as List)
          .map((e) => (e as Map<String, dynamic>)['shop_id'] as String)
          .toList();

      final shops = <Shop>[];
      for (final result in await Future.wait(
        shopIds.map((id) => ApiClient.instance.get('/shops/$id').catchError((_) => null)),
      )) {
        if (result is Map<String, dynamic>) {
          shops.add(Shop.fromJson(result));
        }
        // A null result means that shop was deleted since being favorited --
        // silently skipped rather than shown as an error for the whole list.
      }

      if (!mounted) return;
      setState(() => _state = ViewData(shops));
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _state = ViewError(e.message));
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Could not load your favorites.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: BrandedAppBar(title: const Text('My Favorites')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: AsyncStateView<List<Shop>>(
          state: _state,
          onRetry: _load,
          isEmpty: (data) => data.isEmpty,
          emptyTitle: 'No favorites yet',
          emptyMessage: 'Tap the heart on any shop\'s page to save it here.',
          emptyIcon: Icons.favorite_border,
          loadingSkeleton: const SkeletonList(),
          builder: (context, allShops) {
            final shops = filterShops(allShops, filter: _filter, query: _query);
            return Column(
              children: [
                ListFilterBar<String>(
                  searchHint: 'Search your favorites',
                  onSearchChanged: (value) => setState(() => _query = value),
                  options: shopFilterOptions(allShops),
                  selected: _filter,
                  onSelected: (value) => setState(() => _filter = value),
                ),
                if (shops.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(AppSpacing.xl),
                    child: Text('No favorites match this filter.'),
                  ),
                Expanded(
                  child: GridView.builder(
            padding: const EdgeInsets.all(AppSpacing.lg),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              mainAxisSpacing: AppSpacing.md,
              crossAxisSpacing: AppSpacing.md,
              childAspectRatio: 190 / 246,
            ),
            itemCount: shops.length,
            itemBuilder: (context, index) {
              final shop = shops[index];
              return ShopPreviewCard(
                shop: shop,
                categoryIconFor: categoryIcon(shop.category),
                categoryTint: categoryColors(context, shop.category),
              );
            },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
