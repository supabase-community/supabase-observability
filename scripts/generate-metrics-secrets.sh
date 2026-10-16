#!/usr/bin/env bash
# Generates the two local secret files the metrics pipeline needs to
# start: `jwt` (Bearer token for Supavisor/Realtime scraping) and
# `.metrics-secrets.env` (postgres-exporter's DSN). Both are gitignored.
#
# Values come from $SUPABASE_DIR/.env, never from this project's own
# .env — same rule verify-logs.sh and set-log-levels.sh follow.
#
# `jwt` is an HS256 token signed with METRICS_JWT_SECRET, or with
# JWT_SECRET when METRICS_JWT_SECRET is unset or empty - the same value
# overrides/metrics.yml gives realtime and supavisor.
#
# Re-run this whenever METRICS_JWT_SECRET, JWT_SECRET or POSTGRES_PASSWORD
# changes in Supabase's .env; it always overwrites both files.
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

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl is required to sign the jwt file."
  exit 2
fi

METRICS_JWT_SECRET="$(grep '^METRICS_JWT_SECRET=' "${SUPABASE_DIR}/.env" | tail -1 | cut -d= -f2-)"
JWT_SECRET="$(grep '^JWT_SECRET=' "${SUPABASE_DIR}/.env" | tail -1 | cut -d= -f2-)"
POSTGRES_PASSWORD="$(grep '^POSTGRES_PASSWORD=' "${SUPABASE_DIR}/.env" | tail -1 | cut -d= -f2-)"

SIGNING_SECRET="${METRICS_JWT_SECRET:-${JWT_SECRET}}"

if [ -z "${SIGNING_SECRET}" ]; then
  echo "Neither METRICS_JWT_SECRET nor JWT_SECRET found in ${SUPABASE_DIR}/.env."
  exit 2
fi

if [ -z "${POSTGRES_PASSWORD}" ]; then
  echo "POSTGRES_PASSWORD not found in ${SUPABASE_DIR}/.env."
  exit 2
fi

b64url() {
  openssl enc -base64 -A | tr '+/' '-_' | tr -d '='
}

IAT="$(date +%s)"
EXP=$((IAT + 5 * 365 * 24 * 3600))
HEADER="$(printf '%s' '{"alg":"HS256","typ":"JWT"}' | b64url)"
PAYLOAD="$(printf '%s' "{\"role\":\"metrics\",\"iss\":\"supabase-observability\",\"iat\":${IAT},\"exp\":${EXP}}" | b64url)"
SIGNATURE="$(printf '%s' "${HEADER}.${PAYLOAD}" | openssl dgst -binary -sha256 -hmac "${SIGNING_SECRET}" | b64url)"

printf '%s' "${HEADER}.${PAYLOAD}.${SIGNATURE}" > "${REPO_ROOT}/jwt"
chmod 644 "${REPO_ROOT}/jwt"

cat > "${REPO_ROOT}/.metrics-secrets.env" <<EOF
DATA_SOURCE_NAME=postgresql://postgres:${POSTGRES_PASSWORD}@supabase-db:5432/postgres?sslmode=disable
EOF
chmod 600 "${REPO_ROOT}/.metrics-secrets.env"

echo "Wrote jwt and .metrics-secrets.env."
