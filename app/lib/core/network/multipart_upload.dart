import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import 'api_exception.dart';
import 'session_manager.dart';

/// A file the user picked, held in memory.
///
/// Bytes rather than a path: on web there is no filesystem path, and
/// `withData: true` gives the same shape on every platform so the callers
/// do not need two code paths.
class PickedFile {
  final String name;
  final Uint8List bytes;

  const PickedFile({required this.name, required this.bytes});

  int get sizeBytes => bytes.length;
}

/// Shared multipart upload, used by shop photos, verification documents and
/// road-report photos.
///
/// Before this each feature grew its own copy of the picker + request +
/// error handling, which is how three screens ended up with three different
/// behaviours for the same failure.
class MultipartUpload {
  MultipartUpload._();

  /// Matches the server-side cap (see services/*/app/images.py). Checked
  /// here too so a 6MB photo fails instantly instead of after a long upload
  /// on a slow connection.
  static const int maxBytes = 8 * 1024 * 1024;

  static const List<String> imageExtensions = ['jpg', 'jpeg', 'png', 'webp'];
  static const List<String> documentExtensions = ['jpg', 'jpeg', 'png', 'webp', 'pdf'];

  /// Opens the system picker. Returns null if the user backed out.
  static Future<PickedFile?> pick({
    List<String> allowedExtensions = imageExtensions,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      throw const ApiException('Could not read that file. Please try another one.');
    }
    if (bytes.length > maxBytes) {
      throw ApiException(
        'That file is too large. Please choose one under ${maxBytes ~/ (1024 * 1024)}MB.',
      );
    }
    return PickedFile(name: file.name, bytes: bytes);
  }

  /// POST a picked file to [path] as multipart/form-data.
  ///
  /// [fields] become extra form fields alongside the file, which is how
  /// `doc_type` and `note` travel with a verification document.
  static Future<Map<String, dynamic>> send({
    required String path,
    required PickedFile file,
    String fieldName = 'file',
    Map<String, String> fields = const {},
  }) async {
    final normalized = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('${AppConstants.apiBaseUrl}$normalized');
    final request = http.MultipartRequest('POST', uri);

    final token = SessionManager.instance.token;
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    request.fields.addAll(fields);
    request.files.add(
      http.MultipartFile.fromBytes(fieldName, file.bytes, filename: file.name),
    );

    http.Response response;
    try {
      // Longer than the normal API timeout: this is a photo on a phone
      // connection, not a JSON call.
      response = await http.Response.fromStream(
        await request.send(),
      ).timeout(const Duration(seconds: 90));
    } catch (_) {
      throw const ApiException('Upload failed. Check your connection and try again.');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return {};
      try {
        final decoded = jsonDecode(response.body);
        return decoded is Map<String, dynamic> ? decoded : {};
      } catch (_) {
        return {};
      }
    }
    throw ApiException(_errorMessage(response), statusCode: response.statusCode);
  }

  /// POST several files plus form fields in one request.
  ///
  /// Used by the signup application, where the account and its documents
  /// have to arrive together: the server commits all of it or none of it, so
  /// sending the files one at a time would defeat the point.
  ///
  /// [repeatedFields] are sent once per entry, in order, so a list of values
  /// lines up with the files positionally -- which is how each document is
  /// paired with its type.
  static Future<Map<String, dynamic>> sendMany({
    required String path,
    required List<PickedFile> files,
    String fileFieldName = 'files',
    Map<String, String> fields = const {},
    Map<String, List<String>> repeatedFields = const {},
  }) async {
    final normalized = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('${AppConstants.apiBaseUrl}$normalized');
    final request = http.MultipartRequest('POST', uri);

    final token = SessionManager.instance.token;
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    request.fields.addAll(fields);
    for (final entry in repeatedFields.entries) {
      for (final value in entry.value) {
        request.files.add(http.MultipartFile.fromString(entry.key, value));
      }
    }
    for (final file in files) {
      request.files.add(
        http.MultipartFile.fromBytes(fileFieldName, file.bytes, filename: file.name),
      );
    }

    http.Response response;
    try {
      response = await http.Response.fromStream(
        await request.send(),
      ).timeout(const Duration(seconds: 120));
    } catch (_) {
      throw const ApiException('Upload failed. Check your connection and try again.');
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return {};
      try {
        final decoded = jsonDecode(response.body);
        return decoded is Map<String, dynamic> ? decoded : {};
      } catch (_) {
        return {};
      }
    }
    throw ApiException(_errorMessage(response), statusCode: response.statusCode);
  }

  static String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
      if (decoded is Map && decoded['detail'] is List && (decoded['detail'] as List).isNotEmpty) {
        final first = (decoded['detail'] as List).first;
        if (first is Map && first['msg'] is String) return first['msg'] as String;
      }
    } catch (_) {
      // fall through
    }
    return switch (response.statusCode) {
      400 => 'That file was rejected. Please try a different one.',
      401 => 'Please log in again.',
      403 => 'You do not have permission to upload that.',
      409 => 'That conflicts with what is already uploaded.',
      413 => 'That file is too large.',
      _ => 'Upload failed. Please try again.',
    };
  }
}
