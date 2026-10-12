import '../constants/app_constants.dart';
import '../network/session_manager.dart';

/// Turns whatever the backend put in an image field into a URL the app can
/// actually load.
///
/// Photos come from two places now: uploaded files, which the backend
/// returns as a server-relative path like
/// `/shops/{id}/photos/{id}/file`, and links someone typed in, which are
/// absolute `https://` URLs. An `Image.network()` given the relative form
/// silently renders a broken image, so every image in the app must go
/// through here.
String? mediaUrl(String? raw) {
  if (raw == null) return null;
  final value = raw.trim();
  if (value.isEmpty) return null;
  // Already absolute (an external link, or a data: URI).
  if (value.startsWith('http://') ||
      value.startsWith('https://') ||
      value.startsWith('data:')) {
    return value;
  }
  final base = AppConstants.apiBaseUrl;
  return value.startsWith('/') ? '$base$value' : '$base/$value';
}

/// Headers for an image behind an authenticated endpoint.
///
/// Verification documents are private -- the server only serves them to the
/// owner or an admin -- and `Image.network` sends no Authorization header of
/// its own, so without this the admin review screen asks for every document
/// anonymously and renders a column of broken-image icons.
Map<String, String> authImageHeaders() {
  final token = SessionManager.instance.token;
  return token == null ? const {} : {'Authorization': 'Bearer $token'};
}
