import 'dart:convert';

import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import 'api_exception.dart';
import 'session_manager.dart';

/// Thin HTTP client pointed at the API Gateway (never a service directly).
/// Attaches the current session's JWT as a Bearer token automatically, and
/// converts non-2xx responses into [ApiException] with a readable message
/// parsed from the backend's `{"detail": ...}` error shape.
class ApiClient {
  ApiClient._();
  static final ApiClient instance = ApiClient._();

  final http.Client _client = http.Client();

  Uri _uri(String path, [Map<String, dynamic>? query]) {
    final normalized = path.startsWith('/') ? path : '/$path';
    final queryParams = query?.entries
            .where((e) => e.value != null)
            .map((e) => MapEntry(e.key, e.value.toString()))
            .fold<Map<String, String>>({}, (m, e) => m..[e.key] = e.value);
    return Uri.parse('${AppConstants.apiBaseUrl}$normalized')
        .replace(queryParameters: queryParams != null && queryParams.isNotEmpty ? queryParams : null);
  }

  Map<String, String> _headers({bool json = true}) {
    final headers = <String, String>{};
    if (json) headers['Content-Type'] = 'application/json';
    final token = SessionManager.instance.token;
    if (token != null) headers['Authorization'] = 'Bearer $token';
    return headers;
  }

  Future<dynamic> get(String path, {Map<String, dynamic>? query}) =>
      _send('GET', _uri(path, query));

  Future<dynamic> post(String path, {Object? body}) =>
      _send('POST', _uri(path), body: body);

  Future<dynamic> patch(String path, {Object? body}) =>
      _send('PATCH', _uri(path), body: body);

  Future<dynamic> put(String path, {Object? body}) =>
      _send('PUT', _uri(path), body: body);

  Future<dynamic> delete(String path) => _send('DELETE', _uri(path));

  Future<dynamic> _send(String method, Uri uri, {Object? body}) async {
    http.Response response;
    try {
      final headers = _headers();
      final encodedBody = body == null ? null : jsonEncode(body);
      response = await _client
          .send(_request(method, uri, headers, encodedBody))
          .then(http.Response.fromStream)
          .timeout(AppConstants.requestTimeout);
    } catch (_) {
      throw const ApiException(
        'Could not reach the server. Check your connection and try again.',
      );
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return null;
      try {
        return jsonDecode(response.body);
      } catch (_) {
        return null;
      }
    }

    throw ApiException(_extractErrorMessage(response), statusCode: response.statusCode);
  }

  http.Request _request(String method, Uri uri, Map<String, String> headers, String? body) {
    final request = http.Request(method, uri)..headers.addAll(headers);
    if (body != null) request.body = body;
    return request;
  }

  String _extractErrorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
      if (decoded is Map && decoded['detail'] is List && decoded['detail'].isNotEmpty) {
        final first = decoded['detail'].first;
        if (first is Map && first['msg'] is String) return first['msg'] as String;
      }
    } catch (_) {
      // fall through to generic message
    }
    return switch (response.statusCode) {
      400 => 'That request was invalid.',
      401 => 'Please log in again.',
      403 => 'You do not have permission to do that.',
      404 => 'We could not find that.',
      409 => 'That conflicts with existing data.',
      422 => 'Please check the information you entered.',
      _ => 'Something went wrong on our end. Please try again.',
    };
  }
}
