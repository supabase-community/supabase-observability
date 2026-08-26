# Pipeline internals

Why the log pipeline is shaped the way it is. For setup see
[logs.md](logs.md); for what each field means see
[log-fields.md](log-fields.md); for what's currently broken see
[log-known-limitations.md](log-known-limitations.md); for the tools to work
on it see [log-debugging.md](log-debugging.md).

## Event flow

```
Docker json-log files
        │
        ▼
  docker_host           (source: docker_logs)
        │
        ▼
  project_logs          (strip Docker fields, set .appname)
        │
        ▼
     router              (route: split on .appname)
        │
        ├── kong    ──────────┬── kong_logs           (nginx combined)
        │                     └── kong_err            (nginx error)
        │
        ├── envoy   ──────────┬── envoy_access_logs   (nginx combined)
        │                     └── envoy_engine_logs   (Envoy's own format)
        │
        ├── auth    ──────────── auth_logs            (JSON)
        │
        ├── rest    ──────────── rest_logs            (mixed text / nginx)
        │
        ├── realtime ─────────── realtime_logs_filtered → realtime_logs
        │
        ├── storage ──────────── storage_logs         (Pino JSON)
        │
        ├── functions ────────── functions_logs       (no parsing)
        │
        ├── db      ──────────── db_logs               (severity extraction)
        │
        ├── supavisor ────────── supavisor_logs_filtered → supavisor_logs
        │
        └── _unmatched ───────── (no consumer - dropped)
        │
        ▼
  normalize_severity    (unifies .severity across every branch above)
        │
        ▼
  timestamp_guard       (clamps future timestamps)
        │
        ▼
  loki_all / vlogs      (sink)
```

`router._unmatched` has no consumer, so Vector warns on startup. This is
expected: studio, meta, imgproxy and anything else unrouted lands there.
**"Dropped" here means the event is discarded and never reaches a store -
that is the meaning throughout this document.**

## `docker_logs` startup behavior

