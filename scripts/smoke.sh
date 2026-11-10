#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

cli() { docker compose exec -T redis redis-cli "$@"; }

# Probe inside the container: the UI publishes no host port (Traefik routes to it).
# shellcheck disable=SC2317  # invoked indirectly via check()
ui_health() { docker compose exec -T redisinsight wget -qO- http://127.0.0.1:5540/api/health; }

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

cli DEL smoke:doc smoke:bloom smoke:ts >/dev/null 2>&1 || true

echo
echo "RedisInsight:"
check "GET /api/health"    ui_health

echo
if [[ $fail -eq 0 ]]; then
  echo "smoke: $pass passed"
  exit 0
else
  echo "smoke: $pass passed, $fail failed"
  exit 1
fi
