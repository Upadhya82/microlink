import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/features/shop_discovery/shop_discovery_support.dart';

/// Nearby customers vouching for an unverified shop.
///
/// The decision this file pins down is when the shop page offers the
/// "I've seen this shop" button at all: only for a shop the server says is
/// unverified AND told us the number of confirmations it wants. A server too
/// old to know about confirmations sends neither field, and a button whose
/// every tap would 404 is worse than no button.
Map<String, dynamic> _json({
  Object? isVerified = _absent,
  Object? confirmations = _absent,
  Object? required_ = _absent,
  Object? verifiedVia = _absent,
}) => {
      'id': 's1',
      'owner_id': 'o1',
      'name': 'Homagama Stores',
      'description': '',
      'category': 'grocery',
      'address': '1 Highlevel Rd, Homagama',
      'latitude': 6.8441,
      'longitude': 80.0020,
      'opening_time': '09:00',
      'closing_time': '18:00',
      'is_open': true,
      'rating_avg': 0,
      'rating_count': 0,
      'created_at': '2026-10-18T10:00:00+00:00',
      'updated_at': '2026-10-18T10:00:00+00:00',
      if (isVerified != _absent) 'is_verified': isVerified,
      if (confirmations != _absent) 'community_confirmations': confirmations,
      if (required_ != _absent) 'confirmations_required': required_,
      if (verifiedVia != _absent) 'verified_via': verifiedVia,
    };

/// Stands in for "the key is not in the response at all", which is what both
/// an older server and a page cached before this feature look like.
const Object _absent = Object();

void main() {
  group('parsing the confirmation fields', () {
    test('the tally and the threshold are read', () {
      final extras = ShopExtras.fromJson(
        _json(isVerified: false, confirmations: 2, required_: 3),
      );
      expect(extras.communityConfirmations, 2);
      expect(extras.confirmationsRequired, 3);
    });

    test('an older response leaves them at zero rather than null', () {
      final extras = ShopExtras.fromJson(_json(isVerified: false));
      expect(extras.communityConfirmations, 0);
      expect(extras.confirmationsRequired, 0);
    });

    test('how a shop was verified is read', () {
      final extras = ShopExtras.fromJson(
        _json(isVerified: true, verifiedVia: 'community'),
      );
      expect(extras.verifiedVia, 'community');
      expect(extras.verifiedByCommunity, isTrue);
    });

    test('an admin-verified shop is not credited to the neighbourhood', () {
      final extras = ShopExtras.fromJson(
        _json(isVerified: true, verifiedVia: 'admin'),
      );
      expect(extras.verifiedByCommunity, isFalse);
    });
  });

  group('when the confirm button is offered', () {
    test('an unverified shop on a server that knows the threshold', () {
      final extras = ShopExtras.fromJson(
        _json(isVerified: false, confirmations: 0, required_: 3),
      );
      expect(extras.acceptsConfirmations, isTrue);
      expect(extras.showsNotVerifiedChip, isTrue);
    });

    test('never for a shop that is already verified', () {
      final extras = ShopExtras.fromJson(
        _json(isVerified: true, confirmations: 3, required_: 3),
      );
      expect(extras.acceptsConfirmations, isFalse);
    });

    test('not on an older server that sent no threshold', () {
      final extras = ShopExtras.fromJson(_json(isVerified: false));
      expect(extras.acceptsConfirmations, isFalse);
      // The chip still shows: that field is older than this feature.
      expect(extras.showsNotVerifiedChip, isTrue);
    });

    test('not when the server never said whether the shop is verified', () {
      final extras = ShopExtras.fromJson(_json(required_: 3));
      expect(extras.acceptsConfirmations, isFalse);
      expect(extras.showsNotVerifiedChip, isFalse);
    });

    test('still offered once the threshold is met but the shop is not yet '
        'verified, because the owner has products left to list', () {
      final extras = ShopExtras.fromJson(
        _json(isVerified: false, confirmations: 3, required_: 3),
      );
      expect(extras.acceptsConfirmations, isTrue);
    });
  });
}
