# Metrics pipeline internals

Why the metrics pipeline is shaped the way it is. For setup see
[README.md](README.md); for what's currently broken or incomplete see
[known-limitations.md](known-limitations.md).

## Compared to a typical Prometheus setup

A common single-node default is one Prometheus server doing all of it -
scraping, storing, and answering queries in one process. Prometheus can
also send its series to a separate store over remote write, the protocol
the collector uses here.

```
typical                              this project
───────                              ────────────
Prometheus server                    otel-collector        scrapes, receives Storage's push
├── scrapes targets                        │               stores nothing itself
├── stores series                          │ remote write
└── answers queries                        ▼
                                     metrics store         stores series, answers queries
                                     (BACKEND_METRICS)
```

Here collecting and storing are separate containers. The collector keeps
nothing beyond an in-memory send queue (see
[Its queue is memory-only](#its-queue-is-memory-only)) and forwards
everything to the store that `BACKEND_METRICS` picks. That split lets the
store be swapped without touching the scrape config, and matches the log
pipeline, where Vector collects and the log store stores.

## The collector

```
otel-collector    --config=base.yaml --config=backend.yaml    (merged into one)
│
├── receivers                                        config/metrics/otel-collector.yaml
│   ├── prometheus        7 scrape jobs, pull
│   └── otlp              gRPC on 0.0.0.0:4317, Storage pushes here
│
├── processors                                       config/metrics/otel-collector.yaml
│   └── batch             groups data points into fewer, larger requests
│
└── exporters                                        config/metrics/backends/${BACKEND_METRICS}/
    │                                                    otel-collector-exporter.yaml
    └── prometheusremotewrite
          endpoint              http://victoriametrics:8428/api/v1/write
          disable_scope_info    true
```

`config/metrics/otel-collector.yaml` holds everything that stays the same
whichever store you use. The backend's `otel-collector-exporter.yaml` holds
only the exporter and the pipeline wiring, and `BACKEND_METRICS` picks which
one is mounted - the same split the log pipeline uses between
`config/logs/vector.yaml` and each backend's `vector-sink.yaml`. Inside the
container they're `/etc/otel/base.yaml` and `/etc/otel/backend.yaml`.

One collector takes both paths in. Every service's metrics, scraped or
pushed, reach the store through the same exporter, so settings like
`disable_scope_info` apply to all of them at once.

## Remote write, not OTLP, into the store

Seven of the eight sources expose Prometheus-format metrics. Exporting
them over OTLP would convert Prometheus names into OTel's form and back
again at the store. `prometheusremotewrite` sends them as they were
scraped, and the same exporter works for other remote-write stores too -
Mimir, Thanos, Amazon Managed Prometheus.

### Its queue is memory-only

`prometheusremotewrite` doesn't support the collector's `sending_queue`
or `file_storage`. It has its own `remote_write_queue`, held in memory.

```
scrape / push ──► batch ──► remote_write_queue (memory) ──► metrics store
                                    │
                                    └── collector restarts: queued data is lost
```

This is tracked upstream in
[opentelemetry-collector-contrib#33137](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/33137).
Unlike the log pipeline's VictoriaLogs sink, there is no disk buffer to
turn on.

## `disable_scope_info`

By default the exporter adds `otel_scope_name` and `otel_scope_version` to
every series. Neither carries information here: `job`, `instance`, and
`service` already identify the source, and `otel_scope_version` is the
collector's own version, so upgrading the collector would start a new
series for every metric and break `rate()` across the upgrade.

`disable_scope_info: true` removes both at the export stage. That also
covers sources that embed these labels themselves - GoTrue's `/` endpoint
carries `otel_scope_name="github.com/XSAM/otelsql"` from its database
instrumentation, and those labels are gone once stored.

## Labels

```
scrape job (otel-collector.yaml)                stored series
────────────────────────────────                ─────────────
job_name: supabase-auth              ───►       job="supabase-auth"
targets:  ["supabase-auth:9100"]     ───►       instance="supabase-auth:9100"
labels:   { service: auth }          ───►       service="auth"


Storage OTLP resource attribute                 stored series
───────────────────────────────                 ─────────────
service.name = storage_api           ───►       job="storage_api"
(container identity)                 ───►       instance="<container-id>:pid:1"
                                                no service label
```

The exporter maps OTel's `service.name` to `job`, not to a
`service_name` label - query Storage with `{job="storage_api"}`. Its
`instance` embeds the container ID, so it changes every time the Storage
container is recreated.

## Storage pushes

Every other service exposes an endpoint the collector scrapes. Storage
pushes over OTLP gRPC to the collector's `otlp` receiver, enabled by two
variables in `overrides/metrics.yml`:

| Variable | Value |
| --- | --- |
| `OTEL_METRICS_ENABLED` | `true` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://supabase-observability-otel:4317` |

`PROMETHEUS_METRICS_ENABLED` isn't needed for this. It turns on Storage's
separate pull endpoint on admin port `5001`, which this pipeline doesn't
use.

What follows from push:

| | Scraped services | Storage |
| --- | --- | --- |
| `up` metric | Yes | No - `up` only exists for scrape targets |
| Collector down | Nothing scrapes, gap in data | Storage keeps running normally, including across a Storage restart |
| `instance` label | `host:port`, stable | Changes on every recreate |

## Why the overrides live in `COMPOSE_FILE`

A container keeps only the Compose files passed to the command that last
created it. Metrics settings on Supabase's side are env vars and command
flags, read only at creation, so any recreate that leaves the override
files out drops them:

```
sh run.sh recreate ─┐
docker compose up ──┤                          ┌── overrides passed ──► metrics on
Supabase upgrade ───┼──► container recreated ──┤
set-log-levels.sh ──┤                          └── overrides left out ─► metrics off,
verify-logs.sh ─────┘                                                    no error,
                                                                         up goes to 0
```

This is how auth, rest, imgproxy, and envoy can all sit at `up` 0 with
nothing reporting it. Every path in the diagram reads `COMPOSE_FILE`, so
registering the two files there puts every path on the top branch.

Paths are absolute because the files live in this repo, outside
Supabase's `docker/` directory. Compose accepts absolute entries in
`COMPOSE_FILE`, and fails loudly - not silently - if one is missing.

| Alternative | Why not |
| --- | --- |
| Pass `-f overrides/metrics.yml` by hand | Holds until the next recreate from any other path |
| `sh run.sh config add` | Only accepts `docker-compose.*.yml` names inside `docker/` |
| Copy the overrides into `docker/docker-compose.override.yml` | The copy drifts silently whenever this repo's overrides change |

Both scripts in this repo expand `COMPOSE_FILE` by hand - see
[../logs/levels.md](../logs/levels.md#why-the-scripts-expand-compose_file-by-hand) -
and pass absolute entries through unchanged.

## Envoy

Envoy's admin listener binds `127.0.0.1` by default, so no other
container can reach `/stats/prometheus`. The same listener serves
`/config_dump`, which returns API keys and JWTs in plaintext, so it can't
simply be rebound.

`allow_paths` is Envoy's own answer: the listener moves to `0.0.0.0` and
Envoy refuses every admin path except those under `/stats`. Filtering in a
proxy in front of the admin port instead would repeat
[CVE-2025-24030](https://github.com/envoyproxy/gateway/security/advisories/GHSA-j777-63hf-hx76),
where path traversal got past a `/stats/prometheus`-only route to the
rest of the admin handlers.

The admin block goes in through `--config-yaml`, which Envoy merges over
the bootstrap loaded with `-c`. Upstream mounts its own entrypoint, which
ends with `exec envoy -c /etc/envoy/envoy.yaml "$@"`, so command args are
appended rather than replacing upstream's config:

```
envoy -c /etc/envoy/envoy.yaml  --config-yaml '<admin block>'  --log-level info
      │                         │                              │
      └── upstream bootstrap    └── merged over it             └── SUPABASE_ENVOY_LOG_LEVEL
                                    (overrides/metrics-envoy.yml)   (overrides/metrics-envoy.yml)
```

**Why `metrics-envoy.yml` also sets the log level.** Compose replaces a
service's `command` across files instead of merging it:

```
overrides/metrics-envoy.yml     command: [--config-yaml, <admin>, --log-level, ...]
overrides/log-levels-envoy.yml  command: [--log-level, ...]
                                          │
                                          └── applied after → replaces the whole array,
                                              admin block gone, envoy job at up 0
```

So while `metrics-envoy.yml` is registered, it's the only file that sets
Envoy's `command`. It carries `--log-level` from
`SUPABASE_ENVOY_LOG_LEVEL` (default `info`, Envoy's own default), and
`scripts/set-log-levels.sh` leaves `log-levels-envoy.yml` out.

The admin block and `allow_paths` must never be split into separate
files: rebinding to `0.0.0.0` without `allow_paths` would expose
`/config_dump`.

## Supavisor and Realtime credentials

Both check a Bearer JWT against `METRICS_JWT_SECRET`, which upstream's
compose sets to `${JWT_SECRET}`. Supabase's `ANON_KEY` is signed with
`JWT_SECRET`, so it passes:

```
$SUPABASE_DIR/.env
├── JWT_SECRET ───────────┬──► realtime   METRICS_JWT_SECRET   (upstream compose)
│                         └──► supavisor  METRICS_JWT_SECRET   (upstream compose)
│
├── ANON_KEY  (signed with JWT_SECRET)
│     └── generate-metrics-secrets.sh ──► jwt ──► otel-collector
│                                                 credentials_file for both jobs
│
└── POSTGRES_PASSWORD
      └── generate-metrics-secrets.sh ──► .metrics-secrets.env ──► postgres-exporter
                                                                   DATA_SOURCE_NAME
```

Without the token, Supavisor answers `/metrics` with `403`.

Both secrets are read from Supabase's `.env`, not this project's, so when
a key changes, that file is the one place to change it.

## postgres-exporter

Postgres has no metrics endpoint of its own, so this project runs
[`prometheuscommunity/postgres-exporter`](https://github.com/prometheus-community/postgres_exporter)
and scrapes that.

It connects straight to `supabase-db:5432`, not through Supavisor, so the
exporter's own connections don't show up in the connection-pool metrics
it sits next to.

It needs `v0.20.0` or newer. Supabase's Postgres ships a setting,
`supautils.disable_program`, with no description (`short_desc` is `NULL`),
and older exporters abort the whole `pg_settings` collection on it -
which also takes `pg_stat_activity` down with it. Fixed in
[postgres_exporter#1327](https://github.com/prometheus-community/postgres_exporter/pull/1327).
`PG_EXPORTER_DISABLE_SETTINGS_METRICS` was removed in the same release, so
it isn't a workaround on newer versions.

## `resource_detection` is left out

The collector's `resource_detection` processor with the Docker detector
would add host tags like `host.name`. It needs the Docker socket, which a
non-root collector can't read without a per-host group ID, and a failing
detector stops the collector from starting - turning an optional tag into
a single point of failure for every metric. The full reasoning is in
`config/metrics/otel-collector.yaml`.

## The store is one service, filled in by the backend's folder

```
.env   BACKEND_METRICS=victoriametrics
              │
              ▼
docker-compose.o11y-metrics.yml
  metrics-store:
    extends:
      file: config/metrics/backends/${BACKEND_METRICS}/compose.yml
              │
              ▼
config/metrics/backends/victoriametrics/compose.yml
  image, ports, volume, network alias "victoriametrics"
```

The store is always the service `metrics-store`, whichever backend fills
it in. The log pipeline does the same with `logs-store`. Three things
follow from that:

- **It starts with the rest of the stack.** There's no profile to leave
  it out, so `make up-metrics` and `docker compose up -d` start the same
  containers. A `BACKEND_METRICS` with no matching folder stops Compose
  with a "no such file" error.
- **Switching backends replaces it in place.** Compose sees the same
  service with a new definition and recreates it, removing the previous
  store's container.
- **The collector reaches it by the backend's name.** The backend's
  `compose.yml` gives the container a network alias equal to the folder
  name, and the exporter's endpoint uses that host.

Two rules for a backend's `compose.yml` come from how `extends` works:
relative paths resolve from the backend's own folder, and named volumes
must be declared in `docker-compose.o11y-metrics.yml`, because `extends`
copies the service but not the top-level volume declarations.