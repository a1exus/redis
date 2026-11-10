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
