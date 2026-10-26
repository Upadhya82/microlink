import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/media_url.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/models/shop.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/app_router.dart';
import '../../../core/utils/category_style.dart' show categoryIcon;
import '../../../core/utils/view_state.dart';
import '../../../core/widgets/app_card.dart';
import '../../../core/widgets/async_state_view.dart';
import '../../../core/widgets/rating_chip.dart';
import '../../orders/cart_controller.dart';
import '../../../core/widgets/status_badge.dart';
import '../shop_discovery_support.dart';
import '../widgets/shop_confirmation_card.dart';
import '../../../core/widgets/branded_app_bar.dart';

/// Everything the Shop Detail screen needs, loaded together so the whole
/// screen shares one loading / error state.
class _ShopDetailData {
  final ShopEntry shop;
  final List<ProductEntry> products;
  final List<AlertEntry> alerts;
  final List<ReviewEntry> reviews;

  /// null when the data is fresh from the server; otherwise the time it was
  /// saved on the phone (the screen is then in offline mode).
  final DateTime? cachedAt;

  const _ShopDetailData({
    required this.shop,
    required this.products,
    required this.alerts,
    required this.reviews,
    this.cachedAt,
  });
}

class _RatingResult {
  final int rating;
  final String comment;

  const _RatingResult(this.rating, this.comment);
}

/// The Shop Detail screen (SRS REQ-SEARCH-4): name, address, contact number,
/// photos, operational status, product availability and community trust
/// score, plus alerts and customer reviews. A shop page the user has opened
/// before can be shown again offline from the 7-day cache (REQ-SEARCH-5).
class ShopDetailScreen extends StatefulWidget {
  final String shopId;

  const ShopDetailScreen({super.key, required this.shopId});

  @override
  State<ShopDetailScreen> createState() => _ShopDetailScreenState();
}

class _ShopDetailScreenState extends State<ShopDetailScreen> {
  ViewState<_ShopDetailData> _state = const ViewLoading();

  bool _isFavorite = false;
  bool _togglingFavorite = false;
  String _stockFilter = 'all'; // all | in_stock | low_stock | out_of_stock

  @override
  void initState() {
    super.initState();
    _fetchAll();
    _fetchFavoriteStatus();
  }

  /// Whether this shop is already in the signed-in user's favourites. There is
  /// no single "is this shop favourited" endpoint, so this checks the shop id
  /// against the user's favourites list.
  Future<void> _fetchFavoriteStatus() async {
    if (!SessionManager.instance.isLoggedIn) return;
    try {
      final response = await ApiClient.instance.get('/recommendations/favorites/me');
      final isFavorited = (response as List)
          .any((e) => (e as Map<String, dynamic>)['shop_id'] == widget.shopId);
      if (!mounted) return;
      setState(() => _isFavorite = isFavorited);
    } catch (_) {
      // Non-fatal: the heart just starts unfilled if this fails.
    }
  }

  Future<void> _fetchAll() async {
    setState(() => _state = const ViewLoading());
    try {
      final results = await Future.wait<dynamic>([
        ApiClient.instance.get('/shops/${widget.shopId}'),
        ApiClient.instance.get('/shops/${widget.shopId}/products'),
        ApiClient.instance.get('/shops/${widget.shopId}/alerts'),
        // Reviews are a bonus section - a failure must not hide the shop.
        ApiClient.instance.get('/shops/${widget.shopId}/reviews').catchError((_) => <dynamic>[]),
      ]);

      final shopJson = results[0] as Map<String, dynamic>;
      final productsJson = results[1] as List;
      final alertsJson = results[2] as List;
      final reviewsJson = results[3] is List ? results[3] as List : <dynamic>[];

      final data = _parse(shopJson, productsJson, alertsJson, reviewsJson, null);
      unawaited(ShopCache.saveDetail(
        shopId: widget.shopId,
        shop: shopJson,
        products: productsJson,
        alerts: alertsJson,
        reviews: reviewsJson,
      ));

      if (!mounted) return;
      setState(() => _state = ViewData(data));
      _logView(data.shop.shop);
    } on ApiException catch (e) {
      if (e.isNetworkError) {
        await _loadFromCache(e.message);
      } else {
        if (!mounted) return;
        setState(() => _state = ViewError(e.message));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _state = const ViewError('Something went wrong. Please try again.'));
    }
  }

