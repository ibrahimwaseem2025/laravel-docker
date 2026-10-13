# Laravel Docker Project

This project provides a fully Dockerized development environment for a Laravel 12 application using PHP 8.4 FPM, PostgreSQL 16, Redis, and Nginx.

## Project Structure

```
project-root/
├── app/                      # Laravel application code
├── ...
├── docker/
│   ├── nginx/                # Nginx configuration files
│   │   └── nginx.conf
│   ├── php/                  # PHP Dockerfile and setup
│   │   └── Dockerfile
│   └── entrypoint.sh         # Entrypoint script for Laravel setup
├── docker-compose.yml        # Docker Compose service definitions
├── Makefile                  # Dev workflow (make help)
├── .env.example              # Environment variable template
└── README.md
```

## Environment Details

-   **Laravel**: 12.x
-   **PHP**: 8.4 (FPM)
-   **Database**: PostgreSQL 16
-   **Cache**: Redis 7 (Alpine)
-   **Web Server**: Nginx (Alpine)
-   **Orchestration**: Docker Compose or Podman (auto-detected by the Makefile)

## Getting Started

### Prerequisites

Docker (with the compose plugin) **or** Podman (with `podman compose`), plus GNU Make.

### Quick start

```bash
cp .env.example .env   # optional; the entrypoint copies it for you if missing
make up                # build images, start the stack, show status
```

Then visit [http://localhost:8000](http://localhost:8000).

The Makefile auto-detects the compose provider. To force one explicitly:

```bash
make up COMPOSE="podman compose"
make up COMPOSE="docker compose"
```

### Common commands

| Command              | What it does                                        |
|----------------------|-----------------------------------------------------|
| `make up`            | Build and start everything (detached)               |
| `make down`          | Stop containers (keeps data volumes)                |
| `make ps`            | Show container status                               |
| `make logs`          | Follow logs (`LOGS_ARGS="--tail=100 php"` to filter)|
| `make shell`         | Shell inside the PHP container                      |
| `make migrate`       | Apply pending migrations (non-destructive)          |
| `make migrate-fresh CONFIRM=yes` | Drop all tables and re-migrate (destructive) |
| `make seed`          | Seed the database                                   |
| `make assets`        | Build frontend assets (vite) in the container       |
| `make test`          | Run the test suite (in-memory sqlite)               |
| `make debug-php`     | PHP version, extensions, DB/Redis connectivity      |
| `make rebuild CONFIRM=yes` | Wipe volumes, rebuild images, restart         |
| `make artisan c="..."` | Run any artisan command in the container          |

Destructive targets (`migrate-fresh`, `rebuild`, `destroy`) refuse to run without `CONFIRM=yes`.

### ⚙️ Environment Flexibility

On startup, `docker/entrypoint.sh` picks the env file in this order:

1. `.env.docker` (if present) → copied to `.env`
2. else existing `.env`
3. else `.env.example` → copied to `.env`

Inside the `php` container, `docker-compose.yml` sets `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD`, `REDIS_HOST` and `REDIS_CLIENT` explicitly, so the stack works even with a stale local `.env`. These values match the `postgres` and `redis` services in `docker-compose.yml` (`laravel` / `secret` / `laravel-docker`).

### What runs on container startup

`docker/entrypoint.sh` automatically:

- Installs Composer dependencies
- Generates `APP_KEY` only if it is missing (restarts never rotate it)
- Waits for PostgreSQL and Redis **with a 60s timeout**, failing fast with a clear error instead of hanging
- Runs pending migrations (`php artisan migrate --force`) — non-destructive
- Seeds the database only if `RUN_SEEDERS=true`
- Caches Laravel config, routes, and views
- Fixes `storage` and `bootstrap/cache` permissions, then starts PHP-FPM

### Accessing inside the Container

```bash
make shell                      # sh (the image does not include bash)
make artisan c="migrate:status"
```

## Technical Notes

-   **Environment Isolation**: The application runs entirely inside containers, ensuring your host machine stays clean.
-   **File Permissions**: UID/GID synchronization is configurable via `ARG UID`/`ARG GID` in `docker/php/Dockerfile`.
-   **Database**: A PostgreSQL role and database are automatically created based on the `POSTGRES_USER` and `POSTGRES_DB` environment variables.
-   **Redis Integration**: Laravel uses Redis for cache and sessions (`phpredis` extension is compiled into the image).
-   **Podman**: Rootless Podman works out of the box; `podman compose` is detected automatically (or set `COMPOSE="podman compose"`).

## 💡 Troubleshooting

### `FATAL: role "laravel" does not exist` / auth failures

Make sure `.env` matches the `postgres` service in `docker-compose.yml`:

```
DB_DATABASE=laravel-docker
DB_USERNAME=laravel
DB_PASSWORD=secret
```

(`.env.example` already ships with these values, and the `php` service sets them as container environment variables, which take precedence over `.env`.)

### The php container exits on startup

Check the reason with `make logs LOGS_ARGS="php"`. Startup fails fast with an explicit message if PostgreSQL or Redis is unreachable for more than 60 seconds — no silent hanging.

### SELinux hosts (Fedora/RHEL)

The bind mounts in `docker-compose.yml` use the `:z` suffix so Podman/Docker can
relabel the files for the containers. This is a no-op on non-SELinux systems.

### Frontend assets / Vite

Breeze feature tests and any page using `@vite` need built assets. `make test`
builds them automatically on first run; build manually with `make assets`
(Node.js is included in the PHP image).

### Port 8000 already in use

Change the host port in `docker-compose.yml` (`ports: - "8000:80"`) and update `APP_URL` in `.env`.
