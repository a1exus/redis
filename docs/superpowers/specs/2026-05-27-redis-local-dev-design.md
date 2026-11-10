# Redis Local Dev Environment — Design

- **Date:** 2026-05-27
- **Status:** Approved for implementation planning (revised)
- **Scope:** Docker Compose setup for a local-dev Redis 8 + RedisInsight stack in this repo

## Goal

Stand up a reproducible, hardened, single-command local development environment containing:

1. Redis 8 (official image), with the modules bundled into Redis 8 core: Search, JSON, TimeSeries, Bloom.
2. RedisInsight as a separate UI container.
3. Durable data across restarts via named volumes.

Loopback-only exposure. No auth (deliberate, justified below). Industry-standard Docker Compose conventions throughout.

## Approach

**Chosen: plain `redis:8` + separate `redis/redisinsight`.**

Redis 8 (GA May 2025) folded the previously-separate Stack modules into the canonical `redis` image, so the official image is sufficient for module access without taking on the Redis Stack release cadence. RedisInsight runs as a sibling container so the UI can restart independently of the server.

**Alternatives considered:**

- *`redis/redis-stack` all-in-one:* simplest compose, but couples UI to server lifecycle and has a slower release cadence than `redis:8`.
- *`redis/redis-stack-server` + standalone RedisInsight:* same cadence issue without the simplicity benefit; redundant given `redis:8`.

## Architecture

```
┌───────────────────────────────────────────────────┐
│  host (localhost)                                 │
│   ├─ 127.0.0.1:6379 ──► redis        (redis:8)    │
│   └─ 127.0.0.1:5540 ──► redisinsight              │
│                            │                      │
│                            └─► redis:6379 (DNS)   │
└───────────────────────────────────────────────────┘

  redis-data            named volume → /data in redis
  redisinsight-data     named volume → /data in redisinsight
  redis-net             dedicated bridge network
```

- Both host ports bound to `127.0.0.1` — never reachable from the LAN.
- RedisInsight reaches Redis via Compose's internal DNS (`redis:6379`), not the host port.
- State lives in named volumes; `compose down` keeps it, `down -v` wipes it.

## File layout

```
.
├── compose.yaml          # service definitions
├── redis.conf            # committed; mounted read-only into redis
├── .env                  # committed (no secrets); image versions, ports, limits
├── Makefile              # convenience targets
├── scripts/
│   └── smoke.sh          # PING + module + UI verification
├── .gitignore
└── README.md
```

## Best-practices principles applied

All sections honor the following, called out explicitly so the implementation phase can audit against this list.

**Compose conventions**
- No top-level `version:` key (obsolete in current Compose Spec).
- Filename is `compose.yaml`, not `docker-compose.yml`.
- Explicit project name via top-level `name:`.
- Custom named network rather than the default.
- All host port bindings prefixed with `127.0.0.1:`.
- No `container_name:` — anti-pattern that blocks scaling and cross-project parallelism.

**Image hygiene**
- Pin to specific minor/patch tags; recommend `@sha256:` digest pinning at implementation time.
- Use the standard (debian-slim) `redis:8` variant — the alpine variant historically drops bundled modules; verify against the chosen tag before merging.
- Image versions in `.env`, referenced via `${REDIS_VERSION}` etc.

**Runtime hardening**
- `init: true` to reap PID-1 zombies.
- `cap_drop: [ALL]`.
- `security_opt: [no-new-privileges:true]`.
- `read_only: true` on Redis with sized `tmpfs` for `/tmp` and a named volume for `/data`.
- `user: redis` set explicitly on Redis. With `cap_drop: [ALL]` the container's root user has no `CAP_DAC_OVERRIDE`/`CAP_CHOWN`, so the image's default root start fails with `Can't open or create append-only dir appendonlydir: Permission denied` (reproduced on `redis:8.10.3`). Starting directly as the unprivileged `redis` user needs no capabilities and is the standard least-privilege fix. Named volumes inherit `/data` ownership from the image, so no chown is required.

**Operational hygiene**
- Healthchecks on both services. Redis checks the *reply*, not just the exit code. RedisInsight uses the `/api/health` endpoint.
- `depends_on` with `condition: service_healthy` so the UI waits for Redis.
- `restart: unless-stopped`.
- `logging:` pinned to `json-file` with `max-size` + `max-file` so logs can't fill disk.
- Memory **and** CPU limits via `deploy.resources.limits`, parameterized in `.env`.
- `hostname:` set explicitly for deterministic log identification.
- `TZ=UTC` for predictable log timestamps.
- `ulimits.nofile` raised to 65536 (Redis opens many fds).
- `sysctls: net.core.somaxconn=1024` to silence Redis's listen-backlog warning.
- `stop_grace_period: 1m` on Redis so AOF/RDB can flush on shutdown.

