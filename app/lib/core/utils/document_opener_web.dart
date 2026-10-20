import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../network/api_exception.dart';

/// Web: hand the bytes to the browser as a blob and open that in a new tab,
/// so the built-in PDF viewer shows it.
///
/// A blob rather than the document's own URL: the endpoint needs an
/// Authorization header, and a tab the browser opens itself sends none --
/// which is why the document had to be fetched here first. The object URL
/// is released shortly afterwards; revoking it immediately can race the new
/// tab's load on some browsers.
Future<void> openBytes(
  Uint8List bytes, {
  required String fileName,
  String? contentType,
}) async {
  final type = (contentType ?? '').split(';').first.trim();
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: type.isEmpty ? 'application/octet-stream' : type),
  );
  final url = web.URL.createObjectURL(blob);

  final opened = web.window.open(url, '_blank');
  if (opened == null) {
    web.URL.revokeObjectURL(url);
    throw const ApiException(
      'Your browser blocked the document window. Allow pop-ups for this site and try again.',
    );
  }

  // Long enough for the new tab to have read the blob.
  Future<void>.delayed(const Duration(minutes: 1), () {
    web.URL.revokeObjectURL(url);
  });
}
