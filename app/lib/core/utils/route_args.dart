/// Route argument payloads. Every screen that needs data from its caller
/// takes one of these via `ModalRoute.of(context)!.settings.arguments`.
///
/// Kept separate from `app_router.dart` (which imports every screen) so
/// that shared, low-level widgets (e.g. `ShopPreviewCard`) can depend on
/// just the argument shape they need to navigate, without an import cycle
/// back through the router into the screens themselves.
library;

class ShopDetailArgs {
  final String shopId;
  const ShopDetailArgs(this.shopId);
}

class ShopListArgs {
  final String? initialCategory;
  const ShopListArgs({this.initialCategory});
}

class DeliveryTrackingArgs {
  final String orderId;
  const DeliveryTrackingArgs(this.orderId);
}

class LiveMapArgs {
  final double? destinationLat;
  final double? destinationLng;
  final String? destinationLabel;
  const LiveMapArgs({this.destinationLat, this.destinationLng, this.destinationLabel});
}

/// Optional context for the "Promote / Submit a Sponsored Ad" screen. When a
/// shop owner opens it from one of their shops, the shop is pre-selected so
/// the ad links straight back to that shop's detail page once approved.
class SubmitAdArgs {
  final String? shopId;
  final String? shopName;
  const SubmitAdArgs({this.shopId, this.shopName});
}

