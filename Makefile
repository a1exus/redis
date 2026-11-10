SHELL := bash
.SHELLFLAGS := -euo pipefail -c
MAKEFLAGS += --warn-undefined-variables --no-builtin-rules
.DEFAULT_GOAL := help

COMPOSE ?= docker compose
SHELLCHECK_IMAGE ?= koalaman/shellcheck:v0.10.0

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

.PHONY: restart
restart: down up ## Restart everything

.PHONY: clean
clean: ## Stop services AND remove volumes (DESTROYS DATA)
	$(COMPOSE) down --volumes

.PHONY: ps
ps: ## Show service status
	$(COMPOSE) ps

##@ Interaction

.PHONY: logs
logs: ## Tail logs from all services
	$(COMPOSE) logs -f --tail=100

.PHONY: cli
cli: ## Open redis-cli inside the redis container
	$(COMPOSE) exec redis redis-cli

.PHONY: ui
ui: ## Print RedisInsight URL (routed by Traefik)
	@echo "RedisInsight: http://$${REDISINSIGHT_HOST:-redisinsight.localhost}"

##@ Validation

.PHONY: config
config: ## Validate and render the resolved compose config
	@$(COMPOSE) config -q && echo "docker-compose.yaml: OK"

.PHONY: smoke
smoke: ## Smoke-verify: PING + each bundled module + UI healthy
	@./scripts/smoke.sh

.PHONY: lint
lint: ## Shellcheck scripts/ (runs in Docker)
	@docker run --rm -v "$$PWD":/mnt -w /mnt $(SHELLCHECK_IMAGE) scripts/*.sh && echo "shellcheck: OK"

.PHONY: scan
scan: ## Scan pinned images for CVEs (uses docker scout if available)
	@if docker scout --help >/dev/null 2>&1; then \
		for image in $$($(COMPOSE) config --images); do docker scout cves "$$image"; done; \
	else \
		echo "docker scout not available — install Docker Desktop ≥ 4.17 or 'docker scout' CLI"; \
	fi