  _ShopDetailData _parse(
    Map<String, dynamic> shopJson,
    List<dynamic> productsJson,
    List<dynamic> alertsJson,
    List<dynamic> reviewsJson,
    DateTime? cachedAt,
  ) {
    return _ShopDetailData(
      shop: ShopEntry.fromJson(shopJson),
      products: productsJson
          .map((e) => ProductEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      alerts: alertsJson.map((e) => AlertEntry.fromJson(e as Map<String, dynamic>)).toList(),
      reviews: reviewsJson.map((e) => ReviewEntry.fromJson(e as Map<String, dynamic>)).toList(),
      cachedAt: cachedAt,
    );
  }

  Future<void> _loadFromCache(String networkMessage) async {
    final cached = await ShopCache.loadDetail(widget.shopId);
    if (!mounted) return;
    if (cached == null) {
      setState(() => _state = ViewError(
            '$networkMessage\nThis shop has not been saved for offline use yet. '
            'Open it once while online and it will be available offline for 7 days.',
          ));
      return;
    }
    try {
      final data = _parse(cached.shop, cached.products, cached.alerts, cached.reviews, cached.savedAt);
      setState(() => _state = ViewData(data));
    } catch (_) {
      setState(() => _state = ViewError(networkMessage));
    }
  }

  void _logView(Shop shop) {
    final session = SessionManager.instance;
    if (!session.isLoggedIn) return;
    if (session.userId == shop.ownerId) return;
    // Fire-and-forget interaction signal - never block or surface failures.
    ApiClient.instance.post(
      '/recommendations/interactions',
      body: {'shop_id': shop.id, 'interaction_type': 'view'},
    ).catchError((_) => null);
  }

  void _openDirections(Shop shop) {
    Navigator.pushNamed(
      context,
      AppRoutes.liveMap,
      arguments: LiveMapArgs(
        destinationLat: shop.latitude,
        destinationLng: shop.longitude,
        destinationLabel: shop.name,
      ),
    );
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _copyPhone(String phone) async {
    await Clipboard.setData(ClipboardData(text: phone));
    if (!mounted) return;
    _showMessage('Phone number copied');
  }

  Future<void> _toggleFavorite() async {
    if (_togglingFavorite) return;
    if (!SessionManager.instance.isLoggedIn) {
      _showMessage('Please log in to save favourites.');
      return;
    }
    final wasFavorite = _isFavorite;
    setState(() {
      _isFavorite = !wasFavorite;
      _togglingFavorite = true;
    });
    try {
      if (wasFavorite) {
        await ApiClient.instance.delete('/recommendations/${widget.shopId}/favorite');
      } else {
        await ApiClient.instance.post('/recommendations/${widget.shopId}/favorite');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isFavorite = wasFavorite);
      _showMessage('Could not update your favourites. Please try again.');
    } finally {
      if (mounted) setState(() => _togglingFavorite = false);
    }
  }

  Future<void> _rateShop() async {
    if (!SessionManager.instance.isLoggedIn) {
      _showMessage('Please log in to rate this shop.');
      return;
    }
    final result = await showModalBottomSheet<_RatingResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _RateSheet(),
    );
    if (result == null) return;
    try {
      await ApiClient.instance.post(
        '/shops/${widget.shopId}/rating',
        body: {'rating': result.rating, 'comment': result.comment},
      );
      if (!mounted) return;
      _showMessage('Thanks for rating this shop!');
      await _fetchAll();
    } on ApiException catch (e) {
      if (!mounted) return;
      _showMessage(e.message);
    }
  }

  Future<void> _replyToReview(ReviewEntry review) async {
    final text = await showDialog<String>(
      context: context,
      builder: (_) => const _ReplyDialog(),
    );
    if (text == null || text.isEmpty) return;
    try {
      await ApiClient.instance.post(
        '/shops/${widget.shopId}/reviews/${review.id}/reply',
        body: {'reply': text},
      );
      if (!mounted) return;
      await _fetchAll();
    } on ApiException catch (e) {
      if (!mounted) return;
      _showMessage(e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      bottomNavigationBar: _CartBar(shopId: widget.shopId),
      extendBodyBehindAppBar: true,
      appBar: BrandedAppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: Padding(
          padding: const EdgeInsets.only(left: AppSpacing.md),
          child: _CircleIconButton(
            icon: Icons.arrow_back,
            onTap: () => Navigator.pop(context),
          ),
        ),
        actions: [
          if (_state case ViewData<_ShopDetailData>())
            Padding(
              padding: const EdgeInsets.only(right: AppSpacing.md),
              child: _CircleIconButton(
                icon: _isFavorite ? Icons.favorite : Icons.favorite_border,
                iconColor: _isFavorite ? Theme.of(context).colorScheme.error : null,
                onTap: _toggleFavorite,
              ),
            ),
        ],
      ),
      body: AsyncStateView<_ShopDetailData>(
        state: _state,
        onRetry: _fetchAll,
        builder: (context, data) => _ShopDetailBody(
          data: data,
          stockFilter: _stockFilter,
          onStockFilterChanged: (value) => setState(() => _stockFilter = value),
          onDirections: () => _openDirections(data.shop.shop),
          onCopyPhone: _copyPhone,
          onRate: _rateShop,
          onReply: _replyToReview,
          onReload: _fetchAll,
        ),
      ),
    );
  }
}

/// A small circular icon button overlaid on the hero (back / favourite).
class _CircleIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? iconColor;

