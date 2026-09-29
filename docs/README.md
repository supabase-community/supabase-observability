# Quick start

## Prerequisites

| Requirement | Note |
| --- | --- |
| A running self-hosted Supabase instance | The `supabase/docker` directory, already up |
| Docker Compose v2 | |
| bash 4 or newer | `scripts/verify-logs.sh` and `scripts/set-log-levels.sh` use `declare -A` and `mapfile`. macOS ships bash 3.2 - see [Platform notes](logs/README.md#platform-notes) |
| `curl`, `jq` | Used by `scripts/verify-logs.sh` to query the log store, and by the checks in [metrics/README.md](metrics/README.md#confirm-it-works) |
| `make` | Optional, every command below has a plain Compose equivalent |

This stack binds ports on localhost only: `9428` for VictoriaLogs or `3100`
for Loki, depending on which log backend you choose, and `8428` for
VictoriaMetrics. None should conflict with anything Supabase itself uses.

## Setup

```bash
git clone <this-repo>
cd supabase-observability
cp .env.example .env
```

Edit `.env`. At minimum:

| Variable | Value |
| --- | --- |
| `SUPABASE_DIR` | Absolute path to your Supabase `docker/` directory (the folder containing Supabase's own `docker-compose.yml`) |

Example:

```bash
SUPABASE_DIR=/home/you/supabase/docker
```

If you cloned Supabase with `git clone --depth 1 https://github.com/supabase/supabase`
and ran the quickstart from inside it, this is `<that clone>/docker`.

**Which gateway are you running?** Envoy ships in upstream's base compose;
Kong is added as an override. Either works here, detected at runtime, but
it's worth knowing which one you have before you start:

```bash
docker ps --format '{{.Names}}' | grep -E 'supabase-(kong|envoy)'
```

## Start logs

```bash
make up-logs
# verify-logs briefly restarts rest and db to raise their log levels -
# see below before running
make verify-logs
```

Two things worth knowing about the second command before you run it:

- It **restarts your Supabase `rest` and `db` containers** to temporarily
  raise their log levels, confirms logs are flowing, then restarts them
  again to put the levels back. It prompts before doing so.
- A `✓` in its output means that service reached the log store, not that
  every field got parsed. See [logs/fields.md](logs/fields.md) if a query
  later returns less than you expect.

```
SERVICE                          VLOGS
-------                          -----
supabase-envoy                    ✓
supabase-auth                     ✓
supabase-rest                     ✓
realtime-dev.supabase-realtime    ✓
supabase-storage                  ✓
supabase-edge-functions           ✓
supabase-db                       ✓
supabase-pooler                   ✓
All services present.
```

Full walkthrough, including what to do if it doesn't pass:
[logs/README.md](logs/README.md)

## Start metrics

```bash
make up-metrics
# regenerates jwt and .metrics-secrets.env from Supabase's own .env first
```

See [How the secrets are generated](metrics/README.md#how-the-secrets-are-generated) for why that's
needed.

Then one change on Supabase's side, since several of its metrics
endpoints are off by default or listen only inside their own container. Append the two override files to `COMPOSE_FILE` in
**Supabase's** `.env`, keeping what's already there:

```bash
# $SUPABASE_DIR/.env - before
COMPOSE_FILE=docker-compose.yml

# after
COMPOSE_FILE=docker-compose.yml:/home/you/supabase-observability/overrides/metrics.yml:/home/you/supabase-observability/overrides/metrics-envoy.yml
```

```bash
cd "$SUPABASE_DIR"
sh run.sh recreate
```

Two things worth knowing before you do:

- `sh run.sh recreate` **takes your whole Supabase stack down and back
  up**, so expect a short outage.
- The `COMPOSE_FILE` change stays until you remove it, and uses absolute
  paths into this repo - remove it before moving or deleting this repo.

Full walkthrough, including how to confirm it works:
[metrics/README.md](metrics/README.md)

## Stopping

```bash
make down-logs
make down-metrics
```

Each stops its pipeline and keeps what's already stored. To also delete
stored data, put log levels back to Supabase's defaults, or turn
Supabase's metrics endpoints back off, see
[logs/README.md](logs/README.md#stopping-and-removing) and
[metrics/README.md](metrics/README.md#stopping-and-removing).

## Confirming nothing upstream was touched

This project never writes to anything under your Supabase `docker/`
directory - only Compose overrides and runtime mechanisms. You can
confirm that directly:

```bash
git -C "$SUPABASE_DIR/.." status --short
```

Nothing from this stack should appear here, before or after running it.

Metrics is the one place you change something there yourself: two
entries in `COMPOSE_FILE` in `$SUPABASE_DIR/.env`. Supabase's git ignores
`.env`, so it won't show above. See what's registered with:

```bash
cd "$SUPABASE_DIR"
sh run.sh config
```

## Idle resource use

With one backend running and no traffic, measured with
`docker stats --no-stream`:

| Container | CPU | Memory |
| --- | --- | --- |
| `supabase-observability-vector` | 0.10% | 21.3MiB |
| `supabase-observability-victorialogs` | 0.27% | 6.7MiB |

Loki in place of VictoriaLogs:

| Container | CPU | Memory |
| --- | --- | --- |
| `supabase-observability-vector` | 0.02% | 21.3MiB |
| `supabase-observability-loki` | 0.53% | 56.6MiB |

Loki's idle memory climbs for a few minutes after startup before
settling - measure after at least 10 minutes of no traffic, not
immediately after `up-logs`.

Both combinations stay well under 150MB total.

## Other documents

| Document | Read it when |
| --- | --- |
| [logs/README.md](logs/README.md) | Setting up, starting, or confirming logs are flowing |
| [metrics/README.md](metrics/README.md) | Setting up metrics, enabling them on Supabase's side, or a job is down |
| [logs/levels.md](logs/levels.md) | A service is silent, or too loud |
| [logs/fields.md](logs/fields.md) | A query returns nothing you expected |
| [logs/troubleshooting.md](logs/troubleshooting.md) | Your app broke and you need the real error |
| [logs/debugging.md](logs/debugging.md) | You're working on the pipeline itself and need `vector top`/`vrl`/`tap` |
| [logs/pipeline-internals.md](logs/pipeline-internals.md) | You want to know why the log pipeline behaves the way it does |
| [logs/known-limitations.md](logs/known-limitations.md) | You want to know what's currently broken or incomplete in the log pipeline |
| [metrics/pipeline-internals.md](metrics/pipeline-internals.md) | You want to know why the metrics pipeline behaves the way it does |
| [metrics/known-limitations.md](metrics/known-limitations.md) | You want to know what's currently broken or incomplete in the metrics pipeline |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | You're opening a PR |