#!/bin/bash
# Runs automatically the first time the postgres container starts.
# Creates one database per microservice, so each service still gets its
# own isolated database (the "Database per Service" pattern) even though
# they all share one Postgres server -- much lighter on a student laptop
# than running 7 separate Postgres containers. If you later deploy to
# real infrastructure, point each service's DATABASE_URL at its own
# Postgres instance instead and this script becomes unnecessary.
set -e

for db in user_db shop_db recommendation_db navigation_db delivery_db crowdsource_db admin_db; do
  echo "Creating database: $db"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE $db;
EOSQL
done
