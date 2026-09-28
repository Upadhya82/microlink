# MicroLink Services — Microservices

This implements the architecture described in the project proposal: a
Client-Server model made of independent microservices, each with its own
database, talking to each other only through an API Gateway or through
events — never by directly calling into another service's database.

## Services

| Service | Folder | Covers (from the SRS) |
|---|---|---|
| API Gateway | `api-gateway/` | Single entry point the Flutter app talks to; routes each request to the right service |
| User Service | `user-service/` | User Management — register, login, roles, verification, language/theme prefs (REQ-AUTH-*, REQ-PERS-*) |
| Shop Service | `shop-service/` | Smart Shop Discovery + Shop Owner Management (REQ-SEARCH-*, REQ-SHOP-*) |
| Recommendation Service | `recommendation-service/` | AI-Based Recommendations (REQ-AI-*) |
| Navigation Service | `navigation-service/` | Navigation & Route Optimization (REQ-NAV-*) |
| Delivery Service | `delivery-service/` | Self Driver Participation + Delivery Assistance (REQ-AGENT-*, REQ-DELIV-*) |
| Crowdsource Service | `crowdsource-service/` | Crowd-Sourced Data Collection (REQ-CROWD-*) |
| Admin Service | `admin-service/` | System Monitoring & Administration (REQ-ADMIN-*) |

Each service is its own FastAPI app, with its own SQLAlchemy models and its
own database (`user_db`, `shop_db`, etc. — all hosted on one Postgres
container for now, see `../infra/`, but logically fully separate).

## How the pieces talk to each other

- **App → Gateway → Service**: the Flutter app only ever calls the API
  Gateway (`http://<host>:8080`). The gateway looks at the path
  (`/api/users/...`, `/api/shops/...`, etc.) and forwards the request to
  the right service. Add a new backend feature = add a route to the
  relevant service; you never touch the gateway's routing table itself
  unless you're adding a whole new service.
- **Service → Service (rare, synchronous)**: e.g. recommendation-service
  calls shop-service directly over HTTP to get the shop list. Use this
  sparingly — only when a service genuinely needs an answer right now.
- **Service → Service (events, the default)**: most cross-service
  reactions go through Redis pub/sub (`app/event_bus.py` in every
  service). E.g. when shop-service changes a shop's status it calls
  `publish_event("shop.status_changed", {...})` and doesn't know or care
  who's listening. `admin-service` is the example that actually listens
  (see `admin-service/app/main.py`) and logs every event for the System
  Activity Monitor (REQ-ADMIN-4).

## Running it locally

You need Docker Desktop installed.

```bash
cp .env.example .env      # then edit .env if you want, defaults work for local dev
docker compose up --build
```

This starts Postgres, Redis, all 7 services, and the gateway. First boot
will take a minute while images build. Once it's up:

- Gateway: http://localhost:8080/health
- Each service directly (for debugging only — the app should never call
  these ports): user-service `:8001`, shop-service `:8002`,
  recommendation-service `:8003`, navigation-service `:8004`,
  delivery-service `:8005`, crowdsource-service `:8006`,
  admin-service `:8007`.
- Interactive API docs for any service: `http://localhost:<port>/docs`
  (FastAPI generates this automatically — great for testing endpoints by
  hand before wiring up the Flutter side).

Point the Flutter app at the gateway by setting
`AppConstants.apiGatewayBaseUrl` in
`app/lib/core/constants/app_constants.dart` — it already defaults to
`http://10.0.2.2:8080`, which is correct if you're running the Android
emulator on the same machine as Docker.

## What's real vs. what's a stub

Every endpoint is wired up, connects to a real database, and returns real
responses shaped the way the SRS describes. What's **not** implemented yet
(clearly marked with `TODO` comments in the code):

- **Real AI recommendations** (`recommendation-service`) — currently
  sorts by trust score, doesn't actually learn from behaviour yet. The
  `interactions` table is already being written to, ready for whoever
  builds the real model.
- **Real map/routing data** (`navigation-service`) — currently returns a
  straight-line distance estimate. Needs a Google Maps or Mapbox API key
  and a real Directions API call.
- **File uploads** (ID photos, business registration docs, etc.) — the
  app sends filenames only. Needs an actual file upload endpoint backed
  by object storage (S3, GCS, or similar).
- **Push notifications** ("Notify Customer", closure alerts) — events are
  published (`order.status_changed`, `shop.alert_created`, etc.) but
  nothing currently sends a push notification when they fire. That's a
  new small "notification service" (or a Firebase Cloud Messaging
  integration) that subscribes to those events.
- **Auth enforcement on protected endpoints** — login issues a real JWT,
  but most endpoints don't check it yet. Add a dependency that decodes
  the token (see `user-service/app/auth.py`) and checks the role before
  doing admin-only actions.
- **Cross-service data sync** — e.g. shop-service's `trust_score` field
  should update automatically when crowdsource-service records new
  feedback. Right now they're separate; wire this up via the event bus
  (crowdsource-service already publishes `feedback.submitted`).

## Known contradiction in the SRS worth resolving

Section 5.6 ("Delivery Assistance Request") describes a payment flow in
its stimulus/response walkthrough, but REQ-DELIV-3 explicitly says no
payment/cart functionality is included. This scaffold follows REQ-DELIV-3
(no payment fields in `delivery-service`). Decide as a team which one is
actually correct and update the SRS to match — see the note in
`delivery-service/app/models.py`.
