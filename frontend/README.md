# MicroLink — Frontend (Flutter)

## Running it

```bash
flutter pub get
flutter run
```

The app now boots into the **Login** screen (previously it booted into a
static "Welcome to MicroLink!" text with no way to reach any real screen).
Every screen is registered in `lib/core/utils/app_router.dart` — that's the
one file to touch when you add a new screen so it's actually reachable.

By default the app talks to the backend at `http://10.0.2.2:8080`, which
is the special address the Android emulator uses to reach `localhost` on
your development machine — i.e. it expects the backend (see `../backend/`)
to be running locally via `docker compose up`. Change
`AppConstants.apiGatewayBaseUrl` in `lib/core/constants/app_constants.dart`
if you're testing on a real device or a deployed backend.

## What changed

- `main.dart` now sets up real routing, light/dark theme, and boots into
  Login instead of a placeholder screen.
- Added `lib/core/` — a shared network client (`api_client.dart`, uses
  Dio and auto-attaches the auth token), constants, a light/dark theme,
  shared form validators, and the route table. These were empty folders
  before.
- Added a real `login_screen.dart` — there wasn't one.
- Filled in the screen files that existed but were empty (0 bytes):
  shop discovery, shop details, recommendations, navigation, delivery
  tracking, driver home, add-new-shop, report-road-issue. They're
  functional (they call the backend and show real states — loading,
  empty, error) but several have `TODO` comments where a feature needs
  more work (see each file).
- Added two screens that didn't exist for two SRS features that had no
  UI at all: Shop Owner Dashboard and Admin Dashboard (currently just
  navigable menus — wire each item up as the backend endpoints are
  ready).
- `pubspec.yaml`: added the packages the SRS/proposal actually require
  (maps, GPS, text-to-speech, file picking, secure token storage, state
  management, offline detection) — before, only `http` was there.
- `test/widget_test.dart` was still the default Flutter counter-app test
  and would fail immediately since `main.dart` no longer has a counter.
  Replaced it with a smoke test that matches what the app now does.

## Still to do (see TODO comments in the code for exact locations)

1. **Google Maps / Mapbox setup**: `google_maps_flutter` is in
   `pubspec.yaml` but needs platform configuration — an API key added to
   `android/app/src/main/AndroidManifest.xml` and `ios/Runner/AppDelegate.swift`
   (see the package's own setup docs). `live_map_screen.dart` currently
   only shows your GPS coordinates as a placeholder.
2. **Real file picking**: `register_screen.dart`, `add_new_shop_screen.dart`
   etc. use fake hardcoded filenames for document/photo uploads. Swap in
   the `file_picker` package (already added) and send the real file to a
   backend upload endpoint (see backend README's TODO list).
3. **State management**: `provider` is added but not used yet. Right now
   login state, language, and theme aren't actually remembered between
   screens/app restarts — wire that up (store the choice with
   `shared_preferences`, read it in `main.dart` before building
   `MaterialApp`).
4. **Localization strings**: the UI is English-only text right now.
   `flutter_localizations` + `intl` are added — next step is externalizing
   strings into `.arb` files for English/Sinhala/Tamil.
5. **Voice guidance**: `flutter_tts` is added but not called from any
   screen yet.
