/// Thrown by [ApiClient] for any non-2xx response or network failure.
/// [message] is user-presentable (parsed from the backend's `{"detail": ...}`
/// shape when possible, otherwise a generic fallback).
class ApiException implements Exception {
  final int? statusCode;
  final String message;

  const ApiException(this.message, {this.statusCode});

  bool get isUnauthorized => statusCode == 401;
  bool get isForbidden => statusCode == 403;
  bool get isNotFound => statusCode == 404;
  bool get isNetworkError => statusCode == null;

  @override
  String toString() => message;
}
