import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/session_manager.dart';
import '../../../core/theme/app_colors_extension.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_card.dart';

/// "Is this shop really here?" on an unverified shop's page.
///
/// A shop registered by its owner starts unverified, and until this existed
/// the only way out of that was an admin -- who, for a shop that opened last
/// week in a town they have never visited, has no way to know. The customers
/// who walk past it do, so enough of them confirming it verifies the shop
/// (shop-service/app/community.py holds the rule).
///
/// The card asks for the phone's position when the button is tapped rather
/// than on build: the server will not accept a confirmation without one, but
/// a customer only reading the page should not be asked for their location.
class ShopConfirmationCard extends StatefulWidget {
  final String shopId;
  final String shopName;

  /// What the shop page already knows from the shop's own JSON, so the card
  /// shows the right progress immediately and the fetch below only corrects
  /// it (and fills in whether this account has already confirmed).
  final int confirmations;
  final int required;

  /// Called once the shop becomes verified, so the page can reload and drop
  /// both the "not verified" chip and this card.
  final Future<void> Function() onVerified;

  const ShopConfirmationCard({
    super.key,
    required this.shopId,
    required this.shopName,
    required this.confirmations,
    required this.required,
    required this.onVerified,
  });

  @override
  State<ShopConfirmationCard> createState() => _ShopConfirmationCardState();
}

class _ShopConfirmationCardState extends State<ShopConfirmationCard> {
  late int _confirmations = widget.confirmations;
  late int _required = widget.required;
  bool _confirmedByMe = false;
  int _productsStillNeeded = 0;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _fetchStanding();
  }

  /// Whether this account has already confirmed, which the shop's own JSON
  /// cannot say. A failure leaves the counts the page already had.
  Future<void> _fetchStanding() async {
    try {
      final response =
          await ApiClient.instance.get('/shops/${widget.shopId}/confirmations');
      final data = response as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _confirmations = (data['confirmations'] as num?)?.toInt() ?? _confirmations;
        _required = (data['required'] as num?)?.toInt() ?? _required;
        _confirmedByMe = data['confirmed_by_me'] as bool? ?? false;
        _productsStillNeeded =
            (data['products_still_needed'] as num?)?.toInt() ?? 0;
      });
    } catch (_) {
      // Non-fatal: the card still shows the count the shop page carried.
    }
  }

  void _show(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// The phone's position, or null with the reason already shown to the user.
  /// Unlike the home screen, a refusal here cannot be silent: without a
  /// position there is nothing to send, so the user has to be told why.
  Future<Position?> _position() async {
    try {
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _show('Location permission is needed to confirm a shop near you.');
        return null;
      }
      if (!await Geolocator.isLocationServiceEnabled()) {
        _show('Please turn on location services to confirm this shop.');
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.medium),
      );
    } catch (_) {
      _show('Could not read your location. Please try again.');
      return null;
    }
  }

  Future<void> _confirm() async {
    if (!SessionManager.instance.isLoggedIn) {
      _show('Please log in to confirm this shop.');
      return;
    }
    setState(() => _submitting = true);
    try {
      final position = await _position();
      if (position == null) return;

      final response = await ApiClient.instance.post(
        '/shops/${widget.shopId}/confirm',
        body: {'latitude': position.latitude, 'longitude': position.longitude},
      );
      final data = response as Map<String, dynamic>;
      if (!mounted) return;

      final verified = data['is_verified'] as bool? ?? false;
      setState(() {
        _confirmations = (data['confirmations'] as num?)?.toInt() ?? _confirmations;
        _required = (data['required'] as num?)?.toInt() ?? _required;
        _confirmedByMe = true;
        _productsStillNeeded =
            (data['products_still_needed'] as num?)?.toInt() ?? 0;
      });

      if (verified) {
        _show('Thanks! ${widget.shopName} is now verified.');
        await widget.onVerified();
      } else {
        final remaining = _required - _confirmations;
        _show(
          remaining > 0
              ? 'Thanks! $remaining more neighbour${remaining == 1 ? '' : 's'} '
                  'and this shop will be verified.'
              : 'Thanks for confirming this shop.',
        );
      }
    } on ApiException catch (e) {
      // The server's own words: too far away, account not verified yet, your
      // own shop. Each is something the user can act on, so none is swallowed.
      _show(e.message);
    } catch (_) {
      _show('Could not send your confirmation. Please try again.');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.appColors;
    final textTheme = Theme.of(context).textTheme;
    final progress = _required == 0 ? 0.0 : (_confirmations / _required).clamp(0.0, 1.0);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.how_to_reg_outlined, color: colors.warning),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Is this shop really here?',
                  style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'No admin has checked this shop yet. Customers nearby can confirm '
            'it exists, and once $_required of you have, it is verified.',
            style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: colors.warning.withValues(alpha: 0.16),
              valueColor: AlwaysStoppedAnimation<Color>(colors.success),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '$_confirmations of $_required neighbours confirmed',
            style: textTheme.bodySmall?.copyWith(
              color: colors.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (_confirmations >= _required && _productsStillNeeded > 0) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Your neighbours have confirmed it. It will be verified once the '
              'owner lists $_productsStillNeeded more product'
              '${_productsStillNeeded == 1 ? '' : 's'}.',
              style: textTheme.bodySmall?.copyWith(color: colors.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          if (_confirmedByMe)
            Row(
              children: [
                Icon(Icons.check_circle_outline, size: 18, color: colors.success),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  'You confirmed this shop',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colors.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            )
          else
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _submitting ? null : _confirm,
                icon: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.place_outlined),
                label: Text(
                  _submitting ? 'Confirming...' : "Yes, I've seen this shop",
                ),
              ),
            ),
        ],
      ),
    );
  }
}
