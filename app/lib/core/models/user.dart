/// Mirrors user-service's `UserResponse` schema.
class AppUser {
  final String id;
  final String email;
  final String fullName;
  final String? phone;
  final String role;
  final bool isVerified;
  final bool isActive;
  final DateTime createdAt;

  const AppUser({
    required this.id,
    required this.email,
    required this.fullName,
    this.phone,
    required this.role,
    required this.isVerified,
    required this.isActive,
    required this.createdAt,
  });

  factory AppUser.fromJson(Map<String, dynamic> json) {
    return AppUser(
      id: json['id'] as String,
      email: json['email'] as String,
      fullName: json['full_name'] as String,
      phone: json['phone'] as String?,
      role: json['role'] as String,
      isVerified: json['is_verified'] as bool? ?? false,
      isActive: json['is_active'] as bool? ?? true,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

/// The roles a MicroLink account can have (user-service's `UserRole` enum).
const String roleUser = 'user';
const String roleShopOwner = 'shop_owner';
const String roleDeliveryAgent = 'delivery_agent';
const String roleAdmin = 'admin';

String formatRoleLabel(String role) {
  return switch (role) {
    roleUser => 'Customer',
    roleShopOwner => 'Shop Owner',
    roleDeliveryAgent => 'Delivery Agent',
    roleAdmin => 'Admin',
    _ => role,
  };
}