**Persistence**
- AOF enabled with `appendfsync everysec` — standard durability/perf balance. Window of potential data loss on hard crash: ~1 s. Acceptable for local dev; called out so it isn't a surprise.
- RDB defaults retained.
- Named volume, not a bind mount, to avoid host UID/GID surprises.

**Config delivery**
- `redis.conf` provided via the Compose Spec `configs:` top-level (not as a bind mount). More declarative, portable (same shape in swarm/k8s), and lets us set explicit file mode.

**Makefile / DX**
- `docker compose` (v2 plugin) only; v1 is EoL.
- `SHELL := bash` + `pipefail` for pipeline robustness.
- `MAKEFLAGS += --warn-undefined-variables --no-builtin-rules` for strictness.
- `.PHONY` on every target.
- `.DEFAULT_GOAL := help`, with a self-documenting `help` target.
- `-include .env` + `export` so Make and Compose see the same variables.
- `make up` uses `--wait` so success means *ready*.
- `make config` runs `docker compose config -q` for spec validation.

## `compose.yaml`

```yaml
name: redis-dev

x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"

x-security: &default-security
  cap_drop: [ALL]
  security_opt:
    - no-new-privileges:true
  init: true

services:
  redis:
    image: redis:${REDIS_VERSION}
    hostname: redis
    user: redis
    command: ["redis-server", "/usr/local/etc/redis/redis.conf"]
    ports:
      - "127.0.0.1:${REDIS_PORT}:6379"
    volumes:
      - redis-data:/data
    configs:
      - source: redis_conf
        target: /usr/local/etc/redis/redis.conf
        mode: 0444
    networks: [redis-net]
    environment:
      TZ: UTC
    read_only: true
    tmpfs:
      - /tmp:size=64m
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    sysctls:
      net.core.somaxconn: "1024"
    healthcheck:
      test: ["CMD-SHELL", "redis-cli ping | grep -q PONG"]
      interval: 5s
      timeout: 3s
      retries: 5
      start_period: 5s
      start_interval: 1s         # tight probes during startup; falls back to interval after healthy
    stop_grace_period: 1m
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: ${REDIS_MEMORY}
          cpus: "${REDIS_CPUS}"
    <<: *default-security
    logging: *default-logging

  redisinsight:
    image: redis/redisinsight:${REDISINSIGHT_VERSION}
    hostname: redisinsight
    ports:
      - "127.0.0.1:${REDISINSIGHT_PORT}:5540"
    volumes:
      - redisinsight-data:/data
    networks: [redis-net]
    environment:
      TZ: UTC
    depends_on:
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "wget -q --spider http://localhost:5540/api/health || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
      start_interval: 2s
    restart: unless-stopped
    <<: *default-security
    logging: *default-logging

volumes:
  redis-data:
  redisinsight-data:

networks:
  redis-net:
    driver: bridge

configs:
  redis_conf:
    file: ./redis.conf
```

## `.env`

```dotenv
# Bump after verifying current tags on Docker Hub.
# Ideally pin by digest:  REDIS_VERSION=8.0.3@sha256:<digest>
REDIS_VERSION=8.10.3
REDISINSIGHT_VERSION=3.8.0

# Host bindings (loopback only)
REDIS_PORT=6379
REDISINSIGHT_PORT=5540

# Resource limits
REDIS_MEMORY=1g
REDIS_CPUS=1.0
```

`.env` is committed because it contains no secrets. If auth is ever introduced, sensitive values move to a separate gitignored file referenced via `env_file:`.

## `redis.conf`

```conf
# Persistence — AOF + RDB defaults
appendonly yes
appendfsync everysec

# Networking
bind 0.0.0.0
# Safe: host port is bound to 127.0.0.1 in compose.yaml (redis.conf has no inline comments)
protected-mode no
port 6379

# Logging
loglevel notice
```

`protected-mode no` is deliberate. Inside the bridge network, RedisInsight needs to reach Redis without auth; protected-mode would block it. The external attack surface is gated at the Docker port-binding layer (`127.0.0.1:6379`), not at Redis.

