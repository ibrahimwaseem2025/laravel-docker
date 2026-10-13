#!/bin/sh

set -eu

# The container runs as root (see "user: root" in docker-compose.yml).
# Tell Composer to proceed without its interactive root warning/prompt.
export COMPOSER_ALLOW_SUPERUSER=1

# Copy env file if it doesn't exist
if [ -f "/var/www/.env.docker" ]; then
  echo "Using .env.docker"
  cp /var/www/.env.docker /var/www/.env
elif [ ! -f /var/www/.env ]; then
  echo "No .env found. Copying from .env.example"
  cp /var/www/.env.example /var/www/.env
else
  echo "Using existing .env"
fi

if command -v git >/dev/null 2>&1; then
  git config --global --add safe.directory /var/www
fi

# Install dependencies
composer install \
    --no-interaction \
    --no-progress \
    --prefer-dist \
    --optimize-autoloader

# Generate an application key ONLY when one is missing.
# (Unconditional "key:generate" rotated APP_KEY on every restart, which
# invalidated encrypted sessions/data each time the container started.)
if ! grep -q '^APP_KEY=..*' /var/www/.env 2>/dev/null; then
  echo "APP_KEY missing, generating..."
  php artisan key:generate --force
fi

# Read connection settings from the environment (docker-compose sets them;
# the defaults keep the script usable outside compose as well).
DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
REDIS_HOST="${REDIS_HOST:-redis}"
REDIS_PORT="${REDIS_PORT:-6379}"

# Wait for PostgreSQL with a HARD TIMEOUT. The previous version looped
# forever ("while ! pg_isready ...; do sleep 1; done"), so an unreachable
# database made the container hang silently and php-fpm never started.
echo "Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}..."
tries=0
until pg_isready -h "$DB_HOST" -p "$DB_PORT" -q; do
  tries=$((tries + 1))
  if [ "$tries" -ge 60 ]; then
    echo "ERROR: PostgreSQL not reachable at ${DB_HOST}:${DB_PORT} after 60s" >&2
    exit 1
  fi
  sleep 1
done
echo "PostgreSQL is up!"

# Wait for Redis with the same hard timeout (cache:clear below needs it).
echo "Waiting for Redis at ${REDIS_HOST}:${REDIS_PORT}..."
tries=0
until php -r "exit(@fsockopen(hostname: '${REDIS_HOST}', port: ${REDIS_PORT}, timeout: 2) ? 0 : 1);"; do
  tries=$((tries + 1))
  if [ "$tries" -ge 60 ]; then
    echo "ERROR: Redis not reachable at ${REDIS_HOST}:${REDIS_PORT} after 60s" >&2
    exit 1
  fi
  sleep 1
done
echo "Redis is up!"

# Apply pending migrations. NON-DESTRUCTIVE and idempotent: safe to run on
# every start. (The old "migrate:fresh" wiped all data on each boot and
# failed outright with the template credentials, killing the container
# under "set -e" before php-fpm could start.)
php artisan migrate --force

# Seeding is opt-in: RUN_SEEDERS=true
if [ "${RUN_SEEDERS:-false}" = "true" ]; then
  echo "RUN_SEEDERS=true, seeding database..."
  php artisan db:seed --force
fi

php artisan config:cache
php artisan route:cache
php artisan view:cache

# Fix permissions on runtime directories (only meaningful when root)
if [ "$(id -u)" = "0" ]; then
  chown -R "$(id -u):$(id -g)" storage bootstrap/cache
  # u+rwX/go+rw: capital X only sets the exec bit on directories, so files
  # (e.g. .gitignore) on the bind mount don't get spurious exec bits
  chmod -R u+rwX,go+rw storage bootstrap/cache
fi

php artisan cache:clear

# Start PHP-FPM
exec docker-php-entrypoint php-fpm
