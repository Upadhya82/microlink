# MicroLink — Fixes Applied & Next Steps

This file explains everything that was changed in this pass, and the one
manual step you need to do yourself (deleting a duplicate git folder — no
tool can safely do this for you, see below).

## 1. Fix the duplicate Git repository (do this first, manually)

`E:\MicroLink13\.git` and `E:\MicroLink13\frontend\.git` were both full,
independent clones of the same GitHub repo
(`https://github.com/MicroLink13/frontend-flutter.git`). Keep the one
inside `frontend\` (that's your real working copy) and delete the outer
one at the `MicroLink13` root.

**Before you delete anything: make sure everything is pushed / committed**
you don't want to lose. Then, open PowerShell in `E:\MicroLink13` and run:

```powershell
Remove-Item -Recurse -Force .git
```

That only removes the *outer* repo's Git metadata — it does not touch any
of your files, and it does not touch `frontend\.git`. After this,
`E:\MicroLink13` is just a plain folder containing your `frontend\` (now a
normal Git repo) and your new `backend\` folder — you'll set up Git for
`backend\` separately (see its own section below) or add it into the same
`frontend` repo's history if you'd rather keep one repo for everything.

## 2. Frontend fixes (already applied to the files in this delivery)

- `main.dart` now boots into a real Login screen and wires up every
  screen through a proper route table, instead of showing a static
  "Welcome to MicroLink!" text with nothing reachable.
- Added the missing `core/` files (network client, theme, constants,
  validators) — those folders existed but were completely empty.
- Added a Login screen (there wasn't one).
- Filled in 8 screen files that existed as empty (0-byte) placeholders
  with working versions that call the backend.
- Added two screens for features that had no UI at all: Shop Owner
  Dashboard and Admin Dashboard.
- Added the missing dependencies to `pubspec.yaml` (maps, GPS,
  text-to-speech, file picker, secure storage, state management, offline
  detection) — only `http` was there before.
- Fixed `test/widget_test.dart`, which was still the unmodified Flutter
  counter-app demo test and would have failed the instant anyone ran
  `flutter test`.

Full details: `frontend/README.md`.

## 3. New backend — full microservices build

There was no backend code anywhere in the project folder before this.
Built one matching the architecture in your proposal: 7 independent
services (User, Shop, Recommendation, Navigation, Delivery, Crowdsource,
Admin) behind an API Gateway, each with its own database, communicating
through the gateway and through events (Redis pub/sub) rather than
calling each other's databases directly. Comes with a `docker-compose.yml`
that starts the whole thing with one command.

Full details, how to run it, and exactly what's real vs. still a stub:
`backend/README.md`.

## 4. What you (and your team) need to do next

**To get it running:**
1. Do the Git cleanup in section 1 above.
2. Install Docker Desktop, then `cd backend && cp .env.example .env && docker compose up --build`.
3. `cd frontend && flutter pub get && flutter run` (Android emulator by
   default talks to the backend automatically via `10.0.2.2:8080`).

**To move from scaffold to a real submission**, in roughly the order it
unblocks the most people on your 6-person team:

1. **Maps API key** (GIS/Navigation lead) — get a Google Maps Platform or
   Mapbox key, add it to `backend/.env` and to the Flutter Android/iOS
   config, replace the straight-line distance estimate in
   `navigation-service` with a real Directions API call.
2. **File uploads** (Backend lead) — add a real upload endpoint (object
   storage) so ID photos / business registration docs / shop photos are
   actually stored, and connect `file_picker` on the Flutter side to it.
3. **Real recommendation logic** (AI/ML engineer) — the `interactions`
   table in `recommendation-service` is already collecting the data you need;
   replace the current "sort by trust score" placeholder with an actual
   collaborative-filtering model.
4. **Auth enforcement** (Backend lead) — most endpoints don't check the
   JWT yet; add role checks to admin-only and owner-only routes.
5. **Notifications** (whoever picks it up) — several events are already
   published (order status changes, shop alerts) but nothing sends a push
   notification yet. Needs a small notification service or a Firebase
   Cloud Messaging integration that subscribes to those events.
6. **Testing** (QA lead) — there's currently one smoke test in the whole
   project. The SRS calls for unit/integration/system/UAT testing; start
   with unit tests per service (FastAPI's `TestClient` makes this easy)
   and widget tests for the Flutter screens.
7. **Resolve the SRS payment contradiction** — section 5.6's
   stimulus/response describes a payment flow, but REQ-DELIV-3 explicitly
   excludes payment. Decide which is correct as a team and fix the SRS
   document; the backend currently follows REQ-DELIV-3 (no payment).
8. **Fix the SRS structural issues** flagged earlier (empty "Typical
   course events" in all 35 use case tables, heading-level errors in
   section 6, the Tamil-vs-two-languages mismatch between the Proposal
   and SRS) before treating either document as final.

None of the above needs to happen before your next milestone necessarily
— the scaffold is designed so each team member can pick up one service or
one screen and build on structure that's already wired together and
already talking to a real (if simple) backend.