## `Makefile`

```makefile
SHELL := bash
.SHELLFLAGS := -euo pipefail -c
MAKEFLAGS += --warn-undefined-variables --no-builtin-rules
.DEFAULT_GOAL := help

-include .env
export

COMPOSE ?= docker compose

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
ui: ## Print RedisInsight URL
	@echo "RedisInsight: http://localhost:$(REDISINSIGHT_PORT)"

##@ Validation

.PHONY: config
config: ## Validate and render the resolved compose config
	@$(COMPOSE) config -q && echo "compose.yaml: OK"

.PHONY: smoke
smoke: ## Smoke-verify: PING + each bundled module + UI reachable
	@./scripts/smoke.sh

.PHONY: lint
lint: ## Shellcheck scripts/ (no-op if shellcheck not installed)
	@if command -v shellcheck >/dev/null; then \
		shellcheck scripts/*.sh && echo "shellcheck: OK"; \
	else \
		echo "shellcheck not installed — skipping"; \
	fi

.PHONY: scan
scan: ## Scan pinned images for CVEs (uses docker scout if available)
	@if docker scout --help >/dev/null 2>&1; then \
		docker scout cves redis:$(REDIS_VERSION); \
		docker scout cves redis/redisinsight:$(REDISINSIGHT_VERSION); \
	else \
		echo "docker scout not available — install Docker Desktop ≥ 4.17 or 'docker scout' CLI"; \
	fi
```

## `scripts/smoke.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Load .env so REDISINSIGHT_PORT is available without relying on Make's export.
[[ -f .env ]] && { set -a; source .env; set +a; }

cli() { docker compose exec -T redis redis-cli "$@"; }

pass=0; fail=0
check() {
  local label=$1; shift
  printf '  %-32s ' "$label"
  if out=$("$@" 2>&1); then
    echo "ok"
    pass=$((pass + 1))
  else
    echo "FAIL"
    printf '    → %s\n' "$out"
    fail=$((fail + 1))
  fi
}

echo "Redis core:"
check "PING"               cli PING

echo
echo "Bundled modules (Redis 8 core):"
check "JSON  (JSON.SET)"   cli JSON.SET smoke:doc '$' '{"hello":"world"}'
check "Search (FT._LIST)"  cli FT._LIST
check "Bloom (BF.ADD)"     cli BF.ADD smoke:bloom item
check "TimeSeries (TS.ADD)" cli TS.ADD smoke:ts '*' 42

cli DEL smoke:doc smoke:bloom smoke:ts >/dev/null || true

echo
echo "RedisInsight:"
check "GET /api/health"    curl -fsS "http://localhost:${REDISINSIGHT_PORT:-5540}/api/health"

echo
if [[ $fail -eq 0 ]]; then
  echo "smoke: $pass passed"
  exit 0
else
  echo "smoke: $pass passed, $fail failed"
  exit 1
