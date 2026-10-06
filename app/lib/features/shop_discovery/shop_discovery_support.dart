import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/models/shop.dart';
import '../../core/theme/app_colors_extension.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/widgets/status_badge.dart';

// Shared helpers for the two shop-discovery screens (Member 2).
//
// Why this file exists: the shared `Shop` / `Product` / `ShopAlert` classes in
// core/models/shop.dart (maintained by another member) do not know about the
// newer backend fields (status, delivery, photos, stock status, alert type...).
// Rather than edit a shared file, this feature reads those extra fields from
// the same JSON itself. It also holds the offline cache (SRS REQ-SEARCH-5).

DateTime? _parseDate(Object? value) => value is String ? DateTime.tryParse(value) : null;

int _asInt(Object? value) => value is num ? value.toInt() : 0;

// --------------------------------------------------------------------------
// Models for the extra fields
// --------------------------------------------------------------------------

/// The fields of `ShopResponse` that the shared [Shop] class does not carry.
class ShopExtras {
  /// 'open', 'closed' or 'temporarily_closed'.
  final String status;
  final String? statusReason;
  final DateTime? reopenAt;
  final bool deliveryAvailable;
  final List<String> photos;
  final double trustScore;
  final int productCount;
  final int inStockCount;
  final int lowStockCount;
  final int outOfStockCount;

  /// 'none', 'all_in_stock', 'limited' or 'all_out'.
  final String availability;

  /// Set when the search text matched one of the shop's product names.
  final String? matchedProduct;

  const ShopExtras({
    required this.status,
    this.statusReason,
    this.reopenAt,
    required this.deliveryAvailable,
    required this.photos,
    required this.trustScore,
    required this.productCount,
    required this.inStockCount,
    required this.lowStockCount,
    required this.outOfStockCount,
    required this.availability,
    this.matchedProduct,
  });

  factory ShopExtras.fromJson(Map<String, dynamic> json) {
    final isOpen = json['is_open'] as bool? ?? false;
    final photos = (json['photos'] as List?)?.whereType<String>().toList() ?? <String>[];
    final imageUrl = json['image_url'] as String?;
    return ShopExtras(
      status: json['status'] as String? ?? (isOpen ? 'open' : 'closed'),
      statusReason: json['status_reason'] as String?,
      reopenAt: _parseDate(json['reopen_at']),
      deliveryAvailable: json['delivery_available'] as bool? ?? false,
      photos: photos.isNotEmpty ? photos : (imageUrl != null && imageUrl.isNotEmpty ? [imageUrl] : <String>[]),
      trustScore: (json['trust_score'] as num?)?.toDouble() ??
          (json['rating_avg'] as num?)?.toDouble() ??
          0,
      productCount: _asInt(json['product_count']),
      inStockCount: _asInt(json['in_stock_count']),
      lowStockCount: _asInt(json['low_stock_count']),
      outOfStockCount: _asInt(json['out_of_stock_count']),
      availability: json['availability'] as String? ?? 'none',
      matchedProduct: json['matched_product'] as String?,
    );
  }
}

/// A shop together with its extra fields and the raw JSON (kept for the cache).
class ShopEntry {
  final Shop shop;
  final ShopExtras extras;
  final Map<String, dynamic> raw;
  final double? _distanceOverride;

  const ShopEntry(this.shop, this.extras, this.raw, [this._distanceOverride]);

  factory ShopEntry.fromJson(Map<String, dynamic> json) {
    return ShopEntry(Shop.fromJson(json), ShopExtras.fromJson(json), json);
  }

  /// Distance in km: the server's value, or the one we worked out offline.
  double? get distanceKm => _distanceOverride ?? shop.distanceKm;

  ShopEntry withDistance(double? km) => ShopEntry(shop, extras, raw, km);
}

/// A product plus its three-level stock status.
class ProductEntry {
  final Product product;

