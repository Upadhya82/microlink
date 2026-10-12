import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';

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

/// The floating pill search bar used on top of a map, for jumping to any
/// town or landmark in Sri Lanka.
///
/// Backed by `GET /shops/landmark`, which geocodes through OpenStreetMap
/// restricted to Sri Lanka and falls back to a built-in list of well-known
/// places when the geocoder is slow or unreachable -- so this keeps working
/// on a poor rural connection, which is the point.
class AreaSearchField extends StatefulWidget {
  final String hintText;
  final ValueChanged<SearchedArea> onAreaSelected;

  /// Radius asked for when counting shops near the match.
  final double radiusKm;

  const AreaSearchField({
    super.key,
    required this.onAreaSelected,
    this.hintText = 'Search any area in Sri Lanka',
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

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
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
        // 404 is by far the likeliest failure here and the generic
        // "we could not find that" wording fits the rest too.
        _error = 'We could not find that place. Try a nearby town.';
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
                    onChanged: (_) {
                      if (_error != null) setState(() => _error = null);
                    },
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                    ),
                  ),
                ),
                if (_searching)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                else if (_controller.text.isNotEmpty)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () {
                      _controller.clear();
                      setState(() => _error = null);
                    },
                    child: Icon(Icons.close, size: 18, color: colors.textSecondary),
                  ),
              ],
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