fi
```

The script must be `chmod +x` at creation. Each module probe uses a command that *requires* the module to be loaded, so the test actually verifies the bundled-module promise of `redis:8`.

## `README.md`

````markdown
# redis

Local-dev Redis 8 + RedisInsight, in Docker Compose.

## Prerequisites

- Docker Engine ≥ 25 (or Docker Desktop ≥ 4.27) — `start_interval` in healthchecks requires Engine 25+
- Docker Compose plugin ≥ 2.24 — verify with `docker compose version`
- GNU Make
- `curl` (used by `make smoke` to probe the UI from the host)

## Quickstart

```bash
make up         # start Redis (:6379) and RedisInsight (:5540), wait until healthy
make smoke      # verify Redis + bundled modules + UI
make cli        # open redis-cli
open http://localhost:5540   # RedisInsight
```

In RedisInsight, add a database with **Host: `redis`, Port: `6379`** — Compose's internal DNS handles the lookup. Do not use `localhost`; that points at the RedisInsight container, not Redis.

## Daily commands

| Goal | Command |
|---|---|
| Status | `make ps` |
| Tail logs | `make logs` |
| Stop, keep data | `make down` |
| Stop, wipe data | `make clean` |
| Validate compose | `make config` |

## Configuration

Tunables in `.env`:
- `REDIS_VERSION`, `REDISINSIGHT_VERSION` — image pins. Bump after verifying tags on Docker Hub; prefer `@sha256:` digests for full reproducibility.
- `REDIS_PORT`, `REDISINSIGHT_PORT` — host port bindings (loopback only).
- `REDIS_MEMORY`, `REDIS_CPUS` — resource ceilings.

Server-side Redis settings in `redis.conf`.

## Data

Lives in named volumes (`redis-dev_redis-data`, `redis-dev_redisinsight-data`). Survives `make down`. `make clean` wipes both.

## Adding auth later

Add `requirepass` to `redis.conf`, move it into an `env_file:` referenced from `compose.yaml`, and gitignore that file. Update RedisInsight's saved connection. Intentionally absent today because the host port is loopback-only.

## Troubleshooting

- `make config` validates `compose.yaml` against the Compose Spec before applying.
- `docker compose logs redis | tail -50` for startup errors.
- Port conflict on the host? Change it in `.env` — no compose edits needed.
- If `sysctls: net.core.somaxconn` is rejected by the Docker engine, remove that block from `compose.yaml` and add `tcp-backlog 1024` to `redis.conf`.
- AOF refuses to load after an unclean shutdown:
  `docker compose run --rm --entrypoint redis-check-aof redis --fix /data/appendonlydir/*.aof`
  then `make up`.
````

## `.gitignore`

```gitignore
.DS_Store
.idea/
.vscode/
*.swp
*.swo
```

Volumes live in the Docker engine's storage, not the working directory, so there's nothing repo-local to ignore for data. `.env` is intentionally not ignored.

## Continuous validation (recommended, out of core scope)

These are not part of the deliverable but are the natural next-step hardenings once the env exists. Documented here so they're visible during impl planning.

- **Pre-commit hook** (or `lefthook` / `pre-commit` framework): run `docker compose config -q` and `shellcheck scripts/*.sh` on every commit that touches the relevant files.
- **CI workflow** (e.g., `.github/workflows/validate.yml`): same two checks plus `make smoke` against a freshly-started stack; cache the Compose images.
- **Periodic image refresh**: a scheduled job that bumps `.env` tags after re-running `make smoke`. Keeps digest pins from rotting silently.

## Trade-offs and non-goals

- **`read_only: true` only on Redis**, not RedisInsight. Redis is a single-purpose binary with confined writes; RedisInsight is a Node app whose transient write paths shift across versions. Locking down the UI yields little marginal security on a loopback-only port at a real maintenance cost.
- **No auth.** External access is gated at the host port binding (`127.0.0.1:6379`). Adding `requirepass` later is a documented migration in the README.
- **Pinned tags** were resolved against Docker Hub on 2026-11-10 (`redis:8.10.3`, `redis/redisinsight:3.8.0`). Implementation re-checks them and ideally adds `@sha256:` digests.
- **No `redis.conf` parameter sprawl.** The committed file holds only what differs meaningfully from upstream defaults: persistence, bind, protected-mode, log level. New knobs land here when they earn it.
- **Single Redis instance.** No replicas, no cluster, no sentinel. Scope is local dev.
- **No application service.** The repo wires up Redis + UI; consuming applications live elsewhere and connect to `127.0.0.1:6379`.

## Verification items for implementation

These are deliberate "verify at impl time" items the implementer must resolve before merging, not open questions about the design.

1. Resolve `REDIS_VERSION` and `REDISINSIGHT_VERSION` to current Docker Hub tags; prefer digest pinning.
2. Confirm the chosen `redis:8.x` tag is the debian-slim variant and ships the four bundled modules referenced in `smoke.sh`. *(Checked 2026-11-10 on `redis:8.10.3`: JSON, Bloom, TimeSeries and Search respond under the full hardening set.)*
3. Confirm the RedisInsight image ships `wget` (used by the healthcheck) and exposes `/api/health` on port 5540 in the chosen version. *(`wget` confirmed in `3.8.0`, which runs as `node` uid 1000; `/api/health` still to verify at impl time.)*
4. Confirm the Docker engine on the developer host accepts `sysctls: net.core.somaxconn=1024`. If not, move to `tcp-backlog 1024` in `redis.conf` per the README troubleshooting note.
5. Confirm the Docker engine on the developer host is ≥ 25 (required for `start_interval` in healthchecks); the README prerequisites already state this, but the impl step should fail loudly on a lower version rather than silently ignore the field.
6. `chmod +x scripts/smoke.sh` and `git update-index --chmod=+x scripts/smoke.sh` so the executable bit is committed.
7. Run `make config`, `make lint`, and `make smoke` end-to-end on the developer host before merging.
