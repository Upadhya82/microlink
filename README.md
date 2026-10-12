# MicroLink

AI and GPS Powered Smart Micro Business Discovery, Navigation, and
Delivery Support System — Group 13 final year project.

## Structure

```
app/          Flutter mobile app
services/     7 microservices (FastAPI, Postgres, Redis, Docker)
api-gateway/  Single entry point the app talks to
infra/        Local dev infra: init-db scripts, alternate compose file
deploy/       Deployment scripts/config (filled in later by DevOps lead)
.github/      CI - runs app tests / service syntax checks automatically
```

Documents (Proposal, SRS, diagrams) live in the separate `microlink-docs`
repo, not here — keeps this repo fast to clone since Word docs don't diff
well in Git.

## Getting started

```bash
# Backend - starts Postgres, Redis, all 7 services, and the API Gateway
cp .env.example .env
# edit .env: set JWT_SECRET (>= 32 chars, e.g. `openssl rand -hex 32`) and POSTGRES_PASSWORD
docker compose up --build

# Frontend - in a second terminal
cd app
flutter pub get
flutter run
```

`docker compose up` also merges `docker-compose.override.yml`, which publishes
Postgres, Redis and the individual service ports for local debugging. **On a
server deploy with `docker compose -f docker-compose.yml up -d --build`** so only
the API gateway (port 8080) is reachable, and put HTTPS in front of it.

More detail in `app/README.md` and `services/README.md`.

## Who owns what

| Area | Owner |
|---|---|
| `app/` | Mobile Frontend Lead |
| `services/user-service/`, `services/shop-service/` | Backend Lead |
| `services/recommendation-service/` | AI/ML Engineer |
| `services/navigation-service/` | GIS/Navigation Engineer |
| `api-gateway/`, `services/admin-service/`, `deploy/` | DevOps & Cloud Engineer |
| `services/delivery-service/`, `services/crowdsource-service/`, testing | QA & Product Support |

## Team workflow

1. Branch off `main` for every piece of work: `git checkout -b feature/<short-name>`.
2. Work mainly inside your own folder above to avoid stepping on teammates.
3. Push your branch and open a Pull Request — get at least one teammate
   to review before merging. (No one pushes straight to `main`.)
4. CI runs automatically on your PR (see `.github/workflows/`) — app
   checks run only when `app/` changed, service checks only when
   `services/` or `api-gateway/` changed.

See `PROJECT_FIXES_AND_NEXT_STEPS.md` for the history of what was fixed
and what's still TODO.