  const _CircleIconButton({required this.icon, required this.onTap, this.iconColor});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.92),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(icon, size: 18, color: iconColor ?? Theme.of(context).colorScheme.onSurface),
        ),
      ),
    );
  }
}

class _ShopDetailBody extends StatelessWidget {
  final _ShopDetailData data;
  final String stockFilter;
  final ValueChanged<String> onStockFilterChanged;
  final VoidCallback onDirections;
  final ValueChanged<String> onCopyPhone;
  final VoidCallback onRate;
  final ValueChanged<ReviewEntry> onReply;

  /// Reloads the page. Used when a confirmation verifies the shop, so the
  /// "not verified" chip and the confirmation card both go away at once.
  final Future<void> Function() onReload;

  const _ShopDetailBody({
    required this.data,
    required this.stockFilter,
    required this.onStockFilterChanged,
    required this.onDirections,
    required this.onCopyPhone,
    required this.onRate,
    required this.onReply,
    required this.onReload,
  });

  @override
  Widget build(BuildContext context) {
    final shop = data.shop.shop;
    final extras = data.shop.extras;
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    final colorScheme = Theme.of(context).colorScheme;
    final session = SessionManager.instance;
    final isOwner = session.userId == shop.ownerId;
    final offline = data.cachedAt != null;
    final canRate = !offline && session.isLoggedIn && !isOwner;
    final hasPhone = shop.phone != null && shop.phone!.isNotEmpty;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PhotoHero(photos: extras.photos, category: shop.category),
          if (offline) OfflineBanner(savedAt: data.cachedAt),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            shop.name,
                            style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            formatCategoryLabel(shop.category),
                            style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    ShopStatusBadge(status: extras.status, openLabel: 'Open now'),
                  ],
                ),
                if (extras.status != 'open' &&
                    ((extras.statusReason != null && extras.statusReason!.isNotEmpty) ||
                        extras.reopenAt != null)) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, size: 16, color: colors.textSecondary),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          [
                            if (extras.statusReason != null && extras.statusReason!.isNotEmpty)
                              extras.statusReason!,
                            if (extras.reopenAt != null)
                              'Expected to re-open ${formatDateTime(extras.reopenAt!)}',
                          ].join(' · '),
                          style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.lg,
                  runSpacing: AppSpacing.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (shop.ratingCount > 0)
                      RatingChip(
                        rating: extras.trustScore,
                        count: shop.ratingCount,
                        iconSize: 15,
                        textStyle: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
                      )
                    else
                      Text(
                        'No ratings yet',
                        style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                      ),
                    if (extras.showsNotVerifiedChip) const NotVerifiedChip(),
                    if (extras.delayProne)
                      OftenDelayedChip(
                        medianPickupWaitMin: extras.medianPickupWaitMin,
                      ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.access_time_rounded, size: 16, color: colors.textSecondary),
                        const SizedBox(width: 4),
                        Text(
                          '${shop.openingTime} – ${shop.closingTime}',
                          style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                        ),
                      ],
                    ),
                    if (extras.deliveryAvailable)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.delivery_dining_outlined, size: 18, color: colors.success),
                          const SizedBox(width: 4),
                          Text(
                            'Delivery available',
                            style: textTheme.bodySmall?.copyWith(
                              color: colors.success,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
                // An unverified shop no admin has reached yet: the customers
                // near it can verify it themselves. Hidden offline, where
                // the confirmation could not be sent, and hidden from the
                // owner, who is not allowed to vouch for their own shop.
                if (!offline && !isOwner && extras.acceptsConfirmations) ...[
                  const SizedBox(height: AppSpacing.md),
                  ShopConfirmationCard(
                    shopId: shop.id,
                    shopName: shop.name,
                    confirmations: extras.communityConfirmations,
                    required: extras.confirmationsRequired,
                    onVerified: onReload,
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.place_outlined, size: 18, color: colors.textSecondary),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        shop.address.isEmpty ? 'No address on file' : shop.address,
                        style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
                      ),
                    ),
                  ],
                ),
                if (hasPhone) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Row(
                    children: [
                      Icon(Icons.call_outlined, size: 18, color: colors.textSecondary),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          shop.phone!,
                          style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Copy number',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        onPressed: () => onCopyPhone(shop.phone!),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: onDirections,
                        icon: const Icon(Icons.near_me_outlined, size: 18),
                        label: const Text('Directions'),
                      ),
                    ),
                    if (canRate) ...[
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: onRate,
                          icon: const Icon(Icons.star_outline_rounded, size: 18),
                          label: const Text('Rate shop'),
                        ),
                      ),
                    ],
                  ],
                ),
                if (shop.description.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    shop.description,
                    style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary, height: 1.4),
                  ),
                ],
                if (data.alerts.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xl),
                  Text('Alerts', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: AppSpacing.sm),
                  ...data.alerts.map((alert) => _AlertCard(alert: alert)),
                ],
                const SizedBox(height: AppSpacing.xl),
                _ProductsSection(
                  shop: data.shop.shop,
                  products: data.products,
                  stockFilter: stockFilter,
                  onFilterChanged: onStockFilterChanged,
                ),
                const SizedBox(height: AppSpacing.xl),
                Text(
                  'Ratings & reviews',
                  style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: AppSpacing.sm),
                if (data.reviews.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    child: Text(
                      'No reviews yet.',
                      style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
                    ),
                  )
                else ...[
                  Text(
                    'Trust score is the average of ratings from the last 90 days.',
                    style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  for (final review in data.reviews.take(_reviewsShownAtFirst))
                    _ReviewTile(
                      review: review,
                      canReply: !offline && isOwner && (review.ownerReply == null),
                      onReply: () => onReply(review),
                    ),
                  // Item 3: the page used to stop at eight with no way to
                  // see the rest, which looked like the shop had only eight.
                  if (data.reviews.length > _reviewsShownAtFirst)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => _showAllReviews(
                          context,
                          reviews: data.reviews,
                          isOwner: isOwner,
                          offline: offline,
                          onReply: onReply,
                        ),
                        child: Text(
                          'See all ${data.reviews.length} reviews',
                        ),
                      ),
                    ),
                ],
                if (isOwner) ...[
                  const SizedBox(height: AppSpacing.xl),
                  AppCard(
                    onTap: () => Navigator.pushNamed(context, AppRoutes.shopOwnerDashboard),
                    child: Row(
                      children: [
                        Icon(Icons.storefront, color: colorScheme.primary),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            'You own this shop — manage it from your dashboard',
                            style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                          ),
                        ),
                        Icon(Icons.chevron_right, color: colors.textSecondary),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ==========================================================================
// Hero (photo carousel)
// ==========================================================================

/// The banner at the top: a swipeable carousel when the shop has photos,
/// otherwise a gradient with the category icon.
class _PhotoHero extends StatefulWidget {
  final List<String> photos;
  final String category;

  const _PhotoHero({required this.photos, required this.category});

  @override
  State<_PhotoHero> createState() => _PhotoHeroState();
}

class _PhotoHeroState extends State<_PhotoHero> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _fallback(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primary,
            Color.alphaBlend(Colors.black.withValues(alpha: 0.25), colorScheme.primary),
          ],
        ),
      ),
      alignment: Alignment.bottomCenter,
      child: Icon(
        categoryIcon(widget.category),
        size: 96,
        color: colorScheme.onPrimary.withValues(alpha: 0.35),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    const contentHeight = 210.0;
    final photos = widget.photos;

    return ClipRect(
      child: SizedBox(
        height: topPadding + contentHeight,
        width: double.infinity,
        child: Stack(
          children: [
            Positioned.fill(
              child: photos.isEmpty
                  ? _fallback(context)
                  : PageView.builder(
                      controller: _controller,
                      itemCount: photos.length,
                      onPageChanged: (index) => setState(() => _page = index),
                      itemBuilder: (context, index) => Image.network(
                        mediaUrl(photos[index]) ?? photos[index],
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => _fallback(context),
                      ),
                    ),
            ),
            if (photos.length > 1)
              Positioned(
                left: 0,
                right: 0,
                bottom: 10,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < photos.length; i++)
                      Container(
                        width: i == _page ? 18 : 7,
                        height: 7,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: i == _page ? 0.95 : 0.55),
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                      ),
                  ],
                ),
              ),
            if (photos.length > 1)
              Positioned(
                right: 12,
                bottom: 26,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    '${_page + 1}/${photos.length}',
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ==========================================================================
// Alerts
// ==========================================================================

class _AlertCard extends StatelessWidget {
  final AlertEntry alert;

  const _AlertCard({required this.alert});

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Container(
        decoration: BoxDecoration(
          color: colors.warning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: colors.warning.withValues(alpha: 0.4)),
        ),
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(alertTypeIcon(alert.type), color: colors.warning),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alertTypeLabel(alert.type),
                    style: textTheme.labelMedium?.copyWith(
                      color: colors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    alert.message,
                    style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                  ),
                  if (alert.newAddress != null && alert.newAddress!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      'New address: ${alert.newAddress}',
                      style: textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                  if (alert.endsAt != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Until ${formatDateTime(alert.endsAt!)}',
                      style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==========================================================================
// Products and availability
// ==========================================================================

class _ProductsSection extends StatelessWidget {
  final Shop shop;
  final List<ProductEntry> products;
  final String stockFilter;
  final ValueChanged<String> onFilterChanged;

  const _ProductsSection({
    required this.shop,
    required this.products,
    required this.stockFilter,
    required this.onFilterChanged,
  });

  int _count(String status) => products.where((p) => p.stockStatus == status).length;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;

    final visible = stockFilter == 'all'
        ? products
        : products.where((p) => p.stockStatus == stockFilter).toList();

    Widget filterChip(String value, String label) {
      return ChoiceChip(
        label: Text(label),
        selected: stockFilter == value,
        onSelected: (_) => onFilterChanged(value),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Products', style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        if (products.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Text(
              'This shop hasn\'t listed any products yet.',
              style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
            ),
          )
        else ...[
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              _StockSummary(label: 'In stock', count: _count('in_stock'), status: 'in_stock'),
              const SizedBox(width: AppSpacing.lg),
              _StockSummary(label: 'Low', count: _count('low_stock'), status: 'low_stock'),
              const SizedBox(width: AppSpacing.lg),
              _StockSummary(label: 'Out', count: _count('out_of_stock'), status: 'out_of_stock'),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            children: [
              filterChip('all', 'All (${products.length})'),
              filterChip('in_stock', 'In stock'),
              filterChip('low_stock', 'Low stock'),
              filterChip('out_of_stock', 'Out of stock'),
            ],
          ),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Text(
                'No products with this status.',
                style: textTheme.bodyMedium?.copyWith(color: colors.textSecondary),
              ),
            )
          else
            Column(
              children: [
                for (var i = 0; i < visible.length; i++)
                  _ProductRow(
                    shop: shop,
                    entry: visible[i],
                    showDivider: i != visible.length - 1,
                  ),
              ],
            ),
        ],
      ],
    );
  }
}

