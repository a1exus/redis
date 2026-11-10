SHELL := bash
.SHELLFLAGS := -euo pipefail -c
MAKEFLAGS += --warn-undefined-variables --no-builtin-rules --no-print-directory
.SUFFIXES:
.DELETE_ON_ERROR:
.DEFAULT_GOAL := help

COMPOSE ?= docker compose
SHELLCHECK_IMAGE ?= koalaman/shellcheck:v0.10.0

# Host prerequisites checked by `make doctor` (start_interval needs Engine 25+).
MIN_ENGINE ?= 25
MIN_COMPOSE ?= 2.24
TRAEFIK_NETWORK ?= traefik_traefik

# Optional command-line arguments: SERVICE=redisinsight, FORCE=1.
SERVICE ?=
FORCE ?=

##@ Help

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage: make \033[36m<target>\033[0m\n"} \
		/^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2 } \
		/^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) }' $(MAKEFILE_LIST)

##@ Lifecycle

.PHONY: up
up: ## Start services and wait for healthchecks
	$(COMPOSE) up -d --wait

.PHONY: down
down: ## Stop services, keep data
	$(COMPOSE) down

# Sequential on purpose: `restart: down up` would race under `make -j`.
.PHONY: restart
restart: ## Restart everything
	@$(MAKE) down
	@$(MAKE) up

.PHONY: pull
pull: ## Pull the configured images (re-run `make up` to apply)
	$(COMPOSE) pull

.PHONY: clean
clean: ## Stop services AND remove volumes (DESTROYS DATA; FORCE=1 skips the prompt)
	@if [ -z "$(FORCE)" ]; then \
		read -r -p "Remove containers AND volumes (all data is lost)? [y/N] " answer; \
		[ "$$answer" = y ] || { echo "aborted"; exit 1; }; \
	fi
	$(COMPOSE) down --volumes

.PHONY: ps
ps: ## Show service status
	$(COMPOSE) ps

##@ Interaction

.PHONY: logs
logs: ## Tail logs (all services, or SERVICE=redis)
	$(COMPOSE) logs -f --tail=100 $(SERVICE)

.PHONY: cli
cli: ## Open redis-cli inside the redis container
	$(COMPOSE) exec redis redis-cli

.PHONY: shell
shell: ## Open a shell in a container (SERVICE=redis by default)
	$(COMPOSE) exec $(or $(SERVICE),redis) sh

.PHONY: ui
ui: ## Print RedisInsight URL (routed by Traefik)
	@echo "RedisInsight: http://$${REDISINSIGHT_HOST:-redisinsight.localhost}"

##@ Validation

.PHONY: doctor
doctor: ## Check host prerequisites (Docker, Compose, Traefik network)
	@command -v docker >/dev/null || { echo "doctor: docker not found"; exit 1; }
	@engine=$$(docker version --format '{{.Server.Version}}') \
		|| { echo "doctor: cannot reach the Docker daemon"; exit 1; }; \
	[ "$${engine%%.*}" -ge $(MIN_ENGINE) ] \
		|| { echo "doctor: Docker Engine $$engine < $(MIN_ENGINE) (healthcheck start_interval unsupported)"; exit 1; }; \
	echo "docker engine $$engine: OK"
	@compose=$$($(COMPOSE) version --short) \
		|| { echo "doctor: docker compose plugin not found"; exit 1; }; \
	compose=$${compose#v}; \
	[ "$$(printf '%s\n' $(MIN_COMPOSE) "$$compose" | sort -V | head -n1)" = "$(MIN_COMPOSE)" ] \
		|| { echo "doctor: docker compose $$compose < $(MIN_COMPOSE)"; exit 1; }; \
	echo "docker compose $$compose: OK"
	@if [ -f docker-compose.override.yaml ]; then \
		docker network inspect $(TRAEFIK_NETWORK) >/dev/null 2>&1 \
			|| { echo "doctor: external network '$(TRAEFIK_NETWORK)' not found; start Traefik first"; exit 1; }; \
		echo "network $(TRAEFIK_NETWORK): OK"; \
	fi

.PHONY: config
config: ## Validate and render the resolved compose config
	@$(COMPOSE) config -q && echo "docker-compose.yaml: OK"

.PHONY: check-env
check-env: ## Verify .env.example matches the defaults built into the compose files
	@diff <($(COMPOSE) --env-file /dev/null config) <($(COMPOSE) --env-file .env.example config) \
		&& echo ".env.example: matches compose defaults"

.PHONY: smoke
smoke: ## Smoke-verify: PING + each bundled module + UI healthy
	@./scripts/smoke.sh

.PHONY: lint
lint: ## Shellcheck scripts/ (runs in Docker)
	@docker run --rm -v "$$PWD":/mnt -w /mnt $(SHELLCHECK_IMAGE) scripts/*.sh && echo "shellcheck: OK"

.PHONY: check
check: config lint check-env ## Static checks: config, lint, .env.example drift

.PHONY: scan
scan: ## Scan pinned images for CVEs (uses docker scout if available)
	@if docker scout --help >/dev/null 2>&1; then \
		for image in $$($(COMPOSE) config --images); do docker scout cves "$$image"; done; \
	else \
		echo "docker scout not available — install Docker Desktop ≥ 4.17 or 'docker scout' CLI"; \
	fi
