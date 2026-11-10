#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Load .env so REDISINSIGHT_PORT is available without relying on Make's export.
# shellcheck source=/dev/null
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

cli DEL smoke:doc smoke:bloom smoke:ts >/dev/null 2>&1 || true

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
