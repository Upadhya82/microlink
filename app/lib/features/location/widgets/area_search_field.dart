import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/category_style.dart';

/// An area anywhere in Sri Lanka, resolved from a typed name.
/// Mirrors the `landmark` block of shop-service's `LandmarkSearchResponse`.
class SearchedArea {
  final String name;
  final double latitude;
  final double longitude;

  /// How many MicroLink shops are registered within the searched radius.
  final int shopCount;

  const SearchedArea({
    required this.name,
    required this.latitude,
    required this.longitude,
    required this.shopCount,
  });
}

/// One shop matching what has been typed, enough to list it and open it.
class ShopMatch {
  final String id;
  final String name;
  final String address;
  final String category;

  const ShopMatch({
    required this.id,
    required this.name,
    required this.address,
    required this.category,
  });

  factory ShopMatch.fromJson(Map<String, dynamic> json) => ShopMatch(
        id: json['id'] as String,
        name: json['name'] as String? ?? '',
        address: json['address'] as String? ?? '',
        category: json['category'] as String? ?? 'other',
      );
}

/// The floating pill search bar used on top of a map, for jumping to any
/// town or landmark in Sri Lanka.
///
/// It does two different jobs, because people type two different things
/// into one box:
///
/// * **Shops, as you type.** `GET /shops?q=` matches shop names, addresses,
///   categories and product names, so the matches appear underneath and
///   tapping one opens that shop's page. Without this the box could only
///   find places, and a search for a shop by name either returned "we could
///   not find that place" or -- worse -- quietly matched a town hiding
///   inside the name and moved the map somewhere unrelated. "diyagama
///   bakers" used to land on the town of Diyagama and list whatever was
///   near it, which looks like a result and is not one.
/// * **Places, on Enter.** `GET /shops/landmark` geocodes through
///   OpenStreetMap restricted to Sri Lanka and falls back to a built-in
///   list of well-known places when the geocoder is slow or unreachable --
///   so this keeps working on a poor rural connection, which is the point.
///
/// Enter is left meaning "go to this area" rather than "open the first
/// shop": `/shops?q=` matches addresses too, so pressing Enter on
/// "Homagama" would otherwise open some shop in Homagama instead of moving
/// the map there. Tapping is how you choose a shop; Enter is how you choose
/// an area.
class AreaSearchField extends StatefulWidget {
  final String hintText;
  final ValueChanged<SearchedArea> onAreaSelected;

  /// A shop was picked from the suggestions. The screen decides what that
  /// means -- the live map opens the shop's page.
  final ValueChanged<ShopMatch>? onShopSelected;

  /// Radius asked for when counting shops near the match.
  final double radiusKm;

  const AreaSearchField({
    super.key,
    required this.onAreaSelected,
    this.onShopSelected,
    this.hintText = 'Search a shop or any area in Sri Lanka',
    this.radiusKm = 5,
  });

  @override
  State<AreaSearchField> createState() => _AreaSearchFieldState();
}

class _AreaSearchFieldState extends State<AreaSearchField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  bool _searching = false;
  String? _error;

  List<ShopMatch> _matches = const [];
  bool _matching = false;
  Timer? _debounce;

  /// Guards against an earlier, slower request overwriting the matches for
  /// what is being typed now.
  int _requestId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// Look for shops a short moment after typing stops. A request per
  /// keystroke would be several a second on a name like "thusitha", most of
  /// them already stale before they land.
  void _onChanged(String value) {
    if (_error != null) setState(() => _error = null);
    _debounce?.cancel();

    final query = value.trim();
    if (query.length < 2) {
      setState(() {
        _matches = const [];
        _matching = false;
      });
      return;
    }

    setState(() => _matching = true);
    _debounce = Timer(const Duration(milliseconds: 300), () => _findShops(query));
  }

  Future<void> _findShops(String query) async {
    final id = ++_requestId;
    try {
      final response = await ApiClient.instance.get(
        '/shops',
        query: {'q': query, 'limit': 6},
      );
      if (!mounted || id != _requestId) return;
      final rows = response as List;
      setState(() {
        _matches = rows
            .map((e) => ShopMatch.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        _matching = false;
      });
    } catch (_) {
      if (!mounted || id != _requestId) return;
      // Suggestions are a convenience: a failure here leaves the box usable
      // for the area search rather than putting an error in the way.
      setState(() {
        _matches = const [];
        _matching = false;
      });
    }
  }

  void _openShop(ShopMatch shop) {
    _focusNode.unfocus();
    setState(() => _matches = const []);
    widget.onShopSelected?.call(shop);
  }

  void _clear() {
    _debounce?.cancel();
    _controller.clear();
    setState(() {
      _error = null;
      _matches = const [];
      _matching = false;
    });
  }

  Future<void> _search() async {
    final query = _controller.text.trim();
    // The backend requires at least 2 characters; say so before spending a
    // request on it.
    if (query.length < 2) {
      setState(() => _error = 'Type at least 2 characters.');
      return;
    }

    _focusNode.unfocus();
    setState(() {
      _searching = true;
      _error = null;
    });

    try {
      final response = await ApiClient.instance.get(
        '/shops/landmark',
        query: {'landmark': query, 'radius_km': widget.radiusKm},
      );
      final map = Map<String, dynamic>.from(response as Map);
      final landmark = Map<String, dynamic>.from(map['landmark'] as Map);
      final shops = map['shops'] as List? ?? const [];
      if (!mounted) return;
      setState(() => _searching = false);
      widget.onAreaSelected(
        SearchedArea(
          name: landmark['name'] as String? ?? query,
          latitude: (landmark['latitude'] as num).toDouble(),
          longitude: (landmark['longitude'] as num).toDouble(),
          shopCount: shops.length,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        // 404 is by far the likeliest failure here. The wording names both
        // things the box can do, because "try a nearby town" was baffling
        // advice to somebody who had just typed a shop's name.
        _error = _matches.isEmpty
            ? 'No shop or place found for that. Try a shop name, or a nearby town.'
            : 'That is not a place -- tap one of the shops below instead.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final colors = context.appColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: colorScheme.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          elevation: 3,
          shadowColor: Colors.black.withValues(alpha: 0.15),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              children: [
                Icon(Icons.search, size: 20, color: colors.textSecondary),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    onChanged: _onChanged,
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                    ),
                  ),
                ),
                if (_searching || _matching)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                else if (_controller.text.isNotEmpty)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _clear,
                    child: Icon(Icons.close, size: 18, color: colors.textSecondary),
                  ),
              ],
            ),
          ),
        ),
        if (_matches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Material(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(AppRadius.input),
              elevation: 3,
              shadowColor: Colors.black.withValues(alpha: 0.15),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _matches.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
                itemBuilder: (context, index) {
                  final shop = _matches[index];
                  final style = categoryStyle(context, shop.category);
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                      radius: 16,
                      backgroundColor: style.container,
                      child: Icon(
                        categoryIcon(shop.category),
                        size: 17,
                        color: style.onContainer,
                      ),
                    ),
                    title: Text(
                      shop.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      shop.address.isEmpty
                          ? categoryLabel(shop.category)
                          : shop.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: colors.textSecondary),
                    ),
                    onTap: () => _openShop(shop),
                  );
                },
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.sm),
            child: Material(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(AppRadius.input),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: colorScheme.onErrorContainer, fontSize: 13),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
