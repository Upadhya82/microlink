import 'package:flutter/material.dart';

import '../../features/account/screens/verification_documents_screen.dart';
import '../../features/admin/screens/admin_applicant_screen.dart';
import '../../features/admin/screens/admin_dashboard_screen.dart';
import '../../features/admin/screens/admin_review_screen.dart';
import '../../features/ads/screens/submit_ad_screen.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/auth/screens/register_screen.dart';
import '../../features/crowdsourcing/screens/add_new_shop_screen.dart';
import '../../features/crowdsourcing/screens/confirm_shops_screen.dart';
import '../../features/crowdsourcing/screens/report_road_issue_screen.dart';
import '../../features/delivery/screens/delivery_tracking_screen.dart';
import '../../features/delivery/screens/driver_home_screen.dart';
import '../../features/delivery/screens/my_orders_screen.dart';
import '../../features/delivery/screens/request_delivery_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/navigation/screens/live_map_screen.dart';
import '../../features/notifications/screens/notifications_screen.dart';
import '../../features/orders/screens/checkout_screen.dart';
import '../../features/settings/screens/about_screen.dart';
import '../../features/settings/screens/settings_screen.dart';
import '../../features/recommendations/screens/interests_screen.dart';
import '../../features/recommendations/screens/my_favorites_screen.dart';
import '../../features/recommendations/screens/recommended_shops_screen.dart';
import '../../features/shop_discovery/screens/shop_detail_screen.dart';
import '../../features/shop_discovery/screens/shop_list_screen.dart';
import '../../features/shop_owner/screens/shop_owner_dashboard_screen.dart';
import '../constants/app_constants.dart';
import 'app_page_route.dart';
import 'route_args.dart';

export 'route_args.dart';

/// The app's single source of truth for named routes. Every screen must be
/// registered here -- no navigation should use raw MaterialPageRoute pushes
/// outside of this file.
class AppRouter {
  AppRouter._();

  static Route<dynamic> onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case AppRoutes.login:
        return _page(const LoginScreen(), settings);
      case AppRoutes.register:
        return _page(const RegisterScreen(), settings);
      case AppRoutes.home:
        return _page(const HomeScreen(), settings);
      case AppRoutes.shopList:
        final args = settings.arguments as ShopListArgs? ?? const ShopListArgs();
        return _page(ShopListScreen(initialCategory: args.initialCategory), settings);
      case AppRoutes.shopDetail:
        final args = settings.arguments as ShopDetailArgs;
        return _page(ShopDetailScreen(shopId: args.shopId), settings);
      case AppRoutes.shopOwnerDashboard:
        return _page(const ShopOwnerDashboardScreen(), settings);
      case AppRoutes.recommendedShops:
        return _page(const RecommendedShopsScreen(), settings);
      case AppRoutes.liveMap:
        final args = settings.arguments as LiveMapArgs? ?? const LiveMapArgs();
        return _page(LiveMapScreen(args: args), settings);
      case AppRoutes.driverHome:
        return _page(const DriverHomeScreen(), settings);
      case AppRoutes.deliveryTracking:
        final args = settings.arguments as DeliveryTrackingArgs;
        return _page(DeliveryTrackingScreen(orderId: args.orderId), settings);
      case AppRoutes.myOrders:
        return _page(const MyOrdersScreen(), settings);
      case AppRoutes.requestDelivery:
        final args = settings.arguments as RequestDeliveryArgs? ?? const RequestDeliveryArgs();
        return _page(RequestDeliveryScreen(args: args), settings);
      case AppRoutes.myFavorites:
        return _page(const MyFavoritesScreen(), settings);
      case AppRoutes.interests:
        return _page(const InterestsScreen(), settings);
      case AppRoutes.addNewShop:
        return _page(const AddNewShopScreen(), settings);
      case AppRoutes.confirmShops:
        return _page(const ConfirmShopsScreen(), settings);
      case AppRoutes.reportRoadIssue:
        return _page(const ReportRoadIssueScreen(), settings);
      case AppRoutes.adminDashboard:
        return _page(const AdminDashboardScreen(), settings);
      case AppRoutes.notifications:
        return _page(const NotificationsScreen(), settings);
      case AppRoutes.checkout:
        return _page(const CheckoutScreen(), settings);
      case AppRoutes.verificationDocuments:
        return _page(const VerificationDocumentsScreen(), settings);
      case AppRoutes.adminReview:
        // An int argument opens a given tab (1 = shop suggestions).
        final tab = settings.arguments is int ? settings.arguments as int : 0;
        return _page(AdminReviewScreen(initialTab: tab), settings);
      case AppRoutes.adminApplicant:
        final args = settings.arguments as AdminApplicantArgs;
        return _page(AdminApplicantScreen(user: args.user), settings);
      case AppRoutes.settings:
        return _page(const SettingsScreen(), settings);
      case AppRoutes.about:
        return _page(const AboutScreen(), settings);
      case AppRoutes.submitAd:
        final args = settings.arguments as SubmitAdArgs? ?? const SubmitAdArgs();
        return _page(SubmitAdScreen(args: args), settings);
      default:
        return _page(
          Scaffold(body: Center(child: Text('Unknown route: ${settings.name}'))),
          settings,
        );
    }
  }

  /// Every route goes through here, so the app's transition is defined once
  /// rather than per screen. See [AppPageRoute].
  static PageRoute<dynamic> _page(Widget child, RouteSettings settings) {
    return AppPageRoute<dynamic>(child: child, settings: settings);
  }
}