class _StockSummary extends StatelessWidget {
  final String label;
  final int count;
  final String status;

  const _StockSummary({required this.label, required this.count, required this.status});

  @override
  Widget build(BuildContext context) {
    final color = stockColor(context, status);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          '$label $count',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class _ProductRow extends StatelessWidget {
  final Shop shop;
  final ProductEntry entry;
  final bool showDivider;

  const _ProductRow({
    required this.shop,
    required this.entry,
    required this.showDivider,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final product = entry.product;
    final color = stockColor(context, entry.stockStatus);
    final soldOut = entry.stockStatus == 'out_of_stock';

    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      decoration: BoxDecoration(
        border: showDivider ? Border(bottom: BorderSide(color: colorScheme.outlineVariant)) : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _ProductThumbnail(product: product, soldOut: soldOut),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  product.name,
                  style: textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: soldOut ? context.appColors.textSecondary : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (product.description.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    product.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: context.appColors.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      stockLabel(
                        entry.stockStatus,
                        quantity: entry.stockStatus == 'low_stock' ? product.stockQuantity : null,
                      ),
                      style: textTheme.bodySmall?.copyWith(color: color, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (product.hasDiscount)
                Text(
                  'Rs. ${product.price.toStringAsFixed(2)}',
                  style: textTheme.labelSmall?.copyWith(
                    color: context.appColors.textSecondary,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
              Text(
                'Rs. ${product.finalPrice.toStringAsFixed(2)}',
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: product.hasDiscount ? context.appColors.success : null,
                ),
              ),
              if (product.hasDiscount)
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: context.appColors.success,
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Text(
                    '-${product.discountPercent}%',
                    style: textTheme.labelSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 10,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: AppSpacing.sm),
          _AddToCartControl(shop: shop, product: product, soldOut: soldOut),
        ],
      ),
    );
  }
}

// ==========================================================================
// Reviews
// ==========================================================================

/// How many reviews the shop page shows before offering the rest (item 3).
const int _reviewsShownAtFirst = 8;

/// Every review, in a sheet. Reusing [_ReviewTile] keeps the "Verified
/// order" label and the owner's reply button working here too.
void _showAllReviews(
  BuildContext context, {
  required List<ReviewEntry> reviews,
  required bool isOwner,
  required bool offline,
  required void Function(ReviewEntry) onReply,
}) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.8,
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            Text(
              '${reviews.length} reviews',
              style: Theme.of(sheetContext)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: AppSpacing.md),
            for (final review in reviews)
              _ReviewTile(
                review: review,
                canReply: !offline && isOwner && (review.ownerReply == null),
                onReply: () {
                  Navigator.pop(sheetContext);
                  onReply(review);
                },
              ),
          ],
        ),
      ),
    ),
  );
}

