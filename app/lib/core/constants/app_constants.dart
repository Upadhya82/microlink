import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;

class AppConstants {
  AppConstants._();

  static const String appName = 'MicroLink';

  /// The API Gateway base URL. The app NEVER talks to a backend service
  /// directly -- everything goes through the gateway at /api/*.
  ///
  /// 10.0.2.2 is the Android emulator's alias for the host machine's
  /// localhost; a physical device on the same network should instead point
  /// this at the host's real LAN IP (override via --dart-define=API_BASE_URL=...).
  ///
  /// Uses `defaultTargetPlatform`/`kIsWeb` instead of `dart:io`'s `Platform`
  /// since `dart:io` isn't available on web -- this getter must compile and
  /// behave sensibly on every target (web, desktop, Android).
  static String get apiBaseUrl {
    const override = String.fromEnvironment('API_BASE_URL');
    if (override.isNotEmpty) return override;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:8080/api';
    }
    return 'http://localhost:8080/api';
  }

  static const String authTokenKey = 'microlink_auth_token';
  static const String userIdKey = 'microlink_user_id';
  static const String userRoleKey = 'microlink_user_role';
  static const String userNameKey = 'microlink_user_name';
  static const String themeModeKey = 'microlink_theme_mode';

  static const Duration requestTimeout = Duration(seconds: 15);
}

class AppRoutes {
  AppRoutes._();

  static const String login = '/login';
  static const String register = '/register';
  static const String home = '/home';
  static const String shopList = '/shops';
  static const String shopDetail = '/shops/detail';
  static const String shopOwnerDashboard = '/shop-owner/dashboard';
  static const String recommendedShops = '/recommendations';
  static const String liveMap = '/navigation/map';
  static const String driverHome = '/delivery/driver-home';
  static const String deliveryTracking = '/delivery/tracking';
  static const String myOrders = '/delivery/my-orders';
  static const String requestDelivery = '/delivery/request';
  static const String myFavorites = '/recommendations/favorites';
  static const String interests = '/recommendations/interests';
  static const String addNewShop = '/crowdsource/add-shop';
  static const String reportRoadIssue = '/crowdsource/report-road-issue';
  static const String adminDashboard = '/admin/dashboard';
  static const String submitAd = '/ads/submit';
}
