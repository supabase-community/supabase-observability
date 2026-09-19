#!/usr/bin/env bash
# Confirms all routed services are reaching the log store selected by
# BACKEND_LOGS in .env. Does not modify .env or switch backends.
#
# Temporarily raises PGRST_LOG_LEVEL and log_min_messages on the
# Supabase stack (see overrides/log-levels.yml) so quiet-by-default
# services actually produce log lines, then reverts them at the end.
# Prompts before doing so, since it restarts those two containers.
#
# The revert puts rest and db back to their upstream defaults. If you had
# levels applied deliberately with set-log-levels.sh, re-apply them after.
#
# Only logs produced by this run are counted. Anything already in the store
# from an earlier run is outside the query window, so a pass here means the
# pipeline is working now, not that it worked at some point.
#
# Requires: docker, curl, jq
#
# Reads SUPABASE_DIR from .env, or set it inline to override, e.g.
#   SUPABASE_DIR=/path/to/supabase/docker scripts/verify-logs.sh
#
# Checks whichever single backend BACKEND_LOGS selects. To confirm
# parity between Loki and VictoriaLogs, run this once per backend.
#
# Exits 2 if setup is missing, 1 if any service is missing from the
# store, 0 if all are present.

set -uo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "This script needs bash 4 or newer; found ${BASH_VERSION}." >&2
  echo "macOS ships bash 3.2. Install a newer one (e.g. 'brew install bash')" >&2
  echo "and re-run with it." >&2
  exit 1
fi

for _bin in docker curl jq; do
  command -v "$_bin" >/dev/null 2>&1 || {
    echo "Required command not found: ${_bin}"
    echo "This script needs docker, curl, and jq."
    exit 2
  }
done

LOKI_URL="${LOKI_URL:-http://127.0.0.1:3100}"
VL_URL="${VL_URL:-http://127.0.0.1:9428}"
# The query window starts when this run generates its traffic. Set
# LOOKBACK_MINUTES to also include logs from before that point.
LOOKBACK_MINUTES="${LOOKBACK_MINUTES:-0}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPABASE_DIR="${SUPABASE_DIR:-$(grep "^SUPABASE_DIR=" "${REPO_ROOT}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)}"

SERVICES=(
  "supabase-auth"
  "supabase-rest"
  "realtime-dev.supabase-realtime"
  "supabase-storage"
  "supabase-edge-functions"
  "supabase-db"
  "supabase-pooler"
)

if docker ps --format '{{.Names}}' | grep -qx 'supabase-envoy'; then
  SERVICES=("supabase-envoy" "${SERVICES[@]}")
elif docker ps --format '{{.Names}}' | grep -qx 'supabase-kong'; then
  SERVICES=("supabase-kong" "${SERVICES[@]}")
fi

if [ -z "${SUPABASE_DIR}" ]; then
  echo "SUPABASE_DIR is not set."
  echo "Set it in .env, or point it at your Supabase docker/ directory and retry, e.g.:"
  echo "  SUPABASE_DIR=/path/to/supabase/docker scripts/verify-logs.sh"
  exit 2
fi

if [ ! -f "${SUPABASE_DIR}/docker-compose.yml" ]; then
  echo "Can't find Supabase's docker-compose.yml at ${SUPABASE_DIR}."
  exit 2
fi

# Mirror Supabase's own COMPOSE_FILE so overrides it has enabled (Envoy,
# pg17, s3, ...) stay in effect. Passing -f at all makes docker compose
# ignore COMPOSE_FILE, so each entry has to be expanded by hand.
SUPABASE_COMPOSE_ARGS=()
_compose_file="$(grep '^COMPOSE_FILE=' "${SUPABASE_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
if [ -n "${_compose_file}" ]; then
  IFS=':' read -ra _cf_parts <<< "${_compose_file}"
  for _part in "${_cf_parts[@]}"; do
    SUPABASE_COMPOSE_ARGS+=(-f "${SUPABASE_DIR}/${_part}")
  done
else
  SUPABASE_COMPOSE_ARGS=(-f "${SUPABASE_DIR}/docker-compose.yml")
fi

# The gateway port is Supabase's, not this project's, and it is
# configurable. API_GW_HTTP_PORT is the current variable; KONG_HTTP_PORT
# is upstream's older fallback, kept for compose files that still set it.
GW_PORT="$(grep '^API_GW_HTTP_PORT=' "${SUPABASE_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
if [ -z "${GW_PORT}" ]; then
  GW_PORT="$(grep '^KONG_HTTP_PORT=' "${SUPABASE_DIR}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)"
fi
GW_PORT="${GW_PORT:-8000}"
GW="http://localhost:${GW_PORT}"

BACKEND="$(grep '^BACKEND_LOGS=' "${REPO_ROOT}/.env" | tail -1 | cut -d= -f2-)"
BACKEND="${BACKEND:-victorialogs}"

check_loki=0
check_vl=0
case "${BACKEND}" in
  loki)         check_loki=1 ;;
  victorialogs) check_vl=1 ;;
  *)
    echo "Unrecognized BACKEND_LOGS=${BACKEND} in .env."
    echo "Expected one of: victorialogs, loki."
    exit 2
    ;;
