import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Keeps the screens a user needs when there is no signal (item 14).
///
/// Shop search already cached its results (see `ShopCache`); this follows
/// the same pattern for the three things that were still blank offline: the
/// customer's own orders, the driver's active delivery with its route
/// steps, and notifications. A delivery agent halfway up a lane with no
/// signal could not see the address they were delivering to, which is the
/// worst possible moment to show an empty screen.
///
/// Read-only on purpose. Nothing here queues a write: an order placed
/// offline would be a promise the app cannot keep, and a status change
/// stored for later would tell the customer their parcel moved when it had
/// not. Offline shows what was last known, and says so.
class OfflineCache {
  OfflineCache._();

  /// Old enough to be worth showing with a date, young enough not to
  /// mislead. The same window shop search uses.
  static const Duration maxAge = Duration(days: 7);

  static const String myOrdersKey = 'microlink_cache_my_orders_v1';
  static const String activeDeliveryKey = 'microlink_cache_active_delivery_v1';
  static const String notificationsKey = 'microlink_cache_notifications_v1';

  /// Every key this cache owns, so logging out can clear the lot.
  static const List<String> allKeys = [
    myOrdersKey,
    activeDeliveryKey,
    notificationsKey,
  ];

  /// Store [payload] (any JSON-encodable value) under [key], with the time.
  static Future<void> save(String key, Object? payload) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        key,
        jsonEncode({
          'saved': DateTime.now().millisecondsSinceEpoch,
          'payload': payload,
        }),
      );
    } catch (_) {
      // The cache is a bonus; never let it break the screen that fed it.
    }
  }

  /// What was stored under [key], or null when nothing usable is there.
  static Future<CachedPayload?> load(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final text = prefs.getString(key);
      if (text == null) return null;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final savedMs = decoded['saved'];
      if (savedMs is! int) return null;
      final savedAt = DateTime.fromMillisecondsSinceEpoch(savedMs);
      if (DateTime.now().difference(savedAt) > maxAge) {
        // Too old to show. Drop it rather than leaving it to rot.
        await prefs.remove(key);
        return null;
      }
      return CachedPayload(payload: decoded['payload'], savedAt: savedAt);
    } catch (_) {
      return null;
    }
  }

  /// A list payload, or an empty list. Saves every caller the same casting.
  static Future<CachedList?> loadList(String key) async {
    final cached = await load(key);
    if (cached == null) return null;
    final payload = cached.payload;
    if (payload is! List) return null;
    return CachedList(
      rows: payload
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(),
      savedAt: cached.savedAt,
    );
  }

  /// Forget everything. Called on logout: the next person to use this phone
  /// must not find the previous account's orders and notifications.
  static Future<void> clearAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in allKeys) {
        await prefs.remove(key);
      }
    } catch (_) {
      // Nothing useful to do; the data expires on its own in any case.
    }
  }
}

/// A cached value and when it was stored, so a screen can say how old it is.
class CachedPayload {
  final Object? payload;
  final DateTime savedAt;

  const CachedPayload({required this.payload, required this.savedAt});
}

/// A cached list of JSON rows and when it was stored.
class CachedList {
  final List<Map<String, dynamic>> rows;
  final DateTime savedAt;

  const CachedList({required this.rows, required this.savedAt});
}
