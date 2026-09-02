# Logs

Vector collects container logs from your Supabase services and ships them to
either VictoriaLogs (default) or Loki.

```
Supabase containers ──> Vector ──> VictoriaLogs  (default, has a UI)
                                └─> Loki         (query over HTTP, or Grafana)
```

## Configure

In `.env`:

| Variable | Values | Default |
| --- | --- | --- |
| `SUPABASE_DIR` | Absolute path to your Supabase `docker/` directory | required, see [README.md](README.md) |
| `BACKEND_LOGS` | `victorialogs` or `loki` | `victorialogs` |
| `LOGS_RETENTION_PERIOD` | e.g. `30d` | `30d` |

## Start

```bash
make up-logs
```

Without `make`:

```bash
docker compose -f docker-compose.o11y-logs.yml up -d
```

This binds two ports on localhost only: `9428` for VictoriaLogs, or `3100`
for Loki, depending on `BACKEND_LOGS`.

## Confirm it works

```bash
make verify-logs
```

Without `make`: `scripts/verify-logs.sh`

This checks that every routed service (one the pipeline has a rule for -
see [What gets collected](#what-gets-collected)) is actually reaching the
store. It raises log levels on the quiet-by-default services, generates
traffic, checks the store, then puts the levels back:

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

Two things to know about this check:

- It **restarts your `rest` and `db` containers** to raise their levels, then
  restarts them again to put them back. It prompts before doing so. If you
  had levels applied deliberately with `scripts/set-log-levels.sh`, re-apply
  them afterwards.
- A `✓` means that service reached the store, not that its parsers produced
  fields. A service emitting only unparsed lines still passes. To check
  fields, use the queries in [log-fields.md](log-fields.md).

If a service is missing, the script prints the query it used so you can dig
into that one service. Start with [log-levels.md](log-levels.md) if the
service is silent, or [log-fields.md](log-fields.md) if it is logging but
your query doesn't match it.

## Switching backends

```bash
# in .env:
BACKEND_LOGS=victorialogs   # or: loki

make down-logs
make up-logs
```

Run `make` on its own to list every target.

## Stopping and removing

```bash
make down-logs
```

`docker compose down` on its own only tears down the profile that is
currently active, so a store started under a different `BACKEND_LOGS` would
be left running. `make down-logs` passes `--profile "*"` to catch both.

| Goal | Command |
| --- | --- |
| Stop, keep stored logs | `make down-logs` |
| Stop and delete stored logs | `docker compose -f docker-compose.o11y-logs.yml --profile "*" down -v` |
| Put Supabase's log levels back | `scripts/set-log-levels.sh reset` |

The third one matters if you raised any levels. Stopping this stack does not
revert changes made to your Supabase containers.

## What gets collected

Vector reads the Docker socket, so it sees every container on the host, then
routes by container name. Only the services listed below have a route;
containers with no matching route - including any not in this table - are
read and discarded by Vector, never reaching the log store.

| Container | Collected | Note |
| --- | --- | --- |
| `supabase-envoy` | Yes | Gateway, in upstream's base compose |
| `supabase-kong` | Yes | Gateway, when the Kong override is layered on |
| `supabase-auth` | Yes | |
| `supabase-rest` | Yes | |
| `realtime-dev.supabase-realtime` | Yes | |
| `supabase-storage` | Yes | |
| `supabase-edge-functions` | Yes | |
| `supabase-db` | Yes | |
| `supabase-pooler` | Yes | Not routed in upstream's Vector config - added here for full coverage |
| `supabase-meta`, `supabase-studio`, `supabase-imgproxy` | No | Not among the services Supabase Cloud's own Logs Explorer surfaces, so this pipeline mirrors that and skips them too |
| `supabase-observability-*` | No | Vector excludes itself and its own stack from what it collects |

The container name becomes the `appname` field in VictoriaLogs (`service`
in Loki - see [If you're using Loki](#if-youre-using-loki)), which is what
you filter on at query time:

```
appname:"supabase-auth" AND _time:15m
```

**A missing service is usually a name mismatch.** Routing matches the
container name exactly, so a service renamed in your Supabase compose file
won't be collected, and won't produce an error either. Compare your running
container names against the table above:

```bash
docker ps --format '{{.Names}}'
```

## Gateway routing

Kong and Envoy write the same access-log format (nginx combined) - Envoy's
access logs parse with the same `parse_nginx_log(.., "combined")` logic
`kong_logs` uses. This pipeline still routes them separately, because Envoy
also writes a second format on the same stdout stream - its own internal
engine log - that Kong doesn't have, and that `kong_err`'s abort-on-parse-
failure would otherwise drop.

| Gateway | Route | Parsers | Formats handled |
| --- | --- | --- | --- |
| Envoy | `router.envoy` | `envoy_access_logs`, `envoy_engine_logs` | nginx combined + Envoy's own engine format |
| Kong | `router.kong` | `kong_logs`, `kong_err` | nginx combined + nginx error |

Upstream's base `docker-compose.yml` ships Envoy as of self-hosted v0.8.0
([supabase/supabase#48153](https://github.com/supabase/supabase/pull/48153)).
Kong is still supported as an opt-in override. Both are routed here and the
gateway is detected at runtime, so nothing in this repo changes when you
switch.

## Switching gateway

```bash
cd "$SUPABASE_DIR"
sh run.sh config                    # show which overrides are active
sh run.sh stop                      # stop first
sh run.sh config add kong           # or: sh run.sh config remove kong
sh run.sh start
docker port supabase-kong           # or supabase-envoy
```

**Stop before changing `COMPOSE_FILE`.** Editing it first leaves the old
gateway container running as an orphan, because Compose no longer recognises
it as part of the project. That orphan keeps port 8000 bound, so the new
gateway fails to start:

```
Bind for 0.0.0.0:8000 failed: port is already allocated
```

Recover with `docker rm -f supabase-envoy` (or `supabase-kong`), then
`sh run.sh start`.

The last command in the block above is not optional. A gateway that failed to
bind once can be started again *without* its port binding, and its health
check will still report healthy. Empty output from `docker port` means the
gateway is unreachable - see
[log-troubleshooting.md](log-troubleshooting.md#everything-looks-healthy-but-nothing-responds).

Two things you will see after switching, both expected:

- Vector logs two errors as the old gateway container disappears
  (`can not get logs from container which is dead or marked for removal`,
  then `No such container`).
- The new gateway's full startup history arrives at once, because
  `docker_logs` reads a new container's log file from the beginning.

If you had a gateway log level applied, reset it before switching. Each
gateway reads its own variable - `SUPABASE_ENVOY_LOG_LEVEL` does nothing
once Kong is running, and `SUPABASE_KONG_LOG_LEVEL` does nothing under
Envoy:

```bash
scripts/set-log-levels.sh reset
```

## Querying (VictoriaLogs)

VictoriaLogs ships a UI at `http://localhost:9428/select/vmui/`.

Queries use LogSQL:

| Query | Finds |
| --- | --- |
| `appname:"supabase-auth"` | One service |
| `_time:15m` | Last 15 minutes |
| `appname:"supabase-db" AND _time:1h` | Combined |
| `severity:"error" AND _time:15m` | Errors across every service |
| `_time:[2026-08-08T14:00:00Z, now]` | An absolute window |

Always include a time filter. Without one the query scans everything still
inside the retention window.

`severity` is a normalized field this pipeline adds on top of each service's
own severity field, so one query spans all services. See
[log-fields.md](log-fields.md) for what each service carries natively.

The same queries work over HTTP:

```bash
curl -s http://localhost:9428/select/logsql/query \
  --data-urlencode 'query=appname:"supabase-db" AND _time:15m' \
  | jq -r '._msg'
```

`_msg` is the stored message field. See
[log-fields.md](log-fields.md#_msg-vs-event_message) if you were expecting
`event_message`.

LogSQL supports pipes for sorting, counting, and limiting. Count with the
store's own aggregation rather than piping to `wc -l`, which counts NDJSON
framing lines instead of events:

```bash
curl -s http://localhost:9428/select/logsql/query \
  --data-urlencode 'query=appname:"supabase-db" AND _time:15m | count()'
```

```bash
curl -s http://localhost:9428/select/logsql/query \
  --data-urlencode 'query=_time:1h | stats by (appname) count() as total'
```

Quoting a value for an exact match tokenizes on `_` - a marker like
`"batch_47_"` won't match a stored `batch_47_1`, even though the full
string is there:

```bash
# Matches nothing, even though the value exists
curl -s http://localhost:9428/select/logsql/query \
  --data-urlencode 'query=appname:"supabase-envoy" AND "batch_47_" | stats count() as total'

# Matches
curl -s http://localhost:9428/select/logsql/query \
  --data-urlencode 'query=appname:"supabase-envoy" AND batch_47_1 | stats count() as total'
```

Search the exact value, or drop the quotes and rely on the implicit
substring match instead of phrase quoting.

See the
[LogsQL reference](https://docs.victoriametrics.com/victorialogs/logsql/)
for the full syntax.

## Known upstream defaults that suppress logs

Some Supabase services ship with logging turned down, so they look silent
even under normal traffic.

| Service | Setting | Default | Effect |
| --- | --- | --- | --- |
| PostgREST (`rest`) | `PGRST_LOG_LEVEL` | `error` | Only 5xx is logged. 4xx (auth failures, bad requests) produce no line |
| Postgres (`db`) | `log_min_messages` via compose `command:` | `fatal` | Almost everything below FATAL is suppressed, including query errors |
| Postgres (`db`) | `log_statement` | `ddl` | Set to log DDL, but emitted at LOG level - `log_min_messages=fatal` suppresses it. Schema changes aren't logged until you raise the level |

To raise them, in `.env`:

```
SUPABASE_REST_LOG_LEVEL=info
SUPABASE_DB_LOG_LEVEL=warning
```

Then apply:

```bash
scripts/set-log-levels.sh apply
```

`scripts/set-log-levels.sh status` shows current levels against `.env`. See
[log-levels.md](log-levels.md) for every service, its allowed values, and
which ones are case-sensitive.

Turn it back off once you're done - `scripts/set-log-levels.sh reset`
restores upstream defaults. See
[Security considerations](#security-considerations) below for why.

## If you're using Loki

Loki has no UI of its own. Query over HTTP, or point an existing Grafana at
it.

```bash
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={service=~".+"}' \
  --data-urlencode "start=$(date -u -d '10 minutes ago' +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000" \
  | jq '.data.result[].stream'
```

The same service is labelled differently in each store. Loki calls it
`service`; VictoriaLogs calls it `appname`. The value is identical, so
filters translate directly - just swap the key:

| Store | Filter |
| --- | --- |
| Loki | `{service="supabase-auth"}` |
| VictoriaLogs | `appname:"supabase-auth"` |

Field names inside the event differ too - see
[log-fields.md](log-fields.md#how-fields-are-stored).

Vector's startup healthcheck against Loki can fail if Vector comes up first.
This is a startup ordering artifact, not a data problem; Vector retries and
logs flow normally once Loki is ready.

If a query comes back empty, see
[log-troubleshooting.md](log-troubleshooting.md#a-query-returns-nothing-but-the-logs-should-be-there).

## Connecting Grafana

If you already run Grafana, point it at either store instead of using VMUI or
curl.

| Store | Setup |
| --- | --- |
| Loki | Built-in Grafana data source. Add the Loki container's URL as reachable from Grafana, query with LogQL |
| VictoriaLogs | Needs its own data source plugin installed in Grafana. Not verified against this stack yet |

This repo does not ship a Grafana container. Dashboards are planned; for the
log signal on its own, VMUI covers the same ground without the extra service.

## Security considerations

**Raising a log level can put credentials in the store.**

| Service | At `debug` |
| --- | --- |
| Auth (GoTrue) | Logs the full OAuth exchange code |
| Realtime | Logs the tenant JWT secret in plaintext |

**Postgres error logs include the statement that failed.** With
`SUPABASE_DB_LOG_LEVEL` at `warning` or lower, an error is followed by a
`STATEMENT:` line carrying the original query with its literal values:

```
ERROR:  relation "nonexistent_table" does not exist at character 15
STATEMENT:  SELECT * FROM nonexistent_table WHERE email = 'secret@example.com';
```

This is Postgres'
[`log_min_error_statement`](https://www.postgresql.org/docs/current/runtime-config-logging.html#GUC-LOG-MIN-ERROR-STATEMENT),
which Supabase leaves at its default of `error` - a separate setting from
the one below, controlling only whether *failed* queries get a `STATEMENT:`
line.

**Schema changes (`CREATE`/`ALTER`/`DROP`) are not logged by default,
despite `log_statement=ddl` being set** (see
[Known upstream defaults that suppress logs](#known-upstream-defaults-that-suppress-logs)
for why). If you rely on Postgres logs for a DDL audit trail, set
`SUPABASE_DB_LOG_LEVEL=warning` in `.env` and run
`scripts/set-log-levels.sh apply` - `warning` is the recommended level to
turn this on without pulling in unrelated noise. Don't assume the default
gives you an audit trail: check the store, not just the setting.

**Turning a level back down leaves earlier logs in place.**
`scripts/set-log-levels.sh reset` restores the service, and anything already
collected stays until it ages out of `LOGS_RETENTION_PERIOD` (30 days by
default). Neither store offers a lightweight way to delete specific entries
early. If sensitive data needs to come out sooner, lowering
`LOGS_RETENTION_PERIOD` and letting the store roll forward is the practical
option.

**Vector reads the Docker socket.** It mounts `/var/run/docker.sock`
read-only, which is how it collects container logs. This grants visibility
into every container on the host, so treat the Vector container as trusted.

## Platform notes

- Shell examples in these docs use GNU coreutils syntax (Linux default).
  On macOS, `date -u -d '...'` in particular needs a BSD equivalent.
- `scripts/verify-logs.sh` and `scripts/set-log-levels.sh` need bash 4 or
  newer (`declare -A`, `mapfile`). macOS ships bash 3.2.
