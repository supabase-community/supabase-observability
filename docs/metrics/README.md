# Metrics

The OpenTelemetry Collector scrapes each Supabase service's own metrics
endpoint, receives the metrics Storage pushes to it, and writes everything
to the metrics store - VictoriaMetrics by default.

```
                        scrape (pull)
supabase-auth       ─────────────────┐
supabase-rest       ─────────────────┤
supabase-imgproxy   ─────────────────┤
supabase-envoy      ─────────────────┤
supabase-pooler     ─────────────────┼──►  otel-collector  ──►  metrics store
realtime-dev...     ─────────────────┤           ▲
postgres-exporter   ─────────────────┘           │
        ▲ SQL                                    │
supabase-db                                      │
                                                 │
supabase-storage    ───── OTLP push (gRPC) ──────┘
```

Unlike logs, metrics needs a change on Supabase's side. Several of these
endpoints are off by default or listen only inside their own container, so
two override files have to be layered onto Supabase's own containers - see
[Enable metrics on Supabase's side](#enable-metrics-on-supabases-side).

## Terms

| Term | Here |
| --- | --- |
| Collector | `otel-collector`, the OpenTelemetry Collector. Scrapes services, receives Storage's push, and forwards everything to the store |
| Store | Where metrics are kept and queried. VictoriaMetrics by default, set by `BACKEND_METRICS` |
| `postgres-exporter` | A small container that gives Postgres a metrics endpoint for the collector to scrape |
| Exporter, in the collector's config | The part of the collector that writes to the store, set in each backend's [`otel-collector-exporter.yaml`](../../config/metrics/backends/victoriametrics/otel-collector-exporter.yaml) |
| Scrape, push | The collector pulls from most services; Storage sends its metrics instead |

## Setup at a glance

Setup happens in two directories: this repo, and your Supabase `docker/`
directory (`$SUPABASE_DIR`). The first two steps set up this project's
side, the next two turn on metrics in Supabase, and the last checks it.

| # | Where | Do | What happens |
| --- | --- | --- | --- |
| 1 | this repo | [Configure](#configure) `.env`: metrics block present | Names the store (`BACKEND_METRICS`) and its retention |
| 2 | this repo | [`make up-metrics`](#start) | Reads `ANON_KEY` and `POSTGRES_PASSWORD` from Supabase's `.env` (without changing it), writes them to `jwt` and `.metrics-secrets.env`, and starts the collector, `postgres-exporter`, and the metrics store |
| 3 | `$SUPABASE_DIR` | [Append](#enable-metrics-on-supabases-side) `overrides/metrics.yml` and `overrides/metrics-envoy.yml` to `COMPOSE_FILE` in `.env` | Nothing yet. Supabase's containers only pick this up when they're recreated |
| 4 | `$SUPABASE_DIR` | `sh run.sh recreate` | Supabase's containers come back with their metrics endpoints on. Expect a short outage |
| 5 | anywhere | [Confirm it works](#confirm-it-works) | 7 jobs at `up = 1`, and Storage series arriving |

## Configure

In `.env`, copied from [`.env.example`](../../.env.example):

| Variable | Values | Default |
| --- | --- | --- |
| `SUPABASE_DIR` | Absolute path to your Supabase `docker/` directory | required, see [../README.md](../README.md) |
| `BACKEND_METRICS` | A folder name in `config/metrics/backends/`: `victoriametrics` | `victoriametrics` |
| `METRICS_RETENTION_PERIOD` | e.g. `90d` | `90d` |

## How the secrets are generated

`make up-metrics` runs this for you - nothing to do here during setup:

```bash
scripts/generate-metrics-secrets.sh
```

```
$SUPABASE_DIR/.env              supabase-observability/          read by
──────────────────              ───────────────────────          ───────
ANON_KEY           ───────────► jwt                   (644) ───► otel-collector
                                                                 Bearer token for Supavisor, Realtime

POSTGRES_PASSWORD  ───────────► .metrics-secrets.env  (600) ───► postgres-exporter
                                                                 DATA_SOURCE_NAME
```

Both files are gitignored and overwritten on every run. Values always come
from Supabase's own `.env`, never this project's, so each secret has one
source. `jwt` is `644` rather than `600` because the collector runs as uid
`10001` and has to read it.

Only relevant later, if Supabase's own secrets change. `make up-metrics`
doesn't recreate a container that's already running, so after a value
changes, re-run the script and force-recreate the one that reads it:

| When | Then |
| --- | --- |
| `ANON_KEY` changes | `make up-metrics` (regenerates `jwt`), then `docker compose -f docker-compose.o11y-metrics.yml up -d --force-recreate otel-collector` |
| `POSTGRES_PASSWORD` changes | `make up-metrics` (regenerates `.metrics-secrets.env`), then `docker compose -f docker-compose.o11y-metrics.yml up -d --force-recreate postgres-exporter` |

## Start

```bash
make up-metrics
```

Without `make`:

```bash
scripts/generate-metrics-secrets.sh
docker compose -f docker-compose.o11y-metrics.yml up -d
```

| Container | Does |
| --- | --- |
| `supabase-observability-otel` | Scrapes and receives metrics, writes them to the metrics store |
| `supabase-observability-postgres-exporter` | Serves Postgres statistics as a metrics endpoint |
| `supabase-observability-vm` | Stores metrics |

This binds one port on localhost: `8428` for VictoriaMetrics. The collector
and `postgres-exporter` join Supabase's `supabase_default` network to reach
its containers; neither is published to the host. `supabase_default` is the
network name that follows from `name: supabase` in Supabase's own
`docker-compose.yml`. If you run Supabase under a different project name
(`COMPOSE_PROJECT_NAME` or `docker compose -p`), its network name changes
with it.

## Enable metrics on Supabase's side

An override file is a Compose file that adds or changes settings on
services Supabase's own `docker-compose.yml` already defines, without
editing that file. Register this project's two override files in
`COMPOSE_FILE` in
**Supabase's** `.env`, as absolute paths. See what's there now:

```bash
cd "$SUPABASE_DIR"
sh run.sh config
```

Keep every entry already listed and append the two files:

```bash
# $SUPABASE_DIR/.env
COMPOSE_FILE=docker-compose.yml:/home/you/supabase-observability/overrides/metrics.yml:/home/you/supabase-observability/overrides/metrics-envoy.yml
```

`metrics-envoy.yml` is for Envoy, the default gateway. If you run Kong,
leave it out - see [Known limitations](known-limitations.md).

Then recreate the Supabase stack:

```bash
sh run.sh recreate
```

This runs `docker compose down` and then `up -d --wait`, so expect a short
outage while every container comes back.

Check the overrides reached the containers:

```bash
docker inspect supabase-rest --format '{{range .Config.Env}}{{println .}}{{end}}' | grep PGRST_ADMIN_SERVER_HOST
docker inspect supabase-envoy --format '{{json .Config.Cmd}}'
```

`PGRST_ADMIN_SERVER_HOST=0.0.0.0`, and Envoy's command contains both
`--config-yaml` and `--log-level`.

### Why `COMPOSE_FILE`, not `-f` by hand

A container keeps only the Compose files passed to the command that last
created it. Every way a Supabase container gets recreated reads
`COMPOSE_FILE`:

```
recreated by                           Compose files it gets
────────────                           ─────────────────────
sh run.sh start / recreate             COMPOSE_FILE
docker compose up -d  (in docker/)     COMPOSE_FILE
a Supabase upgrade                     COMPOSE_FILE
scripts/set-log-levels.sh              COMPOSE_FILE + overrides/log-levels*.yml
scripts/verify-logs.sh                 COMPOSE_FILE + overrides/log-levels.yml
```

Pass the overrides once with `-f` instead, and the next recreate through
any row above drops them. Nothing errors - the job's `up` just goes to `0`.
Registered in `COMPOSE_FILE`, every row includes them.

**Moving or deleting this repo breaks Supabase's own commands** while the
paths are registered. Compose stops with an error on any `COMPOSE_FILE`
entry it can't find, so remove the two entries first - see
[Stopping and removing](#stopping-and-removing).

**This project's stack being down doesn't affect Supabase.** Storage keeps
running normally with the collector stopped, including across a Storage
restart, so the overrides can stay registered whether or not this stack is
up.

## Confirm it works

Give it a minute. Scrapes run on Prometheus' default one-minute
[`scrape_interval`](https://prometheus.io/docs/prometheus/latest/configuration/configuration/),
which `config/metrics/otel-collector.yaml` doesn't override.

```bash
curl -sG http://localhost:8428/api/v1/query \
  --data-urlencode 'query=up' \
  | jq -r '.data.result[] | "\(.metric.job)  \(.value[1])"' | sort
```

These seven jobs, each at `1`:

| `job` | Target |
| --- | --- |
| `supabase-auth` | `supabase-auth:9100` |
| `supabase-envoy` | `supabase-envoy:9901` |
| `supabase-imgproxy` | `supabase-imgproxy:8081` |
| `supabase-postgres` | `postgres-exporter:9187` |
| `supabase-realtime` | `realtime-dev.supabase-realtime:4000` |
| `supabase-rest` | `supabase-rest:3001` |
| `supabase-supavisor` | `supabase-pooler:4000` |

Storage isn't in that list. `up` only exists for targets the collector
scrapes, and Storage pushes instead. Check it separately:

```bash
curl -sG http://localhost:8428/api/v1/query \
  --data-urlencode 'query=count(count by (__name__) ({job="storage_api"}))' \
  | jq -r '.data.result[0].value[1]'
```

A number is how many distinct Storage metrics have arrived. `null` means
none have.

`supabase-postgres` at `1` confirms `postgres-exporter` is reachable, not
that every group of metrics it produces arrives. Check the group that has
broken before, the `pg_settings` metrics:

```bash
curl -sG http://localhost:8428/api/v1/query \
  --data-urlencode 'query=count({__name__=~"pg_settings_.+"})' \
  | jq -r '.data.result[0].value[1]'
```

`325` on `supabase/postgres:17.6.1.136`. If it's `null` while
`supabase-postgres` is `1`, check the exporter version first - before
`v0.20.0` it drops `pg_settings` entirely on Supabase's Postgres. See
[pipeline internals](pipeline-internals.md#postgres-exporter).

## What gets scraped

```
otel-collector
├── supabase-auth        supabase-auth:9100                    /
├── supabase-rest        supabase-rest:3001                    /metrics
├── supabase-imgproxy    supabase-imgproxy:8081                /metrics
├── supabase-envoy       supabase-envoy:9901                   /stats/prometheus
├── supabase-supavisor   supabase-pooler:4000                  /metrics            Bearer jwt
├── supabase-realtime    realtime-dev.supabase-realtime:4000   /metrics            Bearer jwt
├── supabase-postgres    postgres-exporter:9187                /metrics
│
└── ◄── storage_api      pushed by supabase-storage to otel-collector:4317 (OTLP gRPC)
```

What the overrides change, and why each one is needed:

| Service | `job` | Changed | Why |
| --- | --- | --- | --- |
| Auth (GoTrue) | `supabase-auth` | `GOTRUE_METRICS_ENABLED=true`, `GOTRUE_METRICS_EXPORTER=prometheus` | Off by default, and the default exporter is `opentelemetry`, not `prometheus`. Serves on `:9100` at `/`, not `/metrics` |
| PostgREST (`rest`) | `supabase-rest` | `PGRST_ADMIN_SERVER_HOST=0.0.0.0` | Supabase's compose sets `PGRST_ADMIN_SERVER_HOST: localhost`, which only the container itself can reach. The override also sets `PGRST_ADMIN_SERVER_PORT=3001`. Supabase's compose uses the same value; it's set here so the scrape target doesn't depend on it |
| imgproxy | `supabase-imgproxy` | `IMGPROXY_PROMETHEUS_BIND=:8081` | Off unless set |
| Envoy | `supabase-envoy` | Admin rebound to `0.0.0.0:9901`, restricted to `/stats` with `allow_paths` | Admin listens on `127.0.0.1` by default, and the same port serves `/config_dump` - see [Security considerations](#security-considerations) |
| Storage | `storage_api` | `OTEL_METRICS_ENABLED=true`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://supabase-observability-otel:4317` | Storage pushes over OTLP rather than being scraped |
| Supavisor | `supabase-supavisor` | Nothing | On by default. Needs the Bearer JWT from `jwt` |
| Realtime | `supabase-realtime` | Nothing | On by default. Needs the same Bearer JWT |
| Postgres | `supabase-postgres` | Nothing | No endpoint of its own. This project's `postgres-exporter` connects straight to `supabase-db` and serves one |

Env vars and command-line flags are only read when a container is created,
which is why the overrides need `sh run.sh recreate` rather than a
restart.

Not scraped: Studio, postgres-meta, Edge Functions, and Kong. See
[Known limitations](known-limitations.md#gaps-in-what-is-collected).

## Troubleshooting: a metrics job shows 0 or is missing

```
up is 0, or a job is missing
│
├── every job missing ─────────────────► the collector or the metrics store isn't running
│                                        docker ps --filter name=supabase-observability
│                                        then docker logs <the missing container>
│
├── auth / rest / imgproxy / envoy ────► the container was created without the overrides
│                                        check with the commands below
│                                        fix: sh run.sh recreate  (in $SUPABASE_DIR)
│
├── supavisor / realtime ──────────────► jwt is missing, or ANON_KEY changed since it was written
│                                        fix: regenerate, force-recreate otel-collector
│
└── postgres ──────────────────────────► .metrics-secrets.env missing or stale
                                         fix: regenerate, force-recreate postgres-exporter
```

Regenerating is covered in [How the secrets are generated](#how-the-secrets-are-generated).

Check whether a Supabase container has the overrides. Use `docker inspect`
rather than `docker exec` - `supabase-auth` and `supabase-rest` have no
shell:

```bash
docker inspect supabase-auth     --format '{{range .Config.Env}}{{println .}}{{end}}' | grep GOTRUE_METRICS
docker inspect supabase-rest     --format '{{range .Config.Env}}{{println .}}{{end}}' | grep PGRST_ADMIN_SERVER_HOST
docker inspect supabase-imgproxy --format '{{range .Config.Env}}{{println .}}{{end}}' | grep IMGPROXY_PROMETHEUS_BIND
docker inspect supabase-storage  --format '{{range .Config.Env}}{{println .}}{{end}}' | grep OTEL_
docker inspect supabase-envoy    --format '{{json .Config.Cmd}}'
```

| Container | Has the overrides when |
| --- | --- |
| `supabase-auth` | `GOTRUE_METRICS_ENABLED=true` and `GOTRUE_METRICS_EXPORTER=prometheus` |
| `supabase-rest` | `PGRST_ADMIN_SERVER_HOST=0.0.0.0` |
| `supabase-imgproxy` | `IMGPROXY_PROMETHEUS_BIND=:8081` |
| `supabase-storage` | `OTEL_METRICS_ENABLED=true` and the `OTEL_EXPORTER_OTLP_ENDPOINT` above |
| `supabase-envoy` | `--config-yaml` followed by the admin block |

If a value is missing, the container predates the registration, or
`COMPOSE_FILE` doesn't list the file. Run `sh run.sh config` in
`$SUPABASE_DIR` before recreating.

**Changed a file in this repo and nothing happened?** The collector reads
`config/metrics/otel-collector.yaml` and the backend's
`otel-collector-exporter.yaml` at startup, and `up -d` doesn't recreate a
container whose only change is a mounted file's contents:

```bash
docker compose -f docker-compose.o11y-metrics.yml up -d --force-recreate otel-collector
```

A change to `overrides/metrics.yml` or `overrides/metrics-envoy.yml`
applies to Supabase's containers instead, so it needs
`sh run.sh recreate` in `$SUPABASE_DIR`.

## Changing log levels with metrics on

`scripts/set-log-levels.sh` recreates the containers it changes, so it has
to carry the metrics overrides along. It does, because it reads
`COMPOSE_FILE`:

```
scripts/set-log-levels.sh apply | reset
│
├── expands COMPOSE_FILE from $SUPABASE_DIR/.env
│     └── includes overrides/metrics.yml
│           rest, auth, storage keep their metrics settings after recreate
│
└── Envoy
      ├── metrics-envoy.yml registered ──► log-levels-envoy.yml is left out.
      │                                    metrics-envoy.yml sets --log-level itself,
      │                                    from SUPABASE_ENVOY_LOG_LEVEL (default info)
      │
      └── not registered ─────────────────► log-levels-envoy.yml, as without metrics
```

The Envoy branch exists because Compose replaces a service's `command`
across files rather than merging it. Both files set Envoy's `command`, so
whichever came last would silently drop the other - see
[pipeline internals](pipeline-internals.md#envoy).

`SUPABASE_ENVOY_LOG_LEVEL` in `.env` works the same either way - see
[../logs/levels.md](../logs/levels.md).

## Switching backends

VictoriaMetrics is currently the only backend. Each backend is a folder
under `config/metrics/backends/`, and `BACKEND_METRICS` names the folder:

```
config/metrics/backends/victoriametrics/
├── compose.yml                    the store container, run as metrics-store
└── otel-collector-exporter.yaml   where the collector sends metrics
```

To add one, copy the folder and rename it. In the new `compose.yml`, keep
the service name `metrics-store` and set the network alias to the folder
name - the exporter's endpoint uses it as the host. Declare the store's
data volume in `docker-compose.o11y-metrics.yml` too: Compose doesn't carry
volume declarations over from the backend's file. Then set
`BACKEND_METRICS` and run `make up-metrics`, which replaces the running
store.

## Stopping and removing

```bash
make down-metrics
```

| Goal | Command |
| --- | --- |
| Stop, keep stored metrics | `make down-metrics` |
| Stop and delete stored metrics | `docker compose -f docker-compose.o11y-metrics.yml down -v` |
| Put Supabase's containers back to upstream defaults | Remove the two entries from `COMPOSE_FILE` in `$SUPABASE_DIR/.env`, then `sh run.sh recreate` |

```
make down-metrics          ──► this project's 3 containers stop
                               Supabase still has its endpoints enabled
                               Storage keeps running normally

remove from COMPOSE_FILE   ──► Supabase back to upstream defaults
 + sh run.sh recreate          required before moving or deleting this repo
```

## Querying (VictoriaMetrics)

VictoriaMetrics ships a UI at `http://localhost:8428/vmui/`.

Queries use [MetricsQL](https://docs.victoriametrics.com/metricsql/), a
superset of PromQL:

| Query | Finds |
| --- | --- |
| `up` | Every scrape target, `1` up or `0` down |
| `up{job="supabase-rest"}` | One target |
| `count by (job) ({job=~".+"})` | Series count per job |
| `count by (__name__) ({job="supabase-auth"})` | Every metric name one job produces |
| `{job="storage_api"}` | Everything Storage has pushed |

Over HTTP, pass the query with `--data-urlencode`:

```bash
curl -sG http://localhost:8428/api/v1/query \
  --data-urlencode 'query=up{job="supabase-auth"}'
```

If you put a query straight into the URL instead, two things break
without an error. `curl` reads unescaped `{` and `}` as its own range
syntax and strips label selectors, unless you pass `-g`. And `+` in a
query string decodes as a space, breaking regexes like `.+`, unless you
write it as `%2B`. `--data-urlencode` avoids both.

### Labels

| Label | From a scrape job | From Storage's push |
| --- | --- | --- |
| `job` | The job's `job_name`, e.g. `supabase-auth` | `storage_api`, from OTel's `service.name` |
| `instance` | The target, e.g. `supabase-auth:9100` | `<container-id>:pid:1`, changes on every recreate |
| `service` | Set on each job in the config, e.g. `auth` | Not set |

`service` is a static label on each scrape job in
`config/metrics/otel-collector.yaml`. Storage's
push doesn't go through a scrape job, so filter it by `job`.

## Security considerations

**Envoy's admin port is rebound from `127.0.0.1` to `0.0.0.0`.** The same
port that serves `/stats/prometheus` also serves `/config_dump`, which
returns API keys and JWTs in plaintext. `allow_paths` restricts the
rebound listener to `/stats`, enforced by Envoy itself rather than a proxy
in front of it:

```
supabase-envoy:9901
├── /stats/prometheus                      200
├── /config_dump                           403
└── /config_dump?path=/../stats/prometheus 403
```

A proxy that forwards only `/stats/prometheus` to the admin port is the
shape of
[CVE-2025-24030](https://github.com/envoyproxy/gateway/security/advisories/GHSA-j777-63hf-hx76),
where path traversal reached the rest of the admin handlers. See
[Envoy's `allow_paths`](https://www.envoyproxy.io/docs/envoy/v1.39.0/start/quick-start/admin).

**None of the enabled endpoints is published to the host.** They're
reachable from containers on `supabase_default` only. That network's
trust boundary is anything the Docker daemon attaches to it - any Compose
project declaring it `external: true`, or `docker network connect` - which
in turn takes Docker socket access, effectively root on the host.

**PostgREST's admin port serves more than metrics.** Rebinding it to
`0.0.0.0` also makes `/live`, `/ready`, and `/schema_cache` reachable from
`supabase_default`. `/schema_cache` returns your tables, relationships,
and functions - see PostgREST's
[admin server](https://docs.postgrest.org/en/v14/references/admin_server.html).

**Two secrets sit on disk in this repo.**

| File | Holds | Mode |
| --- | --- | --- |
| `jwt` | Supabase's `ANON_KEY` | `644` |
| `.metrics-secrets.env` | `POSTGRES_PASSWORD`, in plaintext, inside a connection string for the `postgres` role | `600` |

Both are gitignored. The scrape credential for Supavisor and Realtime is
`ANON_KEY` because upstream sets their `METRICS_JWT_SECRET` to
`JWT_SECRET` - there's no metrics-only secret. See
[Known limitations](known-limitations.md#issues-in-how-the-pipeline-behaves).

**Enabling metrics changes your Supabase `.env`.** It's a change you make
by hand, and it persists: every recreate from then on includes the
overrides. Supabase's git ignores `.env`, so `git status` in your Supabase
checkout won't show it. `sh run.sh config` in `$SUPABASE_DIR` will.

## Platform notes

- `supabase-auth`, `supabase-rest`, and this project's
  `supabase-observability-otel` are distroless - no shell, no
  `curl`/`wget`/`ls`, so `docker exec` into them fails. Read their
  settings with `docker inspect`, and reach their endpoints from a
  throwaway container on the same network:
  ```bash
  docker run --rm --network supabase_default curlimages/curl -s http://supabase-rest:3001/metrics
  ```
- Shell examples use GNU coreutils syntax (Linux default).