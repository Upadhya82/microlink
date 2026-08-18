# MicroLink — Local Database Setup

This gives every team member the exact same PostgreSQL setup on their own
laptop, with no shared server and no AWS needed yet.

## One-time setup (each person does this once)

1. Install Docker Desktop: https://www.docker.com/products/docker-desktop/
   (Windows, Mac, and Linux versions all available. Just install and open it —
   you'll see a whale icon running in your system tray when it's ready.)

2. Clone the team repo and make sure these 3 files are in the project root:
   - docker-compose.yml
   - init-db.sh
   - .env.example

3. Open a terminal in that folder and run:
   docker-compose up -d

4. Wait about 10 seconds, then check it worked:
   docker ps
   (You should see "microlink-postgres" listed as running.)

That's it — you now have Postgres running locally with 7 databases already
created: user_service, shop_service, ai_service, nav_service,
delivery_service, crowdsource_service, admin_service.

## Connecting your module

In your service's folder, copy .env.example to .env, and uncomment only the
line for YOUR module. For example, the Shop Discovery developer's .env
should contain only:

DATABASE_URL=postgresql://admin:devpassword@localhost:5432/shop_service

## Everyday commands

- Start the database:     docker-compose up -d
- Stop the database:      docker-compose down
- Stop AND wipe all data: docker-compose down -v
- View logs:               docker logs microlink-postgres
- Open a SQL prompt:       docker exec -it microlink-postgres psql -U admin -d shop_service

## Checking your data with a GUI (optional but recommended)

Install a free tool like DBeaver or pgAdmin, and connect using:
- Host: localhost
- Port: 5432
- User: admin
- Password: devpassword
- Database: (pick the one for your module)

## Managing schema changes (tables, columns) — Alembic

Each service should use Alembic to track database changes as files, so
teammates can pull your changes from GitHub and apply them with one command
instead of manually running SQL. Ask if you want a walkthrough for this once
your first table is ready.