esac

if [ "$check_loki" -eq 1 ] && ! docker ps --format '{{.Names}}' | grep -q '^supabase-observability-loki$'; then
  echo "BACKEND_LOGS=${BACKEND} but Loki isn't running."
  exit 2
fi
if [ "$check_vl" -eq 1 ] && ! docker ps --format '{{.Names}}' | grep -q '^supabase-observability-victorialogs$'; then
  echo "BACKEND_LOGS=${BACKEND} but VictoriaLogs isn't running."
  exit 2
fi

echo "This raises log levels on your Supabase rest and db containers so the"
echo "quiet-by-default ones produce log lines. They will restart, then revert."
read -r -p "Continue? [y/N] " reply
case "$reply" in
  y|Y) ;;
  *) echo "Aborted."; exit 0 ;;
esac

cleanup() {
  echo "Reverting temporary log-level override..."
  docker compose "${SUPABASE_COMPOSE_ARGS[@]}" up -d rest db >/dev/null 2>&1
}
trap cleanup EXIT

echo "Applying temporary log-level override to rest/db..."
SUPABASE_REST_LOG_LEVEL=info SUPABASE_DB_LOG_LEVEL=warning \
  docker compose "${SUPABASE_COMPOSE_ARGS[@]}" \
    -f "${REPO_ROOT}/overrides/log-levels.yml" \
  up -d rest db >/dev/null

# Everything after this point is what the query window covers.
RUN_START="$(date -u +%s)"

# A gateway that is up but never published its port answers nothing, and
# its health check will not catch that. Without this probe the run would
# report only that no traffic was generated, several services down.
if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${GW}/rest/v1/")" = "000" ]; then
  echo
  echo "No response from the gateway at ${GW}."
  echo "Test traffic cannot be generated, so most services below will show as"
  echo "missing even if the pipeline is fine. Check that the gateway published"
  echo "its port:"
  echo "  docker port supabase-kong     # or supabase-envoy"
  echo "See docs/log-troubleshooting.md if the output is empty."
  echo
fi

echo "Generating test traffic..."
ANON_KEY="$(grep '^ANON_KEY=' "${SUPABASE_DIR}/.env" | cut -d= -f2)"
POOLER_TENANT_ID="$(grep '^POOLER_TENANT_ID=' "${SUPABASE_DIR}/.env" | cut -d= -f2)"
POSTGRES_PASSWORD="$(grep '^POSTGRES_PASSWORD=' "${SUPABASE_DIR}/.env" | cut -d= -f2)"
curl -s "${GW}/auth/v1/token?grant_type=password" \
  -H "apikey: ${ANON_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"email":"verify-logs@example.com","password":"wrong-password"}' \
  >/dev/null 2>&1 || true
curl -s "${GW}/rest/v1/rpc/nonexistent_fn_$(date +%s)" \
  -H "apikey: ${ANON_KEY}" -H "Authorization: Bearer ${ANON_KEY}" >/dev/null 2>&1 || true
curl -s "${GW}/functions/v1/hello" >/dev/null 2>&1 || true
curl -s "${GW}/storage/v1/bucket" -H "apikey: ${ANON_KEY}" >/dev/null 2>&1 || true
docker exec supabase-db psql -U postgres -c "SELECT 1/0;" >/dev/null 2>&1 || true
docker exec supabase-db psql \
  "postgresql://postgres.${POOLER_TENANT_ID}:${POSTGRES_PASSWORD}@supabase-pooler:5432/postgres" \
  -c "SELECT 1;" >/dev/null 2>&1 || true