`docker_logs` does **not** replay a container's log history on Vector
restart. Vector computes `since` from its own process start time
(`now_timestamp`, set once when the `docker_logs` source starts), not from
the container's `Created` time - see
[`src/sources/docker_logs/mod.rs#L388-L405`](https://github.com/vectordotdev/vector/blob/v0.56.0/src/sources/docker_logs/mod.rs#L388-L405)
in Vector's own source if you want to check this against a different
pinned version.

| Event | Result |
| --- | --- |
| Vector restarts | No replay - only new events from the restart point onward. Anything logged while Vector was down is permanently lost |
| `docker restart <service>` | Vector was already watching, resumes tailing the same file, no gap |
| Container recreated | New json-log file. Vector discovers the new container and captures its output from creation onward - nothing is lost, since the file has no earlier history to miss |
| `docker compose up -d` after a config change | Container recreate, same as above |

Recreating a container also produces two errors in Vector's log as the old
container disappears mid-stream. They are harmless:

```
Error in communication with Docker daemon. error=... 409 ...
  "can not get logs from container which is dead or marked for removal"
Failed to fetch container metadata. error=... 404 "No such container: ..."
```

**The practical consequence: any Vector downtime is a permanent ingestion
gap.** A deploy, a crash, or `make restart-vector` all lose whatever every
routed container logged during that window - the lines are still on disk
(`docker logs <service>` will show them) but no Vector restart will ever
collect them retroactively.

**Separately:** a host clock that jumps forward while a container is
writing bakes a future timestamp permanently into that container's log
file. This is not a frequent occurrence on a normal Linux server - it
mainly shows up on first boot before NTP has synced (RTC-less SBCs) or
after restoring a VM snapshot. Since there is no replay, a bad timestamp
written once is a one-time event for the store, not a recurring one -
`timestamp_guard` (below) clamps it at ingestion. `docker restart` does
not clean the underlying file, since it appends to the same one; the
container needs to be recreated. Full recovery steps:
[log-troubleshooting.md](log-troubleshooting.md#loki-rejects-logs-as-timestamp-too-new).

## `project_logs` preprocessing

Every event passes through here first. It is a straight field cleanup, not
a parser - no service-specific structure is extracted yet, that happens
downstream per service.

Before (raw from `docker_logs`):

```json
{"message": "...", "container_name": "supabase-auth", "container_id": "a1b2...", "source_type": "docker", "stream": "stdout", "timestamp": "2026-08-08T14:55:06Z"}
```

After `project_logs`:

```json
{"event_message": "...", "appname": "supabase-auth", "project": "default", "timestamp": "2026-08-08T14:55:06Z"}
```

```
.project        = "default"
.event_message  = del(.message)          Docker message -> event_message
.appname        = del(.container_name)   routing key
del(.container_created_at, .container_id, .source_type,
    .stream, .label, .image, .host)
```

This shape matches upstream Supabase's own convention, which is why it
follows this exact field naming rather than something this pipeline
invented.

| Field | Consequence |
| --- | --- |
| `.appname` | The routing key every `router` condition reads |
| `.stream` | Deleted here, so stdout/stderr is indistinguishable downstream |
| `.timestamp` | Untouched at this point - a per-service transform may overwrite it later |

## Failure behavior: abort vs graceful

Does a failed parse **drop** the event (discard it - it never reaches a
store) or pass it through **unparsed** (still stored, just without the
structured fields that transform would have added)? First table to check
when a log is not showing up.

| Transform | On parse failure |
| --- | --- |
| `kong_logs`, `kong_err` | **Drops it** |
| `envoy_access_logs`, `envoy_engine_logs` | **Drops it** |
| `auth_logs`, `rest_logs`, `realtime_logs`, `storage_logs`, `supavisor_logs`, `db_logs` | Passes through unparsed |
| `functions_logs` | No parsing attempted, always passes through |
| `timestamp_guard` | Never blocks - an unparseable `.timestamp` just skips the clamp check |

Kong and Envoy's drop-on-failure is deliberate, inherited from upstream's
own reasoning (their comment: `# Ignores non nginx errors since they are
related with kong booting up`). For Kong this costs little, since it only
emits non-nginx noise briefly at boot. Envoy is different: it keeps
emitting its own internal-event format for its entire life, which is
exactly why it is split into two transforms instead of one - without the
split, all of Envoy's internal logs would be silently dropped. See
[Kong and Envoy each split into two transforms](#kong-and-envoy-each-split-into-two-transforms)
below.

The "passes through unparsed" row is worth reading carefully. Those events
reach the store, but without the fields their transform would have added,
so a query on those fields will not find them. Realtime's startup shell
trace is the clearest example - see
[log-fields.md](log-fields.md#realtime-realtime-devsupabase-realtime).

### Two spots where an edit could turn "unparsed" into "dropped"

**`db_logs` ends on a bang function:**

```
.metadata.parsed.error_severity = upcase!(.metadata.parsed.error_severity)
```

The logic above it always produces a string first, so this does not fail
today. But it is fragile - editing that logic without also checking this
line can turn it into a silent drop point.

**Filter transforms use `string!`:**

```
!contains(string!(.event_message), "/health")
```

If `.event_message` were not a string, this condition would fail to
evaluate and the event would drop. Everything passing through
`project_logs` is already a string, so this is safe today, but a filter's
drop does not show up clearly in Vector's own logs if that ever changes.

## What this pipeline changes from upstream

Supabase's own self-hosted stack ships a Vector config
(`volumes/logs/vector.yml`) that feeds Logflare. This pipeline reuses its
routing and transform shape, so most of what follows is upstream's design
rather than this project's. The differences:

> Checked against `supabase/supabase`'s `docker/volumes/logs/vector.yml`
> on `master` (verified 2026-08-16). Re-check this table if upstream has
> touched that file since - the gateway routing in particular changed
> shape once already when Envoy became the default.

| Area | Upstream | Here | Why |
| --- | --- | --- | --- |
| Envoy engine logs | Access logs routed through `kong_logs`/`kong_err`; engine-log format unhandled and dropped | [Separate transform added](#kong-and-envoy-each-split-into-two-transforms) | Engine format isn't nginx-shaped, so `kong_err`'s abort-on-failure drops it under upstream's routing |
| Supavisor | Not present | Route added (see [Event flow](#event-flow)) | Self-hosted only; Cloud uses a different pooler |
| REST timestamp | Greedy `.*` | [Non-greedy `.*?`](#rests-colon-problem) | A message containing a second `": "` fails the parse and the event is lost |
| Storage payload | 5 fields extracted | [Whole payload merged](#storage-keeps-its-whole-payload) | Upstream's version does not merge the `error` object, which carries the detail needed when a request fails |
| Realtime metadata | No handling for `key=value` pairs; expects `time [level] msg` immediately | [`(?:\S+=\S+ )*` plus `parse_key_value`](#realtime-and-supavisors-variable-metadata) | Real lines carry a variable run of `key=value` pairs upstream's regex doesn't expect |
| Postgres severity list | No `DEBUG` | `DEBUG` added | Postgres prints plain `DEBUG`, so those lines were landing as `LOG` |
| Severity | Four different shapes across services | One normalized `.severity` on top | A single query could not span services |
| Future timestamps | Not handled | Clamped by `timestamp_guard` | See [startup behavior](#docker_logs-startup-behavior) |
| Realtime health check filter | Matches literal `/health` in the request line; this deployment's actual probes hit `GET /`, so the match never fires | [Matches the actual observed probe path, plus catches response lines by status](#health-check-filtering) | Upstream's filter exists but doesn't match this deployment's real traffic |
| Supavisor health check filter | No route, so no filter | [Filtered by path and status](#health-check-filtering) | Self-hosted only, not in upstream's routing at all |

Each service's own upstream-shaped fields are left untouched; the
normalized `.severity` is added alongside rather than replacing them.

## Kong and Envoy each split into two transforms

Both gateways write more than one log format to the same stdout stream, so
each needs two transforms reading from the same route:

| Gateway | Route | Splits into | Each one handles |
| --- | --- | --- | --- |
| Kong | `router.kong` | `kong_logs`, `kong_err` | nginx access format, nginx error format |
| Envoy | `router.envoy` | `envoy_access_logs`, `envoy_engine_logs` | nginx access format, Envoy's own internal-event format |

### The two formats, as each service actually writes them

```
Envoy access:  172.19.0.1 - - [04/Aug/2026:01:26:50 +0000] "GET /rest/v1/ HTTP/1.1" 401 12 "-" "curl/8.18.0"
Envoy engine:  [2026-08-04 11:45:44.161][1][info][admin] [source/server/admin/admin.cc:66] admin address: ...
```

```
Kong access:  172.19.0.1 - - [10/Aug/2026:12:32:44 +0000] "GET /rest/v1/nonexistent HTTP/1.1" 404 124 "-" "curl/8.18.0"
Kong error:   2026/08/10 11:59:19 [warn] 1#0: the "user" directive makes sense only if ...
```

Kong's access format is identical to Envoy's, so `kong_logs` and
`envoy_access_logs` do the same work on different routes. Kong's error
format carries no status code, which is why Kong error lines have no
`metadata.response.status_code`. Not every error line carries a request
block either - startup warnings like the one above have no client, no
request, and no host. Both cases have to survive the parse: upstream's
version of this transform reuses one `err` variable for both the line
parse and the request split, so a line with no request block takes the
failure path and is dropped. This pipeline uses a separate variable for
the split.

### Why the split exists

Upstream routes both gateways into one shared bucket
(`.appname == "supabase-kong" || .appname == "supabase-envoy"`), reusing
`kong_logs`/`kong_err` for both, since Envoy's access log is formatted to
match nginx combined. Its engine-log format is not nginx-shaped and gets
dropped there. `envoy_engine_logs` catches those lines on a separate
route.

This is a fan-out: the same event is duplicated into both transforms. Each
one aborts on the format it cannot parse (see
[Failure behavior](#failure-behavior-abort-vs-graceful)), so they act as
each other's filter and no separate filter step is needed.

A line matching neither format is aborted by both and never reaches the
store. That is inherited behavior, not a decision made here, and it is
mostly boot-time noise. Two runs measured with `vector top`:

| Transform | Events In | Events Out |
| --- | --- | --- |
| `envoy_access_logs` | 251 | 44 |
| `envoy_engine_logs` | 251 | 199 |
| `kong_logs` | 167 | 3 |
| `kong_err` | 167 | 158 |

243 of Envoy's 251 stored, 161 of Kong's 167. The remainder is what neither
format matched. Read the shape rather than the numbers - yours will differ,
and the split depends entirely on how much traffic the gateway has served
since it started. Kong's 3 access lines against 158 error lines is a stack
that booted and then handled three requests.

This drop is listed in
[log-known-limitations.md](log-known-limitations.md). If you need a
gateway line the store does not have, read it directly:

```bash
docker logs supabase-kong --tail 50
```

## Service log formats

Knowing how a service actually writes explains why a given line is not
caught. Every format below is each service's own; what is specific to this
project is how each one gets parsed.

| Service | Format | Notes |
| --- | --- | --- |
| Envoy | Two formats on one stdout stream | See [Kong and Envoy each split into two transforms](#kong-and-envoy-each-split-into-two-transforms) |
| Kong | nginx combined + nginx error | Same section as Envoy |
| REST | Two formats | `ts: msg` for lifecycle events, nginx combined for HTTP access |
| Auth | JSON | `{"level":"info","msg":"...","time":"..."}` |
| Realtime | `ts [key=value ...] [level] msg` | The `key=value` run is optional and variable |
| Supavisor | `ts [key=value ...] [level] msg` | Same shape as Realtime |
| Storage | Pino JSON | `level` is numeric, not a string |
| Postgres | `ts UTC [pid] LEVEL: msg` | |
| Edge Functions | Unstructured stderr | No parsing possible |

### REST's colon problem

The lifecycle format is `timestamp: message`, but the message body can
contain another `": "`:

```
04/Aug/2026:13:37:18 +0000: Failed listening ... port 5432 failed: Connection refused
```

A greedy `^(?P<time>.*): ` would swallow half the message into the `time`
group, failing the timestamp parse and losing the event. The regex here is
non-greedy (`.*?`) specifically to avoid that.

### Realtime and Supavisor's variable metadata

Both write an optional run of `key=value` pairs between the timestamp and
the level tag - which keys, and how many, varies per line:

```
13:37:20.170 project=realtime-dev external_id=realtime-dev [info] Finished applying migrations
14:56:47.796 region=local [error] failed to connect to Postgres
12:11:02.450 request_id=GMhKZ region=local [info] HEAD /api/health
```

The regex here uses `(?:\S+=\S+ )*` for that run and hands it to
`parse_key_value`, so any number of keys in any combination matches.
Upstream's regex for Realtime has no handling for this run at all - it
expects `time [level] msg` immediately - so a real line with any
`key=value` pairs in between simply doesn't match, and lands with no
`metadata.level`. Supavisor isn't in upstream's routing at all, so there's
no regex to compare against there.

Both services also emit their own `project=` key carrying the tenant name.
It is removed before merging, so it cannot overwrite the shared `default`
value every other service uses.

### Storage keeps its whole payload

`storage_logs` merges the entire parsed Pino payload into `.metadata`.
Upstream's own config extracts only 5 fields and does not merge the whole
`error` object, which carries the detail needed when a storage request
fails.

Storage's numeric severity values are covered in
[log-fields.md](log-fields.md#severity).

### Health check filtering

Realtime and Supavisor both emit constant health check traffic. Upstream
already has a filter stage for Realtime (`realtime_logs_filtered`,
matching literal `/health` in the event text), but this deployment's
actual health probes hit `GET /`, not `/health` - so upstream's filter
never matches them, and they'd reach the store unfiltered. Supavisor has
no upstream route at all, so there is nothing to filter there either.

This pipeline's filter stage matches the actual observed probe path for
each service, and drops response lines by status too (2xx/3xx dropped,
4xx/5xx kept), so a failing health check still shows up.

The filter judges each line on its own - by path for requests, by status
for responses - rather than pairing the two by `request_id`. Vector's
`filter` transform is stateless and could not do that pairing anyway.

One consequence: for a successful non-probe request, the request line is
stored and its response line is not, so a successful request's status code
does not reach the store. Failing requests keep both lines.

## Sink layer: Loki vs VictoriaLogs

Same event, different rejection policy:

| | Loki | VictoriaLogs |
| --- | --- | --- |
| Future timestamp | Rejects (`too new`) | Accepts silently |
| Rejection visible | Explicit error in Loki's own logs | No signal |

Loki being noisy here is an advantage - it surfaces the problem.
VictoriaLogs staying quiet means the same underlying issue is invisible
until you query for it. `timestamp_guard` closes this gap for new events on
both.

### Config notes

| Setting | Value | Why |
| --- | --- | --- |
| `chunk_idle_period` | `30s` | Loki's 30m default delays queryability. 30s suits a single-node deployment; a high-throughput cluster would tune this differently |
| `flush_check_period` | `10s` | Same reason |
| `max_chunk_age` | Loki's default (2h) | No identified benefit to narrowing it - `unordered_writes: true` already handles out-of-order writes independent of this setting |

Vector has no dedicated VictoriaLogs sink - the `elasticsearch` sink is
pointed at VictoriaLogs' bulk endpoint instead (`/insert/elasticsearch/`,
port 9428).

Sink healthchecks are asymmetric on purpose: `victorialogs.yaml` disables
its healthcheck because VictoriaLogs only emulates the Elasticsearch bulk
API and returns 400 on Vector's standard healthcheck request. Loki does not
have that problem, so its healthcheck stays on.