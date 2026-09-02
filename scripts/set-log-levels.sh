#!/usr/bin/env bash
# Applies or resets per-service log verbosity via overrides/log-levels.yml,
# driven by SUPABASE_*_LOG_LEVEL in .env. Independent of scripts/verify-logs.sh,
# which uses the same override file but sets its own values inline without
# touching .env.
#
# `apply` only restarts services whose .env value differs from what's
# actually running right now - already-applied or unset services are left
# alone. `reset` only restarts services that are currently NOT at their
# upstream default. Either way, you get a diff before anything restarts.
#
# Usage:
#   scripts/set-log-levels.sh status         # show .env vs live, no changes
#   scripts/set-log-levels.sh apply [--yes]
#   scripts/set-log-levels.sh reset [--yes]

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OVERRIDE="${REPO_ROOT}/overrides/log-levels.yml"
OVERRIDE_ENVOY="${REPO_ROOT}/overrides/log-levels-envoy.yml"
OVERRIDE_KONG="${REPO_ROOT}/overrides/log-levels-kong.yml"
ENV_FILE="${REPO_ROOT}/.env"
SUPABASE_DIR="${SUPABASE_DIR:-$(grep "^SUPABASE_DIR=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-)}"

ACTION="${1:-}"
ASSUME_YES=false
[[ "${2:-}" == "--yes" ]] && ASSUME_YES=true

if [[ "$ACTION" != "status" && "$ACTION" != "apply" && "$ACTION" != "reset" ]]; then
  echo "Usage: $0 {status|apply|reset} [--yes]" >&2
  exit 2
fi

if [ -z "${SUPABASE_DIR}" ]; then
  echo "SUPABASE_DIR is not set."
  echo "Point it at your Supabase docker/ directory and retry, e.g.:"
  echo "  SUPABASE_DIR=/path/to/supabase/docker scripts/set-log-levels.sh ${ACTION}"
  exit 2
fi

if [ ! -f "${SUPABASE_DIR}/docker-compose.yml" ]; then
  echo "Can't find Supabase's docker-compose.yml at ${SUPABASE_DIR}."
  exit 2
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "No .env found at ${ENV_FILE}. Copy .env.example first."
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

SERVICES=(rest auth realtime storage functions db)

if docker ps --format '{{.Names}}' | grep -qx 'supabase-envoy'; then
  SERVICES=(envoy "${SERVICES[@]}")
elif docker ps --format '{{.Names}}' | grep -qx 'supabase-kong'; then
  SERVICES=(kong "${SERVICES[@]}")
fi

declare -A CONTAINER_NAME=(
  [rest]=supabase-rest
  [auth]=supabase-auth
  [realtime]=realtime-dev.supabase-realtime
  [storage]=supabase-storage
  [functions]=supabase-edge-functions
  [envoy]=supabase-envoy
  [kong]=supabase-kong
  [db]=supabase-db
)
# Empty means the level isn't in the container's env: db reads it from
# postgres itself, envoy from its command line.
declare -A ENV_KEY=(
  [rest]=PGRST_LOG_LEVEL
  [auth]=GOTRUE_LOG_LEVEL
  [realtime]=LOG_LEVEL
  [storage]=LOG_LEVEL
  [functions]=RUST_LOG
  [envoy]=""
  [kong]=KONG_LOG_LEVEL
  [db]=""
)
declare -A UPSTREAM_DEFAULT=(
  [rest]=error [auth]=info [realtime]=info [storage]=info
  [functions]=info [envoy]=info [kong]=notice [db]=fatal
)
# Compose service name where it differs from the name used here. Both
# gateways share the api-gw service; only the image swaps.
declare -A COMPOSE_SERVICE=(
  [envoy]=api-gw
  [kong]=api-gw
)

wanted_value() {
  local svc="$1" var
  var="SUPABASE_$(echo "$svc" | tr '[:lower:]' '[:upper:]')_LOG_LEVEL"
  grep "^${var}=" "$ENV_FILE" | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//'
}

live_value() {
  local svc="$1"
  local container="${CONTAINER_NAME[$svc]}"

  local running
  running="$(docker inspect "$container" --format '{{.State.Running}}' 2>/dev/null)"
  if [ "$running" != "true" ]; then
    echo "NOT_RUNNING"
    return
  fi

  if [ "$svc" = "db" ]; then
    docker exec "$container" psql -U postgres -tAc \
      "SHOW log_min_messages;" 2>/dev/null | tr -d '[:space:]'
    return
  fi

  if [ "$svc" = "envoy" ]; then
    local cmd
    cmd="$(docker inspect "$container" --format '{{range .Config.Cmd}}{{println .}}{{end}}' 2>/dev/null \
      | grep -A1 '^--log-level$' | tail -1)"
    if [ -z "$cmd" ]; then
      echo "${UPSTREAM_DEFAULT[$svc]}"
    else
      echo "$cmd"
    fi
    return
  fi

  local key="${ENV_KEY[$svc]}"
  local val
  val="$(docker inspect "$container" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep "^${key}=" | cut -d= -f2-)"

  if [ -z "$val" ]; then
    echo "${UPSTREAM_DEFAULT[$svc]}"
  else
    echo "$val"
  fi
}

