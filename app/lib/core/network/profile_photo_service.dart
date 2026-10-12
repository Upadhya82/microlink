import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../constants/app_constants.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'multipart_upload.dart';
import 'session_manager.dart';

/// The signed-in user's profile photo.
///
/// There is no avatar column on the user record; a profile photo is stored
/// as a `profile_photo` user document, which the backend already accepts from
/// any signed-in account and replaces on re-upload. This wraps that so the
/// rest of the app can ask for "my photo" without knowing it is a document.
///
/// The bytes are held rather than a URL because the document endpoint is
/// authenticated -- these live alongside identity documents, so they are
/// deliberately not public, and an `Image.network` with no Authorization
/// header would just 404.
///
/// A [ChangeNotifier] like [SessionManager], so an avatar anywhere in the
/// app updates the moment a new photo is uploaded.
class ProfilePhotoService extends ChangeNotifier {
  ProfilePhotoService._();
  static final ProfilePhotoService instance = ProfilePhotoService._();

  static const String docType = 'profile_photo';

  Uint8List? _bytes;
  bool _loading = false;

  /// The photo, or null when there is none (or it has not loaded yet).
  Uint8List? get bytes => _bytes;

  bool get isLoading => _loading;

  /// Fetches the photo if the user has one. Safe to call repeatedly; it is a
  /// no-op while a fetch is already running.
  ///
  /// Failures are swallowed on purpose: a missing avatar is not worth an
  /// error in front of someone who was doing something else.
  Future<void> load() async {
    if (_loading || !SessionManager.instance.isLoggedIn) return;
    _loading = true;
    try {
      final response = await ApiClient.instance.get('/users/me/documents');
      final rows = response is Map<String, dynamic> ? response['items'] : response;
      if (rows is! List) return;

      final match = rows.cast<Map<String, dynamic>>().where(
            (d) => d['doc_type'] == docType,
          );
      if (match.isEmpty) {
        _bytes = null;
        return;
      }

      final fetched = await _fetchFile(match.first['id'] as String);
      if (fetched != null) _bytes = fetched;
    } catch (_) {
      // Leave whatever was already shown rather than blanking it.
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  /// Uploads [file] as the profile photo, replacing any previous one, and
  /// shows it immediately.
  ///
  /// Throws [ApiException] on failure -- unlike [load], this one was asked
  /// for, so the caller must be able to say it did not work.
  Future<void> upload(PickedFile file) async {
    await MultipartUpload.send(
      path: '/users/me/documents',
      file: file,
      fields: const {'doc_type': docType},
    );
    // Show the chosen image straight away instead of waiting for a round
    // trip; the server re-encodes it, but not in a way anyone would see.
    _bytes = file.bytes;
    notifyListeners();
  }

  /// Removes the photo. Returns false when there was nothing to remove.
  Future<bool> remove() async {
    final response = await ApiClient.instance.get('/users/me/documents');
    final rows = response is Map<String, dynamic> ? response['items'] : response;
    if (rows is! List) return false;
    final match = rows.cast<Map<String, dynamic>>().where(
          (d) => d['doc_type'] == docType,
        );
    if (match.isEmpty) return false;

    await ApiClient.instance.delete('/users/me/documents/${match.first['id']}');
    _bytes = null;
    notifyListeners();
    return true;
  }

  /// Dropped on logout so the next person to sign in on this device does not
  /// briefly see the last one's face.
  void clear() {
    _bytes = null;
    notifyListeners();
  }

  Future<Uint8List?> _fetchFile(String documentId) async {
    final token = SessionManager.instance.token;
    if (token == null) return null;
    final uri = Uri.parse(
      '${AppConstants.apiBaseUrl}/users/documents/$documentId/file',
    );
    final response = await http
        .get(uri, headers: {'Authorization': 'Bearer $token'})
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return null;
    return response.bodyBytes;
  }
}
