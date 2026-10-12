import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/picked_location.dart';

/// Remembers the delivery location the customer last chose.
///
/// Kept on the device rather than on the user record: it is a convenience
/// default for the next checkout, not account data, and the order itself
/// always carries its own copy of the address it was placed with (see
/// delivery-service's `Order.delivery_address`), so changing this later never
/// rewrites history.
class DeliveryLocationStore extends ChangeNotifier {
  DeliveryLocationStore._();
  static final DeliveryLocationStore instance = DeliveryLocationStore._();

  static const String _key = 'microlink_delivery_location';

  PickedLocation? _location;
  bool _loaded = false;

  PickedLocation? get location => _location;
  bool get hasLocation => _location != null;

  Future<void> loadFromDisk() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        _location = PickedLocation.fromJson(decoded);
        notifyListeners();
      }
    } catch (_) {
      // A corrupt or unreadable preference just means "no saved location".
    }
  }

  Future<void> save(PickedLocation location) async {
    _location = location;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(location.toJson()));
    } catch (_) {
      // Keeping it for this session is better than failing the checkout.
    }
  }

  Future<void> clear() async {
    _location = null;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // Nothing useful to do.
    }
  }
}
