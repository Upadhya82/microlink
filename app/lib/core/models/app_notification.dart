/// Mirrors admin-service's `NotificationResponse` schema.
///
/// `link` is a small hint the backend attaches so the app can decide where
/// tapping a notification should go -- e.g. `{"route": "order", "id": "..."}`.
/// It is deliberately loose: an unknown route just means the row isn't
/// tappable, so a new backend notification kind can never crash the app.
class AppNotification {
  final String id;
  final String userId;
  final String title;
  final String body;
  final String kind;
  final Map<String, dynamic> link;
  final bool isRead;
  final DateTime createdAt;

  const AppNotification({
    required this.id,
    required this.userId,
    required this.title,
    required this.body,
    required this.kind,
    required this.link,
    required this.isRead,
    required this.createdAt,
  });

  /// The `route` hint, or null when the backend sent none.
  String? get linkRoute {
    final route = link['route'];
    return route is String && route.isNotEmpty ? route : null;
  }

  /// The id the `route` hint refers to (a shop id, order id, ...).
  String? get linkId {
    final id = link['id'];
    return id is String && id.isNotEmpty ? id : null;
  }

  factory AppNotification.fromJson(Map<String, dynamic> json) {
    final rawLink = json['link'];
    return AppNotification(
      id: json['id'] as String,
      userId: json['user_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      kind: json['kind'] as String? ?? 'general',
      link: rawLink is Map ? Map<String, dynamic>.from(rawLink) : const {},
      isRead: json['is_read'] as bool? ?? false,
      createdAt:
          DateTime.tryParse(json['created_at'] as String? ?? '')?.toLocal() ?? DateTime.now(),
    );
  }

  AppNotification copyWith({bool? isRead}) {
    return AppNotification(
      id: id,
      userId: userId,
      title: title,
      body: body,
      kind: kind,
      link: link,
      isRead: isRead ?? this.isRead,
      createdAt: createdAt,
    );
  }
}
