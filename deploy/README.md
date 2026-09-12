# Deploy

This folder is for the DevOps & Cloud Engineer to fill in: deployment
scripts, a production-flavoured `docker-compose.prod.yml` (or Kubernetes
manifests if you go that route later), and environment/secrets templates
for whatever hosting platform you pick (AWS, GCP, etc., per the
proposal).

For local development, you don't need anything here yet — use the root
`docker-compose.yml` and `app/` directly (see each folder's own README).
This folder is specifically for *deploying* the app somewhere real, which
is a later step.

Suggested contents once you get to that stage:
- `docker-compose.prod.yml` — production version of the compose file
  (real secrets via environment variables, no debug reloads, etc.)
- `deploy.sh` — the actual deployment script/steps
- `.env.production.example` — template of every environment variable a
  deployment needs, with fake placeholder values (never commit the real
  ones)
