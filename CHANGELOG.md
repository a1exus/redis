# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project has no versioned releases yet, so everything is under Unreleased.

## [Unreleased]

### Added

- Docker Compose stack: Redis 8.10.3 (bundled Search, JSON, TimeSeries, Bloom) and RedisInsight 3.8.0, with durable named volumes and AOF persistence (`appendfsync everysec`).
- Runtime hardening on Redis: non-root `user: redis`, `cap_drop: [ALL]`, `no-new-privileges`, read-only root filesystem, `init`, memory/CPU limits, json-file log rotation.
- `compose.override.yaml`: no published host ports; RedisInsight is routed by Traefik (`redisinsight.localhost`, overridable with `REDISINSIGHT_HOST`) over the external `traefik_traefik` network; the stack network is named `redis_redis`.
- Makefile targets: `up`, `down`, `restart`, `clean`, `ps`, `logs`, `cli`, `ui`, `config`, `smoke`, `lint`, `scan`, `help`.
- `scripts/smoke.sh`: verifies PING, JSON, Search, Bloom, TimeSeries and RedisInsight health.
- Design spec and implementation plan under `docs/superpowers/`.
- README with quickstart, Traefik routing, troubleshooting and AOF recovery steps.

### Changed

- `compose.yaml` has `${VAR:-default}` fallbacks for every variable, so `.env` is optional; added `.env.example` documenting them.
- Redis now sets `maxmemory 768mb` with `noeviction`, below the 1g container limit, so it returns OOM errors instead of being killed by the kernel.
- Spec and README synced to the implemented files; README documents Traefik routing, the GNU Make 3.82 floor, and failed-`make up` troubleshooting.

### Fixed

- `redis.conf`: moved the `protected-mode` comment onto its own line; Redis rejects trailing comments and crash-looped.
- RedisInsight healthcheck probes `127.0.0.1`; BusyBox `wget` resolved `localhost` to `::1`, which the app does not listen on.
- Removed the Compose `configs` `mode` option, which is ignored outside Swarm and warned on every command.
- `smoke.sh` no longer overrides shell-environment port settings with values from `.env`.
- README AOF repair command now targets the AOF manifest and requires the stack to be down.
