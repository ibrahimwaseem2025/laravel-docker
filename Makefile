# =============================================================================
# Laravel Docker - local development workflow
# =============================================================================
# Run `make help` to list all targets.
#
# The compose provider is auto-detected (docker compose, then podman compose,
# then docker-compose). Override it explicitly if needed:
#     make up COMPOSE="podman compose"
#
# Destructive targets (migrate-fresh, rebuild, destroy) refuse to run unless
# you pass CONFIRM=yes, e.g.:
#     make rebuild CONFIRM=yes
# =============================================================================

ifeq ($(origin COMPOSE), undefined)
COMPOSE := $(shell \
	if docker compose version >/dev/null 2>&1; then echo "docker compose"; \
	elif podman compose version >/dev/null 2>&1; then echo "podman compose"; \
	else echo "docker-compose"; fi)
endif

CONFIRM ?= no

.DEFAULT_GOAL := help

.PHONY: help up down build ps logs shell artisan migrate migrate-fresh seed \
        key assets test debug-php rebuild destroy

help: ## Show this help
	@echo "Compose provider: $(COMPOSE)"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables: CONFIRM=yes (required by destructive targets),"
	@echo "           c=\"...\" (for artisan), LOGS_ARGS=\"...\" (for logs)"

up: ## Build images and start the stack detached
	# nginx is force-recreated because it caches the php container's IP at
	# startup (nginx does not re-resolve fastcgi_upstream), and compose does
	# not detect changes to bind-mounted config files.
	$(COMPOSE) up -d --build --force-recreate nginx
	@$(COMPOSE) ps

down: ## Stop and remove containers (keeps data volumes)
	$(COMPOSE) down

build: ## Rebuild images without starting containers
	$(COMPOSE) build

ps: ## Show container status
	$(COMPOSE) ps

logs: ## Follow logs; filter with LOGS_ARGS="--tail=100 php"
	$(COMPOSE) logs -f $(LOGS_ARGS)

shell: ## Open a shell in the php container
	$(COMPOSE) exec php sh

artisan: ## Run artisan in the container: make artisan c="migrate:status"
	$(COMPOSE) exec php php artisan $(c)

migrate: ## Apply pending migrations (non-destructive)
	$(COMPOSE) exec php php artisan migrate --force

migrate-fresh: ## DANGER: drops ALL tables and re-migrates. Needs CONFIRM=yes
	@if [ "$(CONFIRM)" != "yes" ]; then \
		echo "migrate-fresh DESTROYS all data in the database."; \
		echo "Re-run with: make migrate-fresh CONFIRM=yes"; \
		exit 1; \
	fi
	$(COMPOSE) exec php php artisan migrate:fresh --force $(if $(SEED),--seed,)

seed: ## Seed the database
	$(COMPOSE) exec php php artisan db:seed --force

key: ## Regenerate APP_KEY (invalidates encrypted data!)
	$(COMPOSE) exec php php artisan key:generate --force

assets: ## Build frontend assets (vite) inside the php container
	$(COMPOSE) exec -T php sh -c 'npm ci --no-audit --no-fund && npm run build'

test: ## Run the test suite (builds assets first if missing; in-memory sqlite)
	$(COMPOSE) exec -T php sh -c 'if [ ! -f public/build/manifest.json ]; then \
		echo "public/build missing, building frontend assets..."; \
		npm ci --no-audit --no-fund >/dev/null && npm run build; fi; \
		php artisan config:clear >/dev/null && \
		env -u DB_HOST -u DB_PORT -u DB_DATABASE -u DB_USERNAME -u DB_PASSWORD \
		-u REDIS_HOST -u REDIS_CLIENT php artisan test'

debug-php: ## Show PHP version, extensions and service connectivity
	$(COMPOSE) exec php php -v
	$(COMPOSE) exec php php artisan --version
	$(COMPOSE) exec php sh -c 'echo "--- extensions ---"; php -m | grep -Ei "pdo_pgsql|pgsql|redis|opcache|pdo_sqlite" || true'
	@echo "--- connectivity ---"
	$(COMPOSE) exec php pg_isready -h postgres -p 5432
	$(COMPOSE) exec php sh -c 'php -r "exit(@fsockopen(hostname: \"redis\", port: 6379, timeout: 2) ? 0 : 1);" && echo "redis: reachable"'

rebuild: ## DANGER: down -v (deletes DB/redis volumes), rebuild, start. Needs CONFIRM=yes
	@if [ "$(CONFIRM)" != "yes" ]; then \
		echo "rebuild DELETES the postgres_data and redis_data volumes (all local data)."; \
		echo "Re-run with: make rebuild CONFIRM=yes"; \
		exit 1; \
	fi
	$(COMPOSE) down -v
	$(COMPOSE) up -d --build

destroy: ## DANGER: down -v and remove locally built images. Needs CONFIRM=yes
	@if [ "$(CONFIRM)" != "yes" ]; then \
		echo "destroy DELETES the postgres_data and redis_data volumes and local images."; \
		echo "Re-run with: make destroy CONFIRM=yes"; \
		exit 1; \
	fi
	$(COMPOSE) down -v --rmi local
