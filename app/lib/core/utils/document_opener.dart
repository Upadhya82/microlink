import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../network/api_exception.dart';
import '../network/session_manager.dart';
import 'media_url.dart';
// Opening a file is the one part that cannot be shared: the web build hands
// the bytes to the browser, every other build writes them down and asks the
// system to open them.
import 'document_opener_io.dart'
    if (dart.library.js_interop) 'document_opener_web.dart' as platform;

/// Opens a verification document, PDF or image, from an authenticated
/// endpoint (item 9).
///
/// Documents are private: the server only serves them to their owner or an
/// admin, and a plain `Image.network` or a tapped link sends no token. So
/// the bytes are fetched here with the session token and handed to the
/// platform afterwards, which also means a PDF can finally be opened --
/// the admin review screen used to say "PDF preview is not available in the
/// app" and leave it there.
class DocumentOpener {
  DocumentOpener._();

  /// How long to wait for a document before giving up. Longer than an
  /// ordinary API call: these are whole files on a phone connection.
  static const Duration timeout = Duration(seconds: 30);

  /// Fetches [path] with the session token and opens it.
  ///
  /// [path] is the server-relative document path, e.g.
  /// `/users/documents/{id}/file`. Throws [ApiException] with a
  /// user-presentable message on any failure, including "not signed in" --
  /// documents stay behind login.
  static Future<void> open({
    required String path,
    String? fileName,
    String? contentType,
  }) async {
    final token = SessionManager.instance.token;
    if (token == null) {
      throw const ApiException('Please log in again to open this document.');
    }
    final url = mediaUrl(path);
    if (url == null) {
      throw const ApiException('That document is no longer available.');
    }

    final http.Response response;
    try {
      response = await http
          .get(Uri.parse(url), headers: {'Authorization': 'Bearer $token'})
          .timeout(timeout);
    } catch (_) {
      throw const ApiException('Could not reach the server. Please try again.');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw ApiException(
        'You are not allowed to open this document.',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode == 404) {
      throw ApiException(
        'That document is no longer available.',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode >= 400) {
      throw ApiException(
        'Could not open that document. Please try again.',
        statusCode: response.statusCode,
      );
    }

    // The server tells us what it actually stored; the caller's guess is
    // only a fallback for an older response.
    final servedType = response.headers['content-type'] ?? contentType;
    await platform.openBytes(
      Uint8List.fromList(response.bodyBytes),
      fileName: suggestedFileName(
        headerValue: response.headers['content-disposition'],
        fallbackName: fileName,
        contentType: servedType,
      ),
      contentType: servedType,
    );
  }
}

/// The name to open the document under.
///
/// Prefers what the server put in `Content-Disposition` (item 9 added it),
/// falls back to the stored file name, and always ends up with an extension
/// -- Android decides which app can open a file from its extension, so a
/// nameless PDF simply would not open.
String suggestedFileName({
  String? headerValue,
  String? fallbackName,
  String? contentType,
}) {
  final fromHeader = _nameFromDisposition(headerValue);
  final base = (fromHeader ?? fallbackName ?? '').trim();
  final cleaned = _sanitise(base);
  final extension = _extensionFor(contentType);
  if (cleaned.isEmpty) return 'document$extension';
  if (extension.isEmpty || cleaned.toLowerCase().endsWith(extension)) {
    return cleaned;
  }
  final stem = cleaned.contains('.')
      ? cleaned.substring(0, cleaned.lastIndexOf('.'))
      : cleaned;
  return '${stem.isEmpty ? 'document' : stem}$extension';
}

/// Reads the filename out of a Content-Disposition header, preferring the
/// `filename*` form so a Sinhala or Tamil name survives.
String? _nameFromDisposition(String? headerValue) {
  if (headerValue == null || headerValue.isEmpty) return null;

  final extended = RegExp(
    "filename\\*=(?:UTF-8|utf-8)''([^;]+)",
  ).firstMatch(headerValue);
  if (extended != null) {
    try {
      return Uri.decodeComponent(extended.group(1)!.trim());
    } catch (_) {
      // Malformed percent-encoding: fall through to the plain form.
    }
  }

  final plain = RegExp('filename="?([^";]+)"?').firstMatch(headerValue);
  return plain?.group(1)?.trim();
}

/// Strips anything that would make this an unsafe or invalid file name.
String _sanitise(String name) {
  final base = name.replaceAll('\\', '/').split('/').last;
  final cleaned = base.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '').trim();
  return (cleaned == '.' || cleaned == '..') ? '' : cleaned;
}

String _extensionFor(String? contentType) {
  final type = (contentType ?? '').split(';').first.trim().toLowerCase();
  return switch (type) {
    'application/pdf' => '.pdf',
    'image/jpeg' => '.jpg',
    'image/png' => '.png',
    'image/webp' => '.webp',
    _ => '',
  };
}

/// True when this document is a PDF, so a screen can offer Open instead of
/// trying to draw a thumbnail of it.
bool isPdfContentType(String? contentType) =>
    (contentType ?? '').toLowerCase().contains('pdf');
