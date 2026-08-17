# MicroLink

AI and GPS Powered Smart Micro Business Discovery, Navigation, and
Delivery Support System — Group 13 final year project.

## Structure

```
frontend/     Flutter mobile app
backend/      7 microservices + API Gateway (FastAPI, Postgres, Redis, Docker)
deploy/       Deployment scripts/config (filled in later by DevOps lead)
.github/      CI - runs frontend tests / backend syntax checks automatically
```

Documents (Proposal, SRS, diagrams) live in the separate `microlink-docs`
repo, not here — keeps this repo fast to clone since Word docs don't diff
well in Git.

## Getting started

```bash
# Backend - starts Postgres, Redis, all 7 services, and the API Gateway
cd backend
cp .env.example .env
docker compose up --build

# Frontend - in a second terminal
cd frontend
flutter pub get
flutter run
```

More detail in `frontend/README.md` and `backend/README.md`.

## Who owns what

| Area | Owner |
|---|---|
| `frontend/` | Mobile Frontend Lead |
| `backend/user-service/`, `backend/shop-service/` | Backend Lead |
| `backend/recommendation-service/` | AI/ML Engineer |
| `backend/navigation-service/` | GIS/Navigation Engineer |
| `backend/api-gateway/`, `backend/admin-service/`, `deploy/` | DevOps & Cloud Engineer |
| `backend/delivery-service/`, `backend/crowdsource-service/`, testing | QA & Product Support |

## Team workflow

1. Branch off `main` for every piece of work: `git checkout -b feature/<short-name>`.
2. Work mainly inside your own folder above to avoid stepping on teammates.
3. Push your branch and open a Pull Request — get at least one teammate
   to review before merging. (No one pushes straight to `main`.)
4. CI runs automatically on your PR (see `.github/workflows/`) — frontend
   checks run only when `frontend/` changed, backend checks only when
   `backend/` changed.

See `PROJECT_FIXES_AND_NEXT_STEPS.md` for the history of what was fixed
and what's still TODO.
