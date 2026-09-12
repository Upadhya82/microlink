#!/bin/bash
set -e

# This script runs ONCE, automatically, the first time the Postgres
# container starts. It creates one database per MicroLink microservice.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "postgres" <<-EOSQL
    CREATE DATABASE user_service;
    CREATE DATABASE shop_service;
    CREATE DATABASE ai_service;
    CREATE DATABASE nav_service;
    CREATE DATABASE delivery_service;
    CREATE DATABASE crowdsource_service;
    CREATE DATABASE admin_service;
EOSQL

echo "All 7 MicroLink databases created successfully."
