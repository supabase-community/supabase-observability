#!/usr/bin/env bash
# Generates the two local secret files the metrics pipeline needs to
# start: `jwt` (Bearer credential for Supavisor/Realtime scraping) and
# `.metrics-secrets.env` (postgres-exporter's DSN). Both are gitignored.
#
# Values come from $SUPABASE_DIR/.env, never from this project's own
# .env — same rule verify-logs.sh and set-log-levels.sh follow.
#
# Re-run this whenever ANON_KEY or POSTGRES_PASSWORD rotates upstream;
# it always overwrites both files.
#
# Reads SUPABASE_DIR from .env, or set it inline to override, e.g.
#   SUPABASE_DIR=/path/to/supabase/docker scripts/generate-metrics-secrets.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUPABASE_DIR="${SUPABASE_DIR:-$(grep "^SUPABASE_DIR=" "${REPO_ROOT}/.env" 2>/dev/null | tail -1 | cut -d= -f2-)}"

if [ -z "${SUPABASE_DIR}" ]; then
  echo "SUPABASE_DIR is not set."
  echo "Set it in .env, or point it at your Supabase docker/ directory and retry, e.g.:"
  echo "  SUPABASE_DIR=/path/to/supabase/docker scripts/generate-metrics-secrets.sh"
  exit 2
fi

if [ ! -f "${SUPABASE_DIR}/.env" ]; then
  echo "Can't find Supabase's .env at ${SUPABASE_DIR}."
  exit 2
fi

ANON_KEY="$(grep '^ANON_KEY=' "${SUPABASE_DIR}/.env" | tail -1 | cut -d= -f2-)"
POSTGRES_PASSWORD="$(grep '^POSTGRES_PASSWORD=' "${SUPABASE_DIR}/.env" | tail -1 | cut -d= -f2-)"

if [ -z "${ANON_KEY}" ]; then
  echo "ANON_KEY not found in ${SUPABASE_DIR}/.env."
  exit 2
fi

if [ -z "${POSTGRES_PASSWORD}" ]; then
  echo "POSTGRES_PASSWORD not found in ${SUPABASE_DIR}/.env."
  exit 2
fi

printf '%s' "${ANON_KEY}" > "${REPO_ROOT}/jwt"
chmod 644 "${REPO_ROOT}/jwt"

cat > "${REPO_ROOT}/.metrics-secrets.env" <<EOF
DATA_SOURCE_NAME=postgresql://postgres:${POSTGRES_PASSWORD}@supabase-db:5432/postgres?sslmode=disable
EOF
chmod 600 "${REPO_ROOT}/.metrics-secrets.env"

echo "Wrote jwt and .metrics-secrets.env."
