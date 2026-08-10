# Log field reference

Every field the pipeline puts on an event, which service produces it, and
how to query it. Use this when a query returns nothing you expected.

Queries are LogSQL, for the VictoriaLogs UI at
`http://localhost:9428/select/vmui/` or over HTTP - see
[logs.md](logs.md#querying-victorialogs). Loki differences are noted where
they apply.

## Fields on every event

Set in `project_logs`, before any service-specific parsing:

| Field | What it is | Example |
| --- | --- | --- |
| `appname` | Container name. The routing key, and what you filter a single service on | `supabase-auth` |
| `_msg` | The log line, see [below](#_msg-vs-event_message) | `Schema cache loaded` |
| `_time` | The field the store indexes on, see [below](#_time-and-metadatatimestamp) | `2026-08-10T12:32:44Z` |
| `severity` | Normalized level, added at the end of the pipeline, see [below](#severity) | `warn` |
| `project` | Always `default` self-hosted. Kept for shape compatibility with upstream Supabase's own pipeline | `default` |

`project` does not stay at the top level everywhere. Four services move it,
so a query on `project` will not match them:

| Where `project` ends up | Services |
| --- | --- |
| `project` (top level) | Envoy, Kong, Auth, REST, Postgres |
| `metadata.project` | Realtime, Storage, Supavisor |
| `metadata.project_ref` | Edge Functions |

Filter on `appname` rather than `project` unless you specifically need this.

## How fields are stored

VictoriaLogs stores every value as text, whatever type it had in the log
line. A result shows `"metadata.response.status_code": "404"` even though
the parser produced the number 404. This does not change how you query it -
`metadata.response.status_code:404` matches - but it is why the Type column
in the tables below describes the log line, not the stored value.

Nested structures are not stored the same way as each other:

| In the log line | In the store | Query it as |
| --- | --- | --- |
| Nested object | Flattened to dotted keys | `metadata.req.method:"GET"` |
| Array | One JSON string | Substring match on the whole thing |
| Header name containing `-` | `-` becomes `_` | `metadata.req.headers.user_agent` |

So Storage's `metadata.context` holds `[{"host":"890eeb65a0d8","pid":1}]`
as text. There is no `metadata.context[0].host` to filter on. Match inside
it instead:

```
appname:"supabase-storage" AND metadata.context:"890eeb65a0d8"
```

On Loki the whole event is one JSON blob, so unwrap it first and use
underscores throughout:

```
{service="supabase-envoy"} | json | metadata_request_path="/rest/v1/orders"
```

If you are unsure what a field is actually called, ask the store rather
than guessing. Widen the time window if the result is empty - an idle stack
produces nothing, which is not the same as a missing field:

```bash
curl -s http://localhost:9428/select/logsql/query \
  --data-urlencode 'query=appname:"supabase-storage" AND _time:24h | limit 1' | jq .
```

To list every field a service currently produces:

```bash
curl -s http://localhost:9428/select/logsql/query \
  --data-urlencode 'query=appname:"supabase-auth" AND _time:24h | limit 10' \
  | jq -s 'map(keys) | flatten | unique'
```

## `.severity`

`SUPABASE_*_LOG_LEVEL` and `.severity` sound similar but act at different
points:

| | What it does | When |
| --- | --- | --- |
| `SUPABASE_*_LOG_LEVEL` | Decides whether the service writes a line at all | Before the line exists. Set in `.env`, see [log-levels.md](log-levels.md) |
| `.severity` | Labels a line that was already written, so you can filter on it | After the line reaches the store. Added by this pipeline |

Raising a service's log level makes it write more lines. It does not change
the `.severity` those lines get, which depends on whether the service
prints a severity marker at all. Some do not, and always land as `info`.

Every event carries `.severity`, one of `debug | info | warn | error |
fatal`. This is what cross-service queries filter on:

```
severity:"error" AND _time:15m
```

Each service also keeps its own native field. `.severity` does not replace
those, it adds one consistent field on top:

| Service | Native field | Type in the line | Maps to |
| --- | --- | --- | --- |
| Envoy access | `metadata.response.status_code` | number | `>=500` error, `>=400` warn, else info |
| Kong access | `metadata.response.status_code` | number | same |
| Envoy engine | `metadata.level` | string | `warning` to `warn`, `critical` to `fatal` |
| Auth | `metadata.level` | string | direct |
| Realtime | `metadata.level` | string | direct |
| Supavisor | `metadata.level` | string | direct |
| Storage | `metadata.level` | number (Pino) | see table below |
| Postgres | `metadata.parsed.error_severity` | uppercase string | `ERROR` to `error`, `PANIC` to `fatal` |
| Kong error | `severity` | string | direct, and overwritten in place |
| REST | none | | always `info` |
| Edge Functions | none | | always `info` |

Kong's error transform writes its own `.severity` first, and the
normalizing step then rewrites that same field. What reaches the store is
the normalized value. nginx's `notice` becomes `info`, since the normalized
set has no `notice`.

Storage uses [Pino](https://getpino.io/), a Node.js logging library that
writes severity as a number:

| `metadata.level` | `.severity` |
| --- | --- |
| 20 or below | `debug` |
| 21 to 30 | `info` |
| 31 to 40 | `warn` |
| 41 to 50 | `error` |
| above 50 | `fatal` |

So `severity:"error"` finds Storage errors without having to remember that
`metadata.level:50` means error.

## `_time` and `metadata.timestamp`

`_time` is the field the store indexes on, and the one a time filter reads.
Where its value comes from differs by service:

| `_time` source | Services |
| --- | --- |
| Parsed from the log line | Envoy access, Envoy engine, Kong access, Kong error, REST |
| Docker's collection time, line's own time kept on `metadata.timestamp` | Auth, Storage |
| Docker's collection time | Realtime, Edge Functions, Postgres, Supavisor |

The two rarely differ by more than the time it takes Vector to read the
line. If cross-service ordering looks wrong, check which row a service is
in first.

Both services that carry `metadata.timestamp` write it as an RFC 3339
string, so they are directly comparable:

| Service | `metadata.timestamp` |
| --- | --- |
| Auth | `2026-08-04T11:45:43Z` |
| Storage | `2026-08-10T08:22:25.708Z` |

Postgres keeps a copy of the ingest time on `metadata.parsed.timestamp` as
well, matching upstream Supabase's own field layout.

## `_msg` vs `event_message`

Query VictoriaLogs on `_msg`. `event_message` is Vector's internal name;
the VictoriaLogs sink maps it to `_msg` through `_msg_field` in
`backends/vector/victorialogs.yaml`.

```
appname:"supabase-db" AND _msg:"division by zero"
```

Filtering on `event_message` against VictoriaLogs returns nothing, and
raises no error either.

**Loki keeps the original name.** Its sink has no `_msg_field` mapping and
stores each event as JSON as-is, so the message stays on `event_message`:

```
{service="supabase-db"} | json | event_message=~".*division by zero.*"
```

## Fields by service

### Envoy access logs (`supabase-envoy`)

nginx combined format. Kong access lines carry the same set.

| Field | Type in the line | Example |
| --- | --- | --- |
| `metadata.request.method` | string | `GET` |
| `metadata.request.path` | string | `/rest/v1/orders` |
| `metadata.request.protocol` | string | `HTTP/1.1` |
| `metadata.response.status_code` | number | `401` |
| `metadata.request.headers.user_agent` | string | `curl/8.18.0` |
| `metadata.request.headers.referer` | string | `-` |
| `metadata.request.headers.cf_connecting_ip` | string | `172.19.0.1` |

```
appname:"supabase-envoy" AND metadata.response.status_code:401
appname:"supabase-envoy" AND metadata.request.path:"/rest/v1/orders"
appname:"supabase-envoy" AND metadata.request.method:"POST" AND _time:1h
```

The `cf_connecting_ip` name comes from upstream Supabase's own field
layout, where Cloudflare sits in front of the gateway. Self-hosted there is
no Cloudflare, so this holds whatever address nginx saw as the client,
usually a Docker bridge address.

### Envoy engine logs (`supabase-envoy`)

Envoy's own internal-event format, on the same stdout stream as the access
logs above.

| Field | Type in the line | Example |
| --- | --- | --- |
| `metadata.level` | string | `warning` |
| `metadata.component` | string | `upstream` |

Components Envoy emits, by how much they talk:

| Component | What it covers |
| --- | --- |
| `main` | Server lifecycle - startup, shutdown, worker threads |
| `misc` | Uncategorized, mostly deprecated-field warnings at boot |
| `lua` | The Lua filters in Supabase's Envoy config |
| `config` | Config load and xDS |
| `upstream` | Backend cluster health and connections |
| `runtime` | Runtime feature flags |
| `admin` | The admin interface |

`main` and `misc` dominate the volume, and most of both arrives during
startup. Filter to what you need:

```
appname:"supabase-envoy" AND metadata.component:"upstream" AND _time:1h
appname:"supabase-envoy" AND metadata.level:"warning" AND _time:1h
```

Engine lines carry no `metadata.request.*`, and access lines carry no
`metadata.component`, so either field also separates the two:

```
appname:"supabase-envoy" AND metadata.component:*        # engine only
appname:"supabase-envoy" AND metadata.request.method:*   # access only
```

Upstream's `vector.yml` routes Envoy's access logs through the shared
Kong transforms, since Envoy's access log is formatted to match nginx
combined. The engine parser and this field set are specific to this
project.

### Kong (`supabase-kong`)

Only present if you run Kong as your gateway. Kong writes two nginx formats
to one stream, and they carry different fields.

**Access lines** (nginx combined), identical to Envoy access above:

| Field | Type in the line | Example |
| --- | --- | --- |
| `metadata.request.method` | string | `GET` |
| `metadata.request.path` | string | `/rest/v1/nonexistent` |
| `metadata.request.protocol` | string | `HTTP/1.1` |
| `metadata.response.status_code` | number | `404` |
| `metadata.request.headers.user_agent` | string | `curl/8.18.0` |
| `metadata.request.headers.referer` | string | `-` |
| `metadata.request.headers.cf_connecting_ip` | string | `172.19.0.1` |

```
appname:"supabase-kong" AND metadata.response.status_code:404
appname:"supabase-kong" AND metadata.request.path:"/rest/v1/orders"
```

**Error lines** (nginx error). This format carries no status code, so there
is no `metadata.response.status_code` on them. Filter on `severity`:

| Field | Type in the line | Example |
| --- | --- | --- |
| `severity` | string | `warn` |
| `metadata.request.host` | string | `localhost` |
| `metadata.request.method` | string | `GET` |
| `metadata.request.path` | string | `/` |
| `metadata.request.protocol` | string | `HTTP/1.1` |
| `metadata.request.headers.cf_connecting_ip` | string | `unix:` |

Not every error line has a request block. Startup warnings have none and
reach the store with `severity` alone:

```
2026/08/10 11:59:19 [warn] 1#0: the "user" directive makes sense only if ...
```

`metadata.request.host` appears on error lines and not on access lines, so
it separates the two:

```
appname:"supabase-kong" AND metadata.request.host:*             # error only
appname:"supabase-kong" AND metadata.response.status_code:*     # access only
```

`KONG_LOG_LEVEL` controls the error log only. Access lines are written
regardless of its value - see [log-levels.md](log-levels.md).

Most of Kong's volume is startup noise on the error stream. In one observed
run, 167 lines produced 3 access lines and 158 parsed error lines.

### Auth (`supabase-auth`)

GoTrue writes structured JSON, and the whole payload is merged into
`metadata`, so the key set depends on what the line is about. Auth keeps
`project` at the top level rather than moving it under `metadata`.

Always present:

| Field | Type in the line | Example |
| --- | --- | --- |
| `metadata.level` | string | `info` |
| `metadata.timestamp` | RFC 3339 string | `2026-08-04T11:45:43Z` |
| `metadata.component` | string | `api` |

On request lines:

| Field | Example |
| --- | --- |
| `metadata.method` | `POST` |
| `metadata.path` | `/token` |
| `metadata.status` | `400` |
| `metadata.duration` | `12.4` |
| `metadata.request_id` | `9f2c...` |
| `metadata.remote_addr` | `172.19.0.5` |
| `metadata.referer` | `http://localhost:3000/` |
| `metadata.x_forwarded_host` | `localhost:8000` |
| `metadata.x_forwarded_proto` | `http` |

On failures, and on sign-in specifically:

| Field | Example |
| --- | --- |
| `metadata.error_code` | `invalid_credentials` |
| `metadata.error` | error text |
| `metadata.grant_type` | `password` |

```
appname:"supabase-auth" AND metadata.error_code:"invalid_credentials"
appname:"supabase-auth" AND metadata.path:"/token" AND metadata.status:400
appname:"supabase-auth" AND severity:"error" AND _time:15m
```

`metadata.error_code` is the field to reach for on a failed sign-in. See
[log-troubleshooting.md](log-troubleshooting.md#sign-in-fails-with-no-useful-detail).

`metadata.args` appears on lines where GoTrue formats a message from a
template, holding the substituted values. The rendered text is already in
`_msg`, so this is rarely what you want to filter on.

The merge is unconditional, so a line type not listed above still reaches
the store with all of its own keys.

### REST (`supabase-rest`)

PostgREST writes two formats. Lifecycle lines are parsed for their
timestamp; HTTP access lines pass through unparsed, keeping the full line
on `_msg`.

| Field | Type in the line | Example |
| --- | --- | --- |
| `metadata.host` | string | Always `default`. It mirrors `project` rather than a real hostname, matching upstream's field layout |

REST prints no severity marker, so every REST line lands as
`severity:"info"` regardless of what it says. Filter by `appname` and
search the message:

```
appname:"supabase-rest" AND _msg:"Connection refused"
appname:"supabase-rest" AND _time:15m
```

REST is also quiet by default (`PGRST_LOG_LEVEL=error`), so 4xx responses
produce no line at all. See [log-levels.md](log-levels.md).

### Realtime (`realtime-dev.supabase-realtime`)

Realtime writes an optional run of `key=value` pairs between the timestamp
and the level tag. Which keys appear varies per line, and each becomes a
`metadata.*` field.

| Field | Type in the line | Example |
| --- | --- | --- |
| `metadata.level` | string | `info` |
| `metadata.project` | string | `default` |
| `metadata.request_id` | string | `GMpj_j-1ZzcE8-IAABnj` |

```
appname:"realtime-dev.supabase-realtime" AND metadata.request_id:"GMpj_j-1ZzcE8-IAABnj"
appname:"realtime-dev.supabase-realtime" AND severity:"error" AND _time:15m
```

Realtime's own `project=` key is dropped during parsing. It carries the
tenant name, and keeping it would overwrite the shared `default` value
every other service uses.

**Not every line has `metadata.level`.** Realtime's entrypoint script emits
shell trace output at startup, which is not in the
`timestamp [level] message` shape and therefore does not parse:

```
+ '[' true = true ']'
```

Those events still reach the store with the full line on `_msg`, they just
carry no parsed fields. A query on `metadata.level:*` will not match them.

Health check traffic is filtered before this transform. Realtime probes
with `GET /` rather than `/health`, and Phoenix logs each request as two
lines - the request carrying the path, and the response carrying only the
status. The filter drops probe requests by path and 2xx/3xx responses by
status, so 4xx and 5xx responses stay visible. One consequence: for a
successful non-probe request, the request line is stored and its response
line is not, so the status code of a successful request is not in the
store. See
[log-pipeline-internals.md](log-pipeline-internals.md#health-check-filtering).

### Storage (`supabase-storage`)

Pino JSON. The entire payload is merged into `metadata`, so a request line
carries a large field set.

Always present:

| Field | Type in the line | Example |
| --- | --- | --- |
| `metadata.level` | number | `30` |
| `metadata.timestamp` | RFC 3339 string | `2026-08-10T08:22:25.708Z` |
| `metadata.project` | string | `default` |
| `metadata.tenantId` | string | `stub` |
| `metadata.context` | array, stored as JSON text | `[{"host":"890eeb65a0d8","pid":1}]` |

On request lines (`metadata.type:"request"`):

| Field | Example |
| --- | --- |
| `metadata.operation` | `storage.bucket.list` |
| `metadata.role` | `anon` |
| `metadata.reqId` | `req-7nn` |
| `metadata.req.method` | `GET` |
| `metadata.req.url` | `/bucket` |
| `metadata.req.remoteAddress` | `172.19.0.5` |
| `metadata.req.headers.user_agent` | `curl/8.18.0` |
| `metadata.res.statusCode` | `200` |
| `metadata.responseTime` | `22.996628001332283` |
| `metadata.executionTime` | `23` |
| `metadata.appVersion` | `1.60.4` |
| `metadata.region` | `stub` |

```
appname:"supabase-storage" AND metadata.res.statusCode:200
appname:"supabase-storage" AND metadata.operation:"storage.bucket.list"
appname:"supabase-storage" AND metadata.role:"anon" AND _time:1h
```

Storage names its response status `metadata.res.statusCode`. The gateway
uses `metadata.response.status_code` for the same idea, so a query written
for one will not match the other.

Failures add `metadata.error`, which is the object worth reading when an
upload fails:

```
appname:"supabase-storage" AND metadata.error:* AND _time:15m
```

The key holding the error identifier inside that object is `code` on some
paths and `errorCode` on others, depending on where in storage-api it
originated. Read the object whole rather than filtering on one key. See
[log-troubleshooting.md](log-troubleshooting.md#file-upload-fails-with-a-vague-error).

`metadata.tenantId` falls back to `default` on lines that carry no tenant,
such as startup messages, and holds the real tenant on request lines.

Upstream Supabase's own pipeline extracts five fields from these lines and
drops the rest, including `error`. This pipeline merges the whole payload,
which is why everything above is queryable.

### Edge Functions (`supabase-edge-functions`)

edge-runtime writes unstructured text, so there is nothing to parse. This
is the only service where `project` is renamed rather than kept or moved.

| Field | Type in the line | Example |
| --- | --- | --- |
| `metadata.project_ref` | string | `default` |

The whole line stays on `_msg`, and every line lands as `severity:"info"`.
Search the text:

```
appname:"supabase-edge-functions" AND _msg:"error" AND _time:15m
appname:"supabase-edge-functions" AND _time:15m
```

Structured logging for Edge Functions is waiting on upstream work, see
[log-known-limitations.md](log-known-limitations.md).

### Postgres (`supabase-db`)

| Field | Type in the line | Example |
| --- | --- | --- |
| `metadata.parsed.error_severity` | uppercase string | `ERROR` |
| `metadata.parsed.timestamp` | timestamp | ingest time |
| `metadata.host` | string | Always `db-default`. A constant from upstream's field layout, not a real hostname |

```
appname:"supabase-db" AND metadata.parsed.error_severity:"ERROR"
appname:"supabase-db" AND severity:"error" AND _time:15m
appname:"supabase-db" AND _msg:"division by zero"
```

Postgres is quiet by default (`log_min_messages=fatal`), so query errors
produce no line until the level is raised. See
[log-levels.md](log-levels.md).

The severity regex has a known accuracy limit on lines whose query text
contains a word like `ERROR`, and continuation lines (`STATEMENT`,
`DETAIL`, `HINT`, `CONTEXT`) carry no severity of their own and land as
`LOG`. See [log-known-limitations.md](log-known-limitations.md).

### Supavisor (`supabase-pooler`)

Same `key=value` shape as Realtime. Which keys appear depends on the line
type.

On every line:

| Field | Type in the line | Example |
| --- | --- | --- |
| `metadata.level` | string | `error` |
| `metadata.project` | string | `default` |
| `metadata.region` | string | `local` |

On connection lines only:

| Field | Example |
| --- | --- |
| `metadata.user` | `postgres` |
| `metadata.mode` | `session` |
| `metadata.peer_ip` | `172.19.0.3` |
| `metadata.app_name` | `psql` |
| `metadata.type` | `single` |

```
appname:"supabase-pooler" AND severity:"error" AND _time:15m
appname:"supabase-pooler" AND metadata.user:"postgres"
appname:"supabase-pooler" AND metadata.app_name:"psql" AND _time:1h
```

A common failure is `(ENOIDENTIFIER) no tenant identifier provided`, which
means the client connected without a tenant in the username or SNI
hostname. The connection fields above tell you which client it was.

Supavisor has no runtime log level control, but it logs connection failures
at `error` by default, so those are already there without changing
anything. See
[log-troubleshooting.md](log-troubleshooting.md#database-connections-fail-through-the-pooler).

Health check traffic is filtered before this transform, on the same rule as
Realtime. See
[log-pipeline-internals.md](log-pipeline-internals.md#health-check-filtering).

## Diagnostic fields

Two fields appear only when the pipeline had to substitute a value it could
not use as printed. The event still reaches the store either way, and the
field records what happened.

| Field | Appears when | Holds |
| --- | --- | --- |
| `metadata.timestamp_future` | A timestamp was more than 60 seconds ahead of ingest time and was replaced with the current time | The original timestamp |
| `metadata.timestamp_parse_error` | Envoy's internal timestamp did not match the expected format, so Docker's collection time was used | The unparsed text |

```
metadata.timestamp_future:* AND _time:24h | count()
```

A non-zero count means the host clock is, or was, wrong. See
[log-troubleshooting.md](log-troubleshooting.md#loki-rejects-logs-as-timestamp-too-new).

`metadata.timestamp_parse_error` has not yet been observed against a real
malformed timestamp, so treat it as a route that exists rather than one
with a track record. It is listed in
[log-known-limitations.md](log-known-limitations.md).

## Known gaps

See [log-known-limitations.md](log-known-limitations.md) for the current
list, including where `.severity` is known to be imprecise.