  /// 'in_stock', 'low_stock' or 'out_of_stock'.
  final String stockStatus;

  const ProductEntry(this.product, this.stockStatus);

  factory ProductEntry.fromJson(Map<String, dynamic> json) {
    final product = Product.fromJson(json);
    return ProductEntry(
      product,
      json['stock_status'] as String? ?? (product.isAvailable ? 'in_stock' : 'out_of_stock'),
    );
  }
}

/// A shop alert with its type (closure / relocation / special offer).
class AlertEntry {
  final String id;
  final String message;
  final String type;
  final String? newAddress;
  final DateTime? endsAt;

  const AlertEntry({
    required this.id,
    required this.message,
    required this.type,
    this.newAddress,
    this.endsAt,
  });

  factory AlertEntry.fromJson(Map<String, dynamic> json) {
    return AlertEntry(
      id: json['id'] as String? ?? '',
      message: json['message'] as String? ?? '',
      type: json['alert_type'] as String? ?? 'general',
      newAddress: json['new_address'] as String?,
      endsAt: _parseDate(json['ends_at']),
    );
  }
}

/// A customer rating with an optional comment and owner reply.
class ReviewEntry {
  final String id;
  final int rating;
  final String comment;
  final String? ownerReply;
  final DateTime? createdAt;

  const ReviewEntry({
    required this.id,
    required this.rating,
    required this.comment,
    this.ownerReply,
    this.createdAt,
  });

  factory ReviewEntry.fromJson(Map<String, dynamic> json) {
    return ReviewEntry(
      id: json['id'] as String? ?? '',
      rating: _asInt(json['rating']),
      comment: json['comment'] as String? ?? '',
      ownerReply: json['owner_reply'] as String?,
      createdAt: _parseDate(json['created_at']),
    );
  }
}

// --------------------------------------------------------------------------
// Small pure helpers
// --------------------------------------------------------------------------

/// Straight-line distance in km between two points (used offline, when the
/// server cannot work it out for us).
double distanceBetweenKm(double lat1, double lng1, double lat2, double lng2) {
  double rad(double degrees) => degrees * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * 6371 * math.asin(math.sqrt(a));
}

String timeAgo(DateTime moment) {
  final diff = DateTime.now().difference(moment);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  if (diff.inHours < 24) return '${diff.inHours} h ago';
  final days = diff.inDays;
  return days == 1 ? '1 day ago' : '$days days ago';
}

String formatDateTime(DateTime moment) {
  final local = moment.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${local.day}/${local.month}/${local.year} $hh:$mm';
}

String stockLabel(String status, {int? quantity}) {
  switch (status) {
    case 'low_stock':
      return (quantity != null && quantity > 0) ? 'Low stock · $quantity left' : 'Low stock';
    case 'out_of_stock':
      return 'Out of stock';
    default:
      return 'In stock';
  }
}

Color stockColor(BuildContext context, String status) {
  final colors = context.appColors;
  switch (status) {
    case 'low_stock':
      return colors.warning;
    case 'out_of_stock':
      return Theme.of(context).colorScheme.error;
    default:
      return colors.success;
  }
}

String alertTypeLabel(String type) {
  switch (type) {
    case 'closure':
      return 'Closure notice';
    case 'relocation':
      return 'Relocation';
    case 'special_offer':
      return 'Special offer';
    default:
      return 'Notice';
  }
}

IconData alertTypeIcon(String type) {
  switch (type) {
    case 'closure':
      return Icons.block_outlined;
    case 'relocation':
      return Icons.edit_location_alt_outlined;
    case 'special_offer':
      return Icons.local_offer_outlined;
    default:
      return Icons.campaign_outlined;
  }
}

// --------------------------------------------------------------------------
// Offline cache (SRS REQ-SEARCH-5: cache shop data for up to 7 days)
// --------------------------------------------------------------------------

class CachedShops {
  final List<ShopEntry> entries;
  final DateTime? newestSave;