docker exec realtime-dev.supabase-realtime \
  curl -s -H "Authorization: Bearer ${ANON_KEY}" \
  http://localhost:4000/api/tenants/realtime-dev \
  >/dev/null 2>&1 || true

if [ "$check_loki" -eq 1 ]; then
  echo "Waiting for Loki to flush (chunk_idle_period + flush_check_period)..."
  sleep 40
else
  sleep 5
fi
echo

# 60s of margin absorbs sink batching and any small clock difference
# between this shell and the containers.
query_start=$(( RUN_START - 60 - LOOKBACK_MINUTES * 60 ))
start_ns="${query_start}000000000"
end_ns="$(date -u +%s)000000000"
start_iso="$(date -u -d "@${query_start}" +%Y-%m-%dT%H:%M:%SZ)"

echo "Checking ${#SERVICES[@]} services, logs from ${start_iso} onward, against:"
[ "$check_loki" -eq 1 ] && echo "  Loki:         ${LOKI_URL}"
[ "$check_vl" -eq 1 ]   && echo "  VictoriaLogs: ${VL_URL}"
echo

loki_present() {
  local svc="$1"
  local count
  count=$(curl -sG "${LOKI_URL}/loki/api/v1/query_range" \
    --data-urlencode "query={service=\"${svc}\"}" \
    --data-urlencode "start=${start_ns}" \
    --data-urlencode "end=${end_ns}" \
    --data-urlencode "limit=1" \
    | jq '.data.result | length' 2>/dev/null)
  [ -n "$count" ] && [ "$count" -gt 0 ] 2>/dev/null
}

vl_appnames=""
if [ "$check_vl" -eq 1 ]; then
  vl_appnames=$(curl -s "${VL_URL}/select/logsql/query" \
    --data-urlencode "query=_time:[${start_iso}, now] | fields appname" \
    | jq -r '.appname' 2>/dev/null | sort -u)
fi

vl_present() {
  local svc="$1"
  echo "$vl_appnames" | grep -qx "$svc"
}

fail=0
header="$(printf '%-32s' 'SERVICE')"
divider="$(printf '%-32s' '-------')"
if [ "$check_loki" -eq 1 ]; then
  header+="$(printf ' %-6s' 'LOKI')"
  divider+="$(printf ' %-6s' '----')"
fi
if [ "$check_vl" -eq 1 ]; then
  header+="$(printf ' %-6s' 'VLOGS')"
  divider+="$(printf ' %-6s' '-----')"
fi
echo "$header"
echo "$divider"

for svc in "${SERVICES[@]}"; do
  row="$(printf '%-32s' "$svc")"
  miss=0
  if [ "$check_loki" -eq 1 ]; then
    if loki_present "$svc"; then
      row+="$(printf ' %-6s' '✓')"
    else
      row+="$(printf ' %-6s' '✗')"
      miss=1
    fi
  fi
  if [ "$check_vl" -eq 1 ]; then
    if vl_present "$svc"; then
      row+="$(printf ' %-6s' '✓')"
    else
      row+="$(printf ' %-6s' '✗')"
      miss=1
    fi
  fi
  echo "$row"
  [ "$miss" -eq 1 ] && fail=1
done

echo
echo "Queries used (swap the service name to check others):"
if [ "$check_loki" -eq 1 ]; then
  echo "  Loki:"
  echo "    curl -sG ${LOKI_URL}/loki/api/v1/query_range \\"
  echo "      --data-urlencode 'query={service=\"supabase-auth\"}' \\"
  echo "      --data-urlencode 'start=${start_ns}' \\"
  echo "      --data-urlencode 'end=${end_ns}'"
fi
if [ "$check_vl" -eq 1 ]; then
  echo "  VictoriaLogs:"
  echo "    curl -s ${VL_URL}/select/logsql/query \\"
  echo "      --data-urlencode 'query=appname:\"supabase-auth\" AND _time:[${start_iso}, now]'"
fi
echo
echo "Query patterns by symptom: docs/log-troubleshooting.md"
echo

if [ "$fail" -eq 0 ]; then
  echo "All services present."
  exit 0
else
  echo "One or more services missing - see table above."
  exit 1
fi