class _ReviewTile extends StatelessWidget {
  final ReviewEntry review;
  final bool canReply;
  final VoidCallback onReply;

  const _ReviewTile({required this.review, required this.canReply, required this.onReply});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final colors = context.appColors;
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppRadius.card),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (var i = 1; i <= 5; i++)
                  Icon(
                    i <= review.rating ? Icons.star_rounded : Icons.star_outline_rounded,
                    size: 16,
                    color: colorScheme.secondary,
                  ),
                // Item 3: this one came from a delivered order, so it is
                // worth more to a customer than an anonymous rating.
                if (review.isFromOrder) ...[
                  const SizedBox(width: AppSpacing.sm),
                  StatusBadge(
                    label: 'Verified order',
                    background: colors.success.withValues(alpha: 0.16),
                    foreground: colors.success,
                  ),
                ],
                const Spacer(),
                if (review.createdAt != null)
                  Text(
                    timeAgo(review.createdAt!),
                    style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
                  ),
              ],
            ),
            if (review.comment.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(review.comment, style: textTheme.bodyMedium),
            ],
            if (review.ownerReply != null && review.ownerReply!.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  borderRadius: BorderRadius.circular(AppRadius.input),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Reply from the shop',
                      style: textTheme.labelSmall?.copyWith(
                        color: colors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(review.ownerReply!, style: textTheme.bodySmall),
                  ],
                ),
              ),
            ],
            if (canReply)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: onReply, child: const Text('Reply')),
              ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet: pick 1-5 stars and write an optional comment.
