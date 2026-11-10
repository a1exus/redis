# redis

Local-dev Redis 8 + RedisInsight, in Docker Compose.

## Prerequisites

- Docker Engine ≥ 25 (or Docker Desktop ≥ 4.27) — `start_interval` in healthchecks requires Engine 25+
- Docker Compose plugin ≥ 2.24 — verify with `docker compose version`
- GNU Make ≥ 3.82 for strict-shell recipes (macOS ships 3.81: `brew install make`, then use `gmake`); recipes run correctly on 3.81 but without `pipefail`
- A running Traefik with an `web` entrypoint and the external Docker network `traefik_traefik`

## Quickstart

```bash
make up         # start Redis and RedisInsight, wait until healthy
make smoke      # verify Redis + bundled modules + UI
make cli        # open redis-cli
open http://redisinsight.localhost   # RedisInsight, routed by Traefik
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

## Traefik routing

`compose.override.yaml` is loaded automatically. It publishes no host ports: RedisInsight is `expose`d on 5540 and routed by Traefik (router `redisinsight`, entrypoint `web`, host `redisinsight.localhost`); Redis is `expose`d on 6379.

- Networks: `redis_redis` (this stack) and the external `traefik_traefik` (RedisInsight only). Create/run Traefik first, otherwise `make up` fails with "network traefik_traefik declared as external, but could not be found".
- Other containers reach Redis by joining `redis_redis` and using `redis:6379`. `make cli` still works via `docker compose exec`.
- Different hostname: `REDISINSIGHT_HOST=ri.localhost make up`. Different Traefik entrypoint: edit the `entrypoints` label.

## Configuration

Tunables are optional: every value has a default in `compose.yaml`, so the stack runs without a `.env`. To override, `cp .env.example .env` and edit it (or set variables in the shell, which win over `.env`):
- `REDIS_VERSION`, `REDISINSIGHT_VERSION` — image tags, default `latest` (floating: `docker compose pull` moves you to new releases). Pin a tag such as `8.10.3` / `3.8.0`, or a `@sha256:` digest, for reproducible setups.
- `REDIS_PORT`, `REDISINSIGHT_PORT` — host port bindings in `compose.yaml` (loopback only). `compose.override.yaml` resets them; delete that file to publish ports again.
- `REDISINSIGHT_HOST` (shell env, optional) — Traefik hostname, default `redisinsight.localhost`.
- `REDIS_MEMORY`, `REDIS_CPUS` — resource ceilings.

Server-side Redis settings in `redis.conf`. `maxmemory` is 768mb with `noeviction`, under the 1g container limit; raise `REDIS_MEMORY` and `maxmemory` together.

## Data

Lives in named volumes (`redis_redis-data`, `redis_redisinsight-data`). Survives `make down`. `make clean` wipes both.

## Adding auth later

Add `requirepass` to `redis.conf`, move it into an `env_file:` referenced from `compose.yaml`, and gitignore that file. Update RedisInsight's saved connection. Intentionally absent today because Redis publishes no host port; only containers on `redis_redis` can reach it.

## Troubleshooting

- `make config` validates `compose.yaml` against the Compose Spec before applying.
- `docker compose logs redis | tail -50` for startup errors.
- Port conflict on the host? Change it in `.env` — no compose edits needed.
- If `sysctls: net.core.somaxconn` is rejected by the Docker engine, remove that block from `compose.yaml` and add `tcp-backlog 1024` to `redis.conf`.
- `make up` reports an unhealthy service? Run `make logs` for the cause, then `make down`; the failed container keeps restarting in the background until you do.
- AOF refuses to load after an unclean shutdown (stack must be down so nothing else writes to the volume):
  `make down && docker compose run --rm --entrypoint redis-check-aof redis --fix /data/appendonlydir/appendonly.aof.manifest`
  then `make up`.