  const CachedShops(this.entries, this.newestSave);
}

class CachedDetail {
  final Map<String, dynamic> shop;
  final List<dynamic> products;
  final List<dynamic> alerts;
  final List<dynamic> reviews;
  final DateTime savedAt;

  const CachedDetail({
    required this.shop,
    required this.products,
    required this.alerts,
    required this.reviews,
    required this.savedAt,
  });
}

/// Saves shop profiles and shop pages on the phone so they can be browsed
/// without internet. Entries older than [maxAge] are ignored and removed.
///
/// What is stored: the JSON of each shop (name, address, phone, status, photo
/// links, trust score ...), plus the products / alerts / reviews of every shop
/// page the user opened. Photo files themselves are not stored - only their
/// links, so a photo shows offline only if Flutter still has it in memory.
class ShopCache {
  ShopCache._();

  static const Duration maxAge = Duration(days: 7);
  static const int _maxShops = 300;
  static const int _maxDetails = 60;
  static const String _profilesKey = 'microlink_shop_cache_profiles_v1';
  static const String _detailPrefix = 'microlink_shop_cache_detail_v1_';

  static bool _expired(int savedMs) =>
      DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(savedMs)) > maxAge;

  static Map<String, dynamic> _readProfiles(SharedPreferences prefs) {
    final text = prefs.getString(_profilesKey);
    if (text == null) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  /// Remember a list of shops returned by the server.
  static Future<void> saveShops(List<Map<String, dynamic>> shops) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final store = _readProfiles(prefs);
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final shop in shops) {
        final id = shop['id'];
        if (id is String) store[id] = {'saved': now, 'shop': shop};
      }
      store.removeWhere((_, value) => value is! Map || _expired(_asInt(value['saved'])));
      if (store.length > _maxShops) {
        final ids = store.keys.toList()
          ..sort((a, b) => _asInt((store[a] as Map)['saved']).compareTo(_asInt((store[b] as Map)['saved'])));
        for (final id in ids.take(store.length - _maxShops)) {
          store.remove(id);
        }
      }
      await prefs.setString(_profilesKey, jsonEncode(store));
    } catch (_) {
      // The cache is a bonus - never let it break the screen.
    }
  }

  /// Every cached shop that is younger than [maxAge].
  static Future<CachedShops> loadShops() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final store = _readProfiles(prefs);
      final entries = <ShopEntry>[];
      int newest = 0;
      for (final value in store.values) {
        if (value is! Map) continue;
        final saved = _asInt(value['saved']);
        if (_expired(saved)) continue;
        final raw = value['shop'];
        if (raw is! Map<String, dynamic>) continue;
        try {
          entries.add(ShopEntry.fromJson(raw));
          if (saved > newest) newest = saved;
        } catch (_) {
          // A damaged entry is skipped.
        }
      }
      return CachedShops(
        entries,
        newest == 0 ? null : DateTime.fromMillisecondsSinceEpoch(newest),
      );
    } catch (_) {
      return const CachedShops(<ShopEntry>[], null);
    }
  }

  /// Remember a full shop page (shop + products + alerts + reviews).
  static Future<void> saveDetail({
    required String shopId,
    required Map<String, dynamic> shop,
    required List<dynamic> products,
    required List<dynamic> alerts,
    required List<dynamic> reviews,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        '$_detailPrefix$shopId',
        jsonEncode({
          'saved': DateTime.now().millisecondsSinceEpoch,
          'shop': shop,
          'products': products,
          'alerts': alerts,
          'reviews': reviews,
        }),
      );
      await _pruneDetails(prefs);
    } catch (_) {
      // see saveShops
    }
  }

  static Future<void> _pruneDetails(SharedPreferences prefs) async {
    final keys = prefs.getKeys().where((k) => k.startsWith(_detailPrefix)).toList();
    final saved = <String, int>{};
    for (final key in keys) {
      var savedMs = 0;
      try {
        final decoded = jsonDecode(prefs.getString(key) ?? '{}');
        if (decoded is Map) savedMs = _asInt(decoded['saved']);
      } catch (_) {
        savedMs = 0;
      }
      if (savedMs == 0 || _expired(savedMs)) {
        await prefs.remove(key);
      } else {
        saved[key] = savedMs;
      }
    }
    if (saved.length > _maxDetails) {
      final oldestFirst = saved.keys.toList()..sort((a, b) => saved[a]!.compareTo(saved[b]!));
      for (final key in oldestFirst.take(saved.length - _maxDetails)) {
        await prefs.remove(key);
      }
    }
  }

  /// A cached shop page, or null when there is none (or it is too old).
  static Future<CachedDetail?> loadDetail(String shopId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString('$_detailPrefix$shopId');
      if (text == null) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final savedMs = _asInt(decoded['saved']);
      if (savedMs == 0 || _expired(savedMs)) {
        await prefs.remove('$_detailPrefix$shopId');
        return null;
      }
      final shop = decoded['shop'];
      if (shop is! Map<String, dynamic>) return null;
      return CachedDetail(
        shop: shop,
        products: decoded['products'] is List ? decoded['products'] as List : <dynamic>[],
        alerts: decoded['alerts'] is List ? decoded['alerts'] as List : <dynamic>[],
        reviews: decoded['reviews'] is List ? decoded['reviews'] as List : <dynamic>[],
        savedAt: DateTime.fromMillisecondsSinceEpoch(savedMs),
      );
    } catch (_) {
      return null;
    }
  }
}