class _RateSheet extends StatefulWidget {
  const _RateSheet();

  @override
  State<_RateSheet> createState() => _RateSheetState();
}

class _RateSheetState extends State<_RateSheet> {
  final _comment = TextEditingController();
  int _rating = 0;

  @override
  void dispose() {
    _comment.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Rate this shop',
                style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                for (var star = 1; star <= 5; star++)
                  IconButton(
                    tooltip: '$star star${star == 1 ? '' : 's'}',
                    onPressed: () => setState(() => _rating = star),
                    icon: Icon(
                      star <= _rating ? Icons.star_rounded : Icons.star_outline_rounded,
                      size: 34,
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ),
              ],
            ),
            TextField(
              controller: _comment,
              maxLines: 3,
              maxLength: 500,
              decoration: const InputDecoration(hintText: 'Add a comment (optional)'),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _rating == 0
                    ? null
                    : () => Navigator.pop(context, _RatingResult(_rating, _comment.text.trim())),
                child: const Text('Submit rating'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dialog for the owner's reply to a review.
class _ReplyDialog extends StatefulWidget {
  const _ReplyDialog();

  @override
  State<_ReplyDialog> createState() => _ReplyDialogState();
}

class _ReplyDialogState extends State<_ReplyDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Reply to this review'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        maxLength: 500,
        decoration: const InputDecoration(hintText: 'Your reply is shown publicly'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Post reply'),
        ),
      ],
    );
  }
}

