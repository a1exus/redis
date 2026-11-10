# Redis Local Dev Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single-command, hardened, loopback-only Docker Compose stack running Redis 8 (with bundled Search/JSON/TimeSeries/Bloom) plus RedisInsight, with durable named volumes.

**Architecture:** `compose.yaml` defines two services on a dedicated bridge network. Redis takes its config via the Compose `configs:` top-level and persists to a named volume. A Makefile wraps lifecycle/validation, and `scripts/smoke.sh` is the acceptance test, written first and driven from red to green across the tasks.

**Tech Stack:** Docker Engine ≥ 25, Docker Compose plugin ≥ 2.24, GNU Make, bash, shellcheck (run via Docker).

**Spec:** `docs/superpowers/specs/2026-05-27-redis-local-dev-design.md` — the source of truth for every file's exact contents. Where a task says "per spec § X", copy that block verbatim, then apply only the deviations listed in the task.

## Global Constraints

- Filename `compose.yaml`; top-level `name: redis-dev`; no top-level `version:`; no `container_name:`.
- Custom bridge network `redis-net`; named volumes `redis-data` → `/data` in redis and `redisinsight-data` → `/data` in redisinsight.
- All host port bindings prefixed `127.0.0.1:`; ports from `.env` (`REDIS_PORT=6379`, `REDISINSIGHT_PORT=5540`).
- Pins in `.env`: `REDIS_VERSION=8.10.3`, `REDISINSIGHT_VERSION=3.8.0` (re-verify on Docker Hub; add `@sha256:` digests if resolvable). Standard debian `redis:8` variant, not alpine.
- Redis hardening: `user: redis`, `init: true`, `cap_drop: [ALL]`, `security_opt: [no-new-privileges:true]`, `read_only: true` + `tmpfs /tmp:size=64m`, `ulimits.nofile` 65536, `sysctls net.core.somaxconn: "1024"`, `stop_grace_period: 1m`, `TZ=UTC`, `restart: unless-stopped`, json-file logging `10m`×3, memory/CPU limits from `.env`.
- RedisInsight is **not** `read_only`; healthcheck is `wget -q --spider http://127.0.0.1:5540/api/health`; `depends_on` redis with `condition: service_healthy`.
- `redis.conf`: `appendonly yes`, `appendfsync everysec`, `bind 0.0.0.0`, `protected-mode no`, `port 6379`, `loglevel notice`. No auth.
- `docker compose` v2 only. Makefile: `SHELL := bash`, `.SHELLFLAGS := -euo pipefail -c`, `--warn-undefined-variables --no-builtin-rules`, `.PHONY` on every target, `.DEFAULT_GOAL := help`, `make up` uses `--wait`.
- Never `git push`, never commit to `main`, never edit a `.env` the user owns without asking (this repo's `.env` is created by this plan and is committed because it holds no secrets). Commit subjects are imperative, ≤72 chars, ending with the `Co-Authored-By` trailer from the session attribution.
- Toolchains run in Docker, not on the host (shellcheck via image; `docker compose`/`make` are the host entry points).

## Review Focus

Failure modes the spec implies but its own text doesn't test, most likely first:

1. **Shell env must override `.env`** (`REDIS_PORT=6390 make up` binds 6390). Make's `-include .env` + `export` assigns the file's value over the environment, silently ignoring the override. Pinned in Task 2.
2. **Host port already taken** — `make up` must fail non-zero with Docker's bind error, not hang on `--wait`. Pinned in Task 2.
3. **Fresh volume after `make clean`** — `read_only` + `user: redis` must still start from an empty volume (ownership comes from the image). Pinned in Task 4.
4. **Hard kill recovery** — `docker kill` then `make up` returns healthy with data written >1 s earlier intact. Pinned in Task 4.
5. **Smoke leaves no residue and fails clearly with the stack down** — non-zero exit, no `smoke:*` keys left behind after a run. Pinned in Tasks 1 and 3.

---

### Task 1: Branch, spec commit, and the smoke test (red)

**Files:**
- Create: `scripts/smoke.sh` (executable)
- Add (already present, untracked): `docs/superpowers/specs/2026-05-27-redis-local-dev-design.md`, this plan

**Interfaces:**
- Produces: `scripts/smoke.sh` — exit 0 iff PING, `JSON.SET`, `FT._LIST`, `BF.ADD`, `TS.ADD` succeed against the `redis` service and `GET /api/health` succeeds on `localhost:${REDISINSIGHT_PORT:-5540}`; otherwise exit 1 with `smoke: N passed, M failed`. Always deletes `smoke:doc`, `smoke:bloom`, `smoke:ts` before the RedisInsight probe.

- [ ] **Step 1: Create branch** `git switch -c feat/redis-local-dev` (never work on `main`).
- [ ] **Step 2: Commit spec and plan** — `git add docs/` ; subject `Add Redis local dev design spec and plan`.
- [ ] **Step 3: Write `scripts/smoke.sh`** per spec § `scripts/smoke.sh`, verbatim, then `chmod +x scripts/smoke.sh`.
- [ ] **Step 4: Run it with no stack up** — `./scripts/smoke.sh; echo "exit=$?"`. Expected: every check prints `FAIL`, last line `smoke: 0 passed, 5 failed`, `exit=1`. (This is the red state; it also pins Review Focus 5's "fails clearly" half: non-zero, readable per-check reason.)
- [ ] **Step 5: Lint via Docker** — `docker run --rm -v "$PWD":/mnt -w /mnt koalaman/shellcheck:v0.10.0 scripts/smoke.sh`. Expected: no output, exit 0. (Verify the tag exists; pin whichever current tag you use.)
- [ ] **Step 6: Commit** — `git add scripts/smoke.sh`; subject `Add smoke test for Redis modules and RedisInsight`. Also run `git update-index --chmod=+x scripts/smoke.sh` and confirm `git ls-files -s scripts/smoke.sh` shows mode `100755`.

---

### Task 2: Redis service, config, Makefile

**Files:**
- Create: `.env`, `redis.conf`, `compose.yaml`, `Makefile`
- Test: `scripts/smoke.sh` (Redis half goes green)

**Interfaces:**
- Consumes: `scripts/smoke.sh` from Task 1.
- Produces: Make targets `help up down restart clean ps logs cli ui config smoke lint scan`; compose service `redis` (healthy ⇒ ready); `.env` keys `REDIS_VERSION REDISINSIGHT_VERSION REDIS_PORT REDISINSIGHT_PORT REDIS_MEMORY REDIS_CPUS`.

- [ ] **Step 1: Create `.env`** per spec § `.env` (values from Global Constraints; `REDIS_MEMORY=1g`, `REDIS_CPUS=1.0`).
- [ ] **Step 2: Create `redis.conf`** per spec § `redis.conf`, verbatim.
- [ ] **Step 3: Create `compose.yaml` with only the `redis` service** plus top-level `x-logging`, `x-security`, `volumes` (both), `networks`, `configs`, per spec § `compose.yaml`. Deviation from spec text: `user: redis` is already in the spec's service block; keep it. Leave `redisinsight` out until Task 3.
- [ ] **Step 4: Create `Makefile`** per spec § `Makefile`, with these deviations, each a plan call: (a) drop `-include .env` / `export` — Compose already reads `.env` and lets the shell env win, whereas Make's include would clobber the shell value (Review Focus 1); (b) `ui` prints the URL from `$(COMPOSE) port redisinsight 5540` instead of `$(REDISINSIGHT_PORT)`; (c) `scan` iterates `$(COMPOSE) config --images`; (d) `lint` runs the Dockerized shellcheck from Task 1 Step 5 unconditionally (no host-install branch).
- [ ] **Step 5: Validate** — `make config`. Expected: `compose.yaml: OK`.
- [ ] **Step 6: Start** — `make up`. Expected: exits 0 only once `redis` is `healthy`; `make ps` shows `healthy`.
- [ ] **Step 7: Run smoke** — `make smoke`. Expected: PING + 4 module checks `ok`; the `/api/health` check `FAIL` (RedisInsight not defined yet); `exit=1`.
- [ ] **Step 8: Pin Review Focus 1** — `make down && REDIS_PORT=6390 make up && docker compose port redis 6379`. Expected: `127.0.0.1:6390`. Then `make down`. (If it prints 6379, the Makefile is still overriding the environment.)
- [ ] **Step 9: Pin Review Focus 2** — occupy the port: `docker run -d --rm --name portblock -p 127.0.0.1:6379:80 nginx:stable-alpine` (pin the tag you actually use), run `make up; echo "exit=$?"`. Expected: non-zero exit with Docker's "port is already allocated" message, returning promptly. Cleanup: `docker rm -f portblock`.
- [ ] **Step 10: Commit** — `git add .env redis.conf compose.yaml Makefile`; subject `Add Redis 8 service, config and Makefile`.

---

### Task 3: RedisInsight service (green)

**Files:**
- Modify: `compose.yaml` (add `redisinsight` service per spec § `compose.yaml`)

**Interfaces:**
- Consumes: `redis` service healthcheck from Task 2.
- Produces: service `redisinsight` reachable at `http://127.0.0.1:${REDISINSIGHT_PORT}`, healthy via `/api/health`.

- [ ] **Step 1: Add the `redisinsight` service** per spec, verbatim.
- [ ] **Step 2: `make config && make up`**. Expected: both services `healthy`. If `redisinsight` never becomes healthy, check `docker compose logs redisinsight` and confirm `/api/health` exists in 3.8.0 (spec Verification item 3); if the path differs, change the healthcheck and the smoke URL together and note it in the commit body.
- [ ] **Step 3: `make smoke`**. Expected: all five checks `ok`, `smoke: 5 passed`, `exit=0`.
- [ ] **Step 4: Pin Review Focus 5 (no residue)** — `docker compose exec -T redis redis-cli --scan --pattern 'smoke:*'`. Expected: empty output.
- [ ] **Step 5: Verify wiring** — `docker compose exec redisinsight getent hosts redis`. Expected: an address line (Compose DNS resolves `redis` from the UI container).
- [ ] **Step 6: Commit** — subject `Add RedisInsight service`.

---

### Task 4: Runtime hardening and durability verification

**Files:**
- Test: none created; this task executes checks against the running stack and fixes `compose.yaml`/`redis.conf` only if a check fails.

**Interfaces:**
- Consumes: the running stack from Task 3.

- [ ] **Step 1: Loopback only** — `docker ps --format '{{.Names}} {{.Ports}}'`. Expected: every published port starts with `127.0.0.1:`; none shows `0.0.0.0`.
- [ ] **Step 2: Hardening is applied** — `docker inspect "$(docker compose ps -q redis)" --format '{{.HostConfig.ReadonlyRootfs}} {{.Config.User}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.HostConfig.Init}}'`. Expected: `true redis [ALL] [no-new-privileges:true] true`. Also `docker compose exec redis sh -c 'ulimit -n'` → `65536`, and `docker compose exec redis cat /proc/sys/net/core/somaxconn` → `1024` (if rejected by the engine, apply the README fallback from spec: remove `sysctls`, add `tcp-backlog 1024`, and record it).
- [ ] **Step 3: Persistence across restart** — `docker compose exec -T redis redis-cli SET persist:k v`, then `make restart`, then `docker compose exec -T redis redis-cli GET persist:k`. Expected: `v`. Check `appendonly` is on: `docker compose exec -T redis redis-cli CONFIG GET appendonly` → `yes`.
- [ ] **Step 4: Review Focus 4 (hard kill)** — set `crash:k`, wait 2 s, `docker kill "$(docker compose ps -q redis)"`, `make up`, `GET crash:k`. Expected: value present, service `healthy`. (`restart: unless-stopped` may already have restarted it; either path must end healthy with the value.)
- [ ] **Step 5: Review Focus 3 (fresh volume)** — `make clean && make up && make smoke`. Expected: healthy and `smoke: 5 passed` from empty volumes.
- [ ] **Step 6: Clean up test keys**, then commit only if a fix was needed — subject describes the fix.

---

### Task 5: README, .gitignore, final verification

**Files:**
- Create: `README.md`, `.gitignore`

- [ ] **Step 1: Create `.gitignore`** per spec § `.gitignore`, verbatim.
- [ ] **Step 2: Create `README.md`** per spec § `README.md`, verbatim (inner fenced content as authored), updating nothing but the Docker/Compose version floors if Task 2 showed a higher requirement.
- [ ] **Step 3: Final gate** — `make config && make lint && make down && make up && make smoke && make scan`. Expected: `compose.yaml: OK`, `shellcheck: OK`, smoke `5 passed`; `make scan` either prints CVE summaries or the documented "docker scout not available" message, exit 0 either way.
- [ ] **Step 4: Audit against spec** — walk spec § "Best-practices principles applied" line by line against `compose.yaml` and `Makefile`; fix any gap.
- [ ] **Step 5: Commit** — subject `Add README and .gitignore`.
- [ ] **Step 6: Stop.** Do not push. Report the branch name and ask the user whether to push and open a PR.

---

## Self-Review

- **Spec coverage:** compose, `.env`, `redis.conf`, Makefile, smoke, README, `.gitignore`, all seven Verification items (1: Task 2 pins/Task 5; 2–3: Tasks 2–3; 4: Task 4 Step 2; 5: `--wait`/`start_interval` fails loudly on Engine <25 at Task 2 Step 5; 6: Task 1 Step 6; 7: Task 5 Step 3). "Continuous validation" is out of scope per the spec.
- **Deviations from spec (my calls):** Makefile drops `-include .env`/`export` (Review Focus 1); `lint` is Dockerized, per the user's global tooling rule; `ui`/`scan` read from Compose.
- **Consistency:** target names, service names, env keys and `smoke:*` key names are identical across tasks.
