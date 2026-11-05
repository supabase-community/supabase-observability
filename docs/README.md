# Quick start

## Updating an existing install

Skip this section if you have not started this stack before.

Earlier checkouts used one Compose project name, `supabase-observability`, for
everything. Logs and metrics now have their own projects,
`supabase-observability-logs` and `supabase-observability-metrics`, so
`make down-logs` after pulling no longer finds containers started under the
old name.

To see which project your containers belong to, running or stopped:

```bash
docker ps -a --filter name=supabase-observability --format 'table {{.Names}}\t{{.Label "com.docker.compose.project"}}'
```

If nothing is listed, or the project column shows
`supabase-observability-logs`, `supabase-observability-metrics`, or
`supabase-observability-dashboards`, there is nothing to do. Continue with
[Setup](#setup).

If it shows `supabase-observability`, you started the stack under the old name.
Update in this order.

**Step 1.** Before pulling, stop the stack from the checkout you started it
from:

```bash
make down-logs
make down-metrics   # if that checkout has this target
```

**Step 2.** Pull and start again:

```bash
git pull
make up-logs
make up-metrics   # if you run metrics
```

Stored logs and metrics from the old install are not carried over: the new
projects use new volumes. The old `supabase-observability_*` volumes stay on
disk until you remove them with `docker volume rm`.

**Step 3.** If you run metrics, recreate Supabase's Storage so it picks up the
new collector address:

```bash
(cd "$SUPABASE_DIR" && docker compose up -d storage)
```

If you pulled first, `make up-logs` or `make up-metrics` can fail, for example
with `container name ... is already in use`. Remove the old containers and
start again:

```bash
docker rm -f $(docker ps -aq --filter name=supabase-observability)
make up-logs
make up-metrics   # if you run metrics
```

## Prerequisites

| Requirement | Note |
| --- | --- |
| A running self-hosted Supabase instance | The `supabase/docker` directory, already up |
| Docker Compose v2 | |
| bash 4 or newer, for `scripts/set-log-levels.sh` | It uses `declare -A` and `mapfile`. macOS ships bash 3.2 - see [Platform notes](logs/README.md#platform-notes). `scripts/verify-logs.sh` also runs on bash 3.2 |
| `curl`, `jq` | Used by `scripts/verify-logs.sh` to query the log store, and by the checks in [metrics/README.md](metrics/README.md#confirm-it-works) |
| `openssl` | Used by `scripts/generate-metrics-secrets.sh` to sign the metrics token and make `postgres_exporter`'s password, and by the command that creates `METRICS_JWT_SECRET` |
| `make` | Optional, every command below has a plain Compose equivalent |

This stack binds ports on localhost only: `9428` for VictoriaLogs or `3100`
for Loki, depending on which log backend you choose, `8428` for
VictoriaMetrics, and `3000` for Grafana. None should conflict with anything
Supabase itself uses. If something on your machine already uses `3000`, set
`GRAFANA_PORT` in `.env`.

Logs, metrics, and Grafana are separate Compose projects
(`supabase-observability-logs`, `supabase-observability-metrics`, and
`supabase-observability-dashboards`). If
`COMPOSE_PROJECT_NAME` is set in your shell, Compose uses it instead of the
`name:` in these files, and all of them end up in one project - see
[Compose's project name precedence](https://docs.docker.com/compose/how-tos/project-name/).

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

First give Realtime and Supavisor a metrics secret, in **Supabase's** `.env`:

```bash
printf '\nMETRICS_JWT_SECRET=%s\n' "$(openssl rand -base64 30)" >> "$SUPABASE_DIR/.env"
```

Then:

```bash
make up-metrics
# regenerates jwt and .metrics-secrets.env first
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

## Start Grafana

Set a password for Grafana's `admin` login in `.env` first. Grafana creates
the login on its first start, and changing `GRAFANA_ADMIN_PASSWORD`
afterwards does not change an existing login:

```bash
GRAFANA_ADMIN_PASSWORD=<choose one>
```

Then:

```bash
make up-dashboards
```

Open `http://127.0.0.1:3000` and sign in as `admin`. Under Connections, Data
sources, you will find the metrics store and the log store you chose, already
set up - there is nothing to add by hand. Both show an error until their
stores are running, so start [logs](#start-logs) and
[metrics](#start-metrics) first.

Worth knowing:

- Grafana listens on `127.0.0.1` only, like every other port in this stack.
  Set `GRAFANA_PORT` in `.env` to change the port.
- The first start downloads the VictoriaLogs plugin from grafana.com, so it
  needs internet access once. The plugin is kept in the `grafana_data`
  volume. Loki needs no plugin.
- If you change `BACKEND_LOGS` after Grafana's first start, Grafana adds the
  new log datasource but keeps the old one in the `grafana_data` volume. To
  remove the old one, reset Grafana with
  `docker compose -f docker-compose.o11y-dashboards.yml down -v` and run
  `make up-dashboards`. The reset also removes Grafana's login, which is
  created again from `.env`.
- If you already run logs or metrics from an earlier checkout, `make up-logs`
  and `make up-metrics` now create a shared Docker network,
  `supabase-observability`, and recreate the store containers to join it.
  Stored data is kept, but expect a few seconds of interruption.
- To start Grafana over, including its login, run
  `docker compose -f docker-compose.o11y-dashboards.yml down -v`.

## Stopping

```bash
make down-logs
make down-metrics
make down-dashboards
```

Each stops its Compose project and keeps what's already stored. To also delete
stored data, put log levels back to Supabase's defaults, or turn
Supabase's metrics endpoints back off, see
[logs/README.md](logs/README.md#stopping-and-removing) and
[metrics/README.md](metrics/README.md#stopping-and-removing). Grafana keeps its
login and plugin in the `grafana_data` volume; to reset it, see
[Start Grafana](#start-grafana).

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

Both combinations stay well under 150MB total, without Grafana.

Grafana is one more container, measured the same way with the VictoriaLogs
plugin installed:

| Container | CPU | Memory |
| --- | --- | --- |
| `supabase-observability-grafana` | 0.55% | 102.2MiB |

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