// ==========================================================================
// Ordering
// ==========================================================================

/// Add-to-cart control for one product row: a compact "Add" button that
/// becomes a stepper once the product is in the cart.
///
/// An order belongs to exactly one shop (delivery-service gives it a single
/// `shop_id` and one agent), so adding from a second shop asks before
/// replacing the cart rather than quietly discarding it.
class _AddToCartControl extends StatelessWidget {
  final Shop shop;
  final Product product;
  final bool soldOut;

  const _AddToCartControl({
    required this.shop,
    required this.product,
    required this.soldOut,
  });

  Future<void> _add(BuildContext context) async {
    final cart = CartController.instance;
    if (cart.wouldReplaceCart(shop.id)) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Start a new cart?'),
          content: Text(
            'Your cart has items from ${cart.shopName ?? 'another shop'}. '
            'An order can only come from one shop, so adding this will empty it.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Keep cart'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Start new'),
            ),
          ],
        ),
      );
      if (replace != true) return;
    }
    final added = cart.add(product, shopId: shop.id, shopName: shop.name);
    if (added || !context.mounted) return;
    // Refused: either the shelf is empty or the cart already holds all of
    // it. Silence here reads as a broken button.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          product.stockQuantity <= 0 || !product.isAvailable
              ? '${product.name} is out of stock.'
              : 'Only ${product.stockQuantity} of ${product.name} left.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (soldOut) return const SizedBox(width: 4);

    return AnimatedBuilder(
      animation: CartController.instance,
      builder: (context, _) {
        final quantity = CartController.instance.shopId == shop.id
            ? CartController.instance.quantityOf(product.id)
            : 0;

        if (quantity == 0) {
          return IconButton(
            tooltip: 'Add to cart',
            visualDensity: VisualDensity.compact,
            onPressed: () => _add(context),
            icon: Icon(
              Icons.add_shopping_cart,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
          );
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Remove one',
              visualDensity: VisualDensity.compact,
              onPressed: () => CartController.instance.remove(product.id),
              icon: const Icon(Icons.remove_circle_outline, size: 20),
            ),
            Text('$quantity', style: Theme.of(context).textTheme.titleSmall),
            IconButton(
              tooltip: 'Add one',
              visualDensity: VisualDensity.compact,
              // Capped at what the shop says it has on the shelf.
              onPressed: product.stockQuantity > 0 && quantity >= product.stockQuantity
                  ? null
                  : () => _add(context),
              icon: const Icon(Icons.add_circle_outline, size: 20),
            ),
          ],
        );
      },
    );
  }
}

/// Floating "N items · Rs. X — View cart" bar, shown only while this
/// shop's cart has something in it.
class _CartBar extends StatelessWidget {
  final String shopId;

  const _CartBar({required this.shopId});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: CartController.instance,
      builder: (context, _) {
        final cart = CartController.instance;
        if (cart.isEmpty || cart.shopId != shopId) return const SizedBox.shrink();

        final colorScheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Material(
            color: colorScheme.primary,
            borderRadius: BorderRadius.circular(AppRadius.pill),
            elevation: 6,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.pill),
              onTap: () => Navigator.pushNamed(context, AppRoutes.checkout),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.md,
                ),
                child: Row(
                  children: [
                    Icon(Icons.shopping_cart_outlined, color: colorScheme.onPrimary, size: 20),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        '${cart.itemCount} ${cart.itemCount == 1 ? 'item' : 'items'}'
                        '  ·  Rs. ${cart.total.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: colorScheme.onPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      'View cart',
                      style: TextStyle(
                        color: colorScheme.onPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Icon(Icons.chevron_right, color: colorScheme.onPrimary),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}


/// Square product photo, or a neutral placeholder when the owner has not
/// uploaded one yet. Sized small enough that a long product list still
/// scrolls smoothly on a cheap phone.
class _ProductThumbnail extends StatelessWidget {
  final Product product;
  final bool soldOut;

  const _ProductThumbnail({required this.product, required this.soldOut});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final url = mediaUrl(product.imageUrl);

    return Opacity(
      opacity: soldOut ? 0.45 : 1,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.input),
        child: SizedBox(
          width: 52,
          height: 52,
          child: url == null
              ? ColoredBox(
                  color: colorScheme.surfaceContainerHighest,
                  child: Icon(
                    Icons.inventory_2_outlined,
                    size: 22,
                    color: context.appColors.textSecondary,
                  ),
                )
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => ColoredBox(
                    color: colorScheme.surfaceContainerHighest,
                    child: Icon(
                      Icons.broken_image_outlined,
                      size: 22,
                      color: context.appColors.textSecondary,
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}
