import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:frontend/core/constants/app_constants.dart';
import 'package:frontend/core/models/user.dart';
import 'package:frontend/core/models/shop.dart';
import 'package:frontend/core/network/session_manager.dart';
import 'package:frontend/core/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppUser & Roles Tests', () {
    test('AppUser parses JSON correctly', () {
      final json = {
        'id': 'user-123',
        'email': 'test@example.com',
        'full_name': 'Test User',
        'phone': '1234567890',
        'role': 'user',
        'is_verified': true,
        'is_active': true,
        'created_at': '2026-09-11T10:00:00Z',
      };

      final user = AppUser.fromJson(json);
      expect(user.id, 'user-123');
      expect(user.email, 'test@example.com');
      expect(user.fullName, 'Test User');
      expect(user.phone, '1234567890');
      expect(user.role, roleUser);
      expect(user.isVerified, isTrue);
      expect(user.isActive, isTrue);
    });

    test('formatRoleLabel formats known and unknown roles', () {
      expect(formatRoleLabel(roleUser), 'Customer');
      expect(formatRoleLabel(roleShopOwner), 'Shop Owner');
      expect(formatRoleLabel(roleDeliveryAgent), 'Delivery Agent');
      expect(formatRoleLabel(roleAdmin), 'Admin');
      expect(formatRoleLabel('guest'), 'guest');
    });
  });

  group('Shop Model Tests', () {
    test('Shop parses JSON correctly', () {
      final json = {
        'id': 'shop-456',
        'owner_id': 'user-123',
        'name': 'Cafe Central',
        'category': 'restaurant',
        'address': '123 Main St',
        'latitude': 6.9271,
        'longitude': 79.8612,
        'phone': '555-1234',
        'is_open': true,
        'rating_avg': 4.5,
        'rating_count': 10,
        'opening_time': '08:00',
        'closing_time': '20:00',
        'created_at': '2026-09-11T10:00:00Z',
        'updated_at': '2026-09-11T10:00:00Z',
        'distance_km': 1.2,
      };

      final shop = Shop.fromJson(json);
      expect(shop.id, 'shop-456');
      expect(shop.ownerId, 'user-123');
      expect(shop.name, 'Cafe Central');
      expect(shop.category, 'restaurant');
      expect(shop.latitude, 6.9271);
      expect(shop.longitude, 79.8612);
      expect(shop.phone, '555-1234');
      expect(shop.isOpen, isTrue);
      expect(shop.ratingAvg, 4.5);
      expect(shop.ratingCount, 10);
      expect(shop.distanceKm, 1.2);
    });
  });

  group('SessionManager Tests', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('Initial state is not logged in', () {
      final sm = SessionManager.instance;
      expect(sm.isLoggedIn, isFalse);
      expect(sm.isAdmin, isFalse);
      expect(sm.isShopOwner, isFalse);
      expect(sm.isDeliveryAgent, isFalse);
      expect(sm.isCustomer, isTrue);
    });

    test('saveSession updates state and disk', () async {
      final sm = SessionManager.instance;
      await sm.saveSession(
        token: 'mock-jwt-token',
        userId: 'u1',
        role: roleShopOwner,
        name: 'Jane Owner',
      );

      expect(sm.isLoggedIn, isTrue);
      expect(sm.token, 'mock-jwt-token');
      expect(sm.userId, 'u1');
      expect(sm.userRole, roleShopOwner);
      expect(sm.userName, 'Jane Owner');
      expect(sm.isShopOwner, isTrue);
      expect(sm.isAdmin, isFalse);
      expect(sm.isCustomer, isFalse);

      await sm.clearSession();
      expect(sm.isLoggedIn, isFalse);
      expect(sm.token, isNull);
    });
  });

  group('AppTheme & Constants Tests', () {
    test('AppConstants defaults', () {
      expect(AppConstants.appName, 'MicroLink');
      expect(AppConstants.apiBaseUrl, isNotEmpty);
    });

    test('Theme definitions exist', () {
      expect(AppTheme.light, isNotNull);
      expect(AppTheme.dark, isNotNull);
      expect(AppTheme.light.useMaterial3, isTrue);
      expect(AppTheme.dark.useMaterial3, isTrue);
    });
  });
}