// --------------------------------------------------------------------------
// Shared widgets
// --------------------------------------------------------------------------

/// "You are offline. Showing cached results." (SRS 5.3.2).
class OfflineBanner extends StatelessWidget {
  final DateTime? savedAt;

  const OfflineBanner({super.key, this.savedAt});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      color: colors.warning.withValues(alpha: 0.22),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.sm),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: colors.textSecondary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              savedAt == null
                  ? 'You are offline. Showing cached results.'
                  : 'You are offline. Showing cached results (saved ${timeAgo(savedAt!)}).',
              style: textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Open / Closed / Temporarily closed pill.
class ShopStatusBadge extends StatelessWidget {
  final String status;
  final String openLabel;

  const ShopStatusBadge({super.key, required this.status, this.openLabel = 'Open'});

  @override
  Widget build(BuildContext context) {
    switch (status) {
      case 'open':
        return StatusBadge.open(context, label: openLabel);
      case 'temporarily_closed':
        final warning = context.appColors.warning;
        return StatusBadge(
          label: 'Temporarily closed',
          background: warning.withValues(alpha: 0.2),
          foreground: Color.alphaBlend(Colors.black.withValues(alpha: 0.45), warning),
        );
      default:
        return StatusBadge.closed(context);
    }
  }
}

/// A coloured dot plus a short text such as "All items in stock" - the
/// "product availability indicator" of SRS REQ-SEARCH-4.
class AvailabilityIndicator extends StatelessWidget {
  final ShopExtras extras;

  const AvailabilityIndicator({super.key, required this.extras});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final error = Theme.of(context).colorScheme.error;
    late final String label;
    late final Color color;
    switch (extras.availability) {
      case 'all_in_stock':
        label = 'All ${extras.productCount} items in stock';
        color = colors.success;
        break;
      case 'limited':
        final parts = <String>[
          if (extras.lowStockCount > 0) '${extras.lowStockCount} low',
          if (extras.outOfStockCount > 0) '${extras.outOfStockCount} out',
        ];
        label = '${extras.productCount} items · ${parts.join(' · ')}';
        color = colors.warning;
        break;
      case 'all_out':
        label = 'All items out of stock';
        color = error;
        break;
      default:
        label = 'No items listed yet';
        color = colors.textSecondary;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}
