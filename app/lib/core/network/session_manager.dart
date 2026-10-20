import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';
import 'offline_cache.dart';

/// Holds the current login session (JWT + basic user identity) in memory,
/// persisted to disk via shared_preferences so the app stays logged in
/// across restarts. A ChangeNotifier so widgets (e.g. the router/home menu)
/// can react to login/logout without a heavier state-management dependency.
class SessionManager extends ChangeNotifier {
  SessionManager._();
  static final SessionManager instance = SessionManager._();

  String? _token;
  String? _userId;
  String? _userRole;
  String? _userName;
  bool _initialized = false;

  String? get token => _token;
  String? get userId => _userId;
  String? get userRole => _userRole;
  String? get userName => _userName;
  bool get isLoggedIn => _token != null;
  bool get isInitialized => _initialized;

  bool get isAdmin => _userRole == 'admin';
  bool get isShopOwner => _userRole == 'shop_owner';
  bool get isDeliveryAgent => _userRole == 'delivery_agent';

  /// A plain shopper: the only role that gets the "Explore" shopping home
  /// (recommendations, nearby shops, search). Every other role — and a
  /// not-yet-loaded session — lands on a role-specific staff home instead.
  bool get isCustomer => !isAdmin && !isShopOwner && !isDeliveryAgent;

  Future<void> loadFromDisk() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(AppConstants.authTokenKey);
    _userId = prefs.getString(AppConstants.userIdKey);
    _userRole = prefs.getString(AppConstants.userRoleKey);
    _userName = prefs.getString(AppConstants.userNameKey);
    _initialized = true;
    notifyListeners();
  }

  Future<void> saveSession({
    required String token,
    required String userId,
    required String role,
    required String name,
  }) async {
    _token = token;
    _userId = userId;
    _userRole = role;
    _userName = name;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.authTokenKey, token);
    await prefs.setString(AppConstants.userIdKey, userId);
    await prefs.setString(AppConstants.userRoleKey, role);
    await prefs.setString(AppConstants.userNameKey, name);
    notifyListeners();
  }

  Future<void> clearSession() async {
    _token = null;
    _userId = null;
    _userRole = null;
    _userName = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(AppConstants.authTokenKey);
    await prefs.remove(AppConstants.userIdKey);
    await prefs.remove(AppConstants.userRoleKey);
    await prefs.remove(AppConstants.userNameKey);
    // Item 14: the offline caches hold this account's orders and
    // notifications. The next person to sign in on this phone must not
    // find them.
    await OfflineCache.clearAll();
    notifyListeners();
  }
}