compose_names() {
  local svc
  for svc in "$@"; do
    echo "${COMPOSE_SERVICE[$svc]:-$svc}"
  done
}

print_status() {
  local mode="$1"
  DIFF_SERVICES=()
  printf "%-12s %-10s %-10s\n" "SERVICE" ".ENV" "LIVE"
  printf "%-12s %-10s %-10s\n" "-------" "----" "----"
  local svc wanted live shown_wanted shown_live
  for svc in "${SERVICES[@]}"; do
    wanted="$(wanted_value "$svc")"
    live="$(live_value "$svc")"
    shown_wanted="${wanted:-(default)}"

    if [ "$live" = "NOT_RUNNING" ]; then
      shown_live="(not running)"
    else
      shown_live="$live"
    fi
    local note=""
    if [ "$live" != "NOT_RUNNING" ] && [ -n "$wanted" ] && [ "$wanted" != "$live" ]; then
      note="  (.env differs - apply to change, or edit .env to match)"
    fi
    printf "%-12s %-10s %-10s%s\n" "$svc" "$shown_wanted" "$shown_live" "$note"

    if [ "$live" = "NOT_RUNNING" ]; then
      continue
    fi

    if [ "$mode" = "apply" ]; then
      [ -n "$wanted" ] && [ "$wanted" != "$live" ] && DIFF_SERVICES+=("$svc")
    elif [ "$mode" = "reset" ]; then
      [ "$live" != "${UPSTREAM_DEFAULT[$svc]}" ] && DIFF_SERVICES+=("$svc")
    fi
  done
}

confirm_restart() {
  local list="$1"
  [ "$ASSUME_YES" = true ] && return 0
  echo
  echo "This will restart: ${list}"
  echo "In-flight requests to these services will be briefly interrupted."
  read -p "Continue? [y/N] " confirm
  [[ "$confirm" == "y" || "$confirm" == "Y" ]]
}

case "$ACTION" in
  status)
    print_status ""
    ;;
  apply)
    print_status "apply"
    if [ ${#DIFF_SERVICES[@]} -eq 0 ]; then
      echo
      echo "Nothing to apply - .env already matches what's running."
      exit 0
    fi
    confirm_restart "${DIFF_SERVICES[*]}" || { echo "Aborted."; exit 1; }

    for svc in "${DIFF_SERVICES[@]}"; do
      var="SUPABASE_$(echo "$svc" | tr '[:lower:]' '[:upper:]')_LOG_LEVEL"
      export "$var"="$(wanted_value "$svc")"
    done

    COMPOSE_EXTRA=()
    if [[ " ${DIFF_SERVICES[*]} " == *" envoy "* ]]; then
      COMPOSE_EXTRA=(-f "$OVERRIDE_ENVOY")
    elif [[ " ${DIFF_SERVICES[*]} " == *" kong "* ]]; then
      COMPOSE_EXTRA=(-f "$OVERRIDE_KONG")
    fi

    mapfile -t TARGETS < <(compose_names "${DIFF_SERVICES[@]}")

    if ! docker compose "${SUPABASE_COMPOSE_ARGS[@]}" -f "$OVERRIDE" \
      "${COMPOSE_EXTRA[@]}" up -d "${TARGETS[@]}"; then
      echo "Failed to apply - docker compose returned an error above." >&2
      exit 1
    fi
    echo "Applied: ${DIFF_SERVICES[*]}"
    ;;
  reset)
    print_status "reset"
    if [ ${#DIFF_SERVICES[@]} -eq 0 ]; then
      echo
      echo "Nothing to reset - everything is already at upstream defaults."
      exit 0
    fi
    confirm_restart "${DIFF_SERVICES[*]}" || { echo "Aborted."; exit 1; }

    mapfile -t TARGETS < <(compose_names "${DIFF_SERVICES[@]}")

    if ! docker compose "${SUPABASE_COMPOSE_ARGS[@]}" up -d "${TARGETS[@]}"; then
      echo "Failed to reset - docker compose returned an error above." >&2
      exit 1
    fi
    echo "Reset: ${DIFF_SERVICES[*]}"
    ;;
esac
