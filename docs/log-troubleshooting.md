# Finding the actual error when your app breaks

Your app throws an error, the message is vague, and you're not sure which
Supabase service caused it. This maps symptoms to where the real error lives.

All queries go in the VictoriaLogs UI at
`http://localhost:9428/select/vmui/`, or over HTTP with `curl` (see
[logs.md](logs.md#querying-victorialogs)).

## Start here

```
severity:"error" AND _time:15m
```

This scans every service at once on the pipeline's normalized severity
field, not a text match on the word "error". It often surfaces a problem in
a service you weren't looking at, like a background connection failure.

If that returns nothing useful, work down the table.

| Symptom | Likely service | Jump to |
| --- | --- | --- |
| Nothing responds at all, but everything looks healthy | Gateway not published | [Gateway unreachable](#everything-looks-healthy-but-nothing-responds) |
| A query returns nothing, but you expect data | Store or query, not a service | [Empty query](#a-query-returns-nothing-but-the-logs-should-be-there) |
| Request fails, the service you expect shows nothing | Gateway (Envoy or Kong) | [Gateway](#request-fails-but-the-service-shows-nothing) |
| `row-level security policy` | Postgres | [RLS](#insert-or-update-fails-with-row-level-security-policy) |
| Upload fails vaguely | Storage | [Storage](#file-upload-fails-with-a-vague-error) |
| Sign-in fails with no detail | Auth | [Auth](#sign-in-fails-with-no-useful-detail) |
| Connection refused / pooler errors | Supavisor | [Pooler](#database-connections-fail-through-the-pooler) |

---

## Everything looks healthy but nothing responds

Containers are `Up`, health checks report `healthy`, `make verify-logs`
passes, and yet requests to the gateway do not connect:

```
curl: (7) Failed to connect to localhost port 8000 after 0 ms
```

Check whether the gateway published its port at all:

```bash
docker port supabase-kong     # or supabase-envoy
```

Empty output means it did not. `docker inspect` is not enough here -
`HostConfig.PortBindings` still shows the intended binding even when it was
never established.

This happens when a gateway container fails to bind once (typically because
a previous gateway was still holding the port) and is then started again
rather than recreated. A gateway's health check runs inside the container
and does not test port publishing, so it keeps reporting healthy.

```bash
cd "$SUPABASE_DIR"
sh run.sh recreate api-gw
docker port supabase-envoy     # or supabase-kong
```

You should see the port listed. Confirm with a request:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8000/rest/v1/
```

`401` is the expected answer without an API key. `000` means still no
connection.

`make verify-logs` passing in this state is expected rather than
misleading. It confirms services are reaching the log store, which they
are - the gateway was still writing its own startup logs. It does not
confirm your stack is serving traffic.

Not every `✗` in `make verify-logs`'s table is caused by the same thing,
and not every `✓` confirms the gateway path either - `db`, `realtime`, and
`pooler` produce traffic independent of the gateway, so they can pass even
while it is down.

---

## A query returns nothing, but the logs should be there

Work through these in order - the first two are far more common than the
last two.

**1. No time filter, or the wrong window.** Every query needs one.

On Loki, `query_range` without `start`/`end` falls back to a narrow
default window and returns nothing even when the data exists:

```bash
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={service=~".+"}' \
  --data-urlencode "start=$(date -u -d '10 minutes ago' +%s)000000000" \
  --data-urlencode "end=$(date -u +%s)000000000"
```

(GNU `date` syntax - macOS's BSD `date` needs a different flag for this.)

On VictoriaLogs, to search a specific past window rather than "the last N
minutes", give it an explicit range - brackets and a comma, not
`_time:start:end`:

```
appname:"supabase-auth" AND _time:[2026-08-04T11:00:00Z, 2026-08-04T14:00:00Z]
```

An empty result on a narrow window is not evidence a field is missing. An
idle stack produces nothing. Widen the window before concluding anything:

```
appname:"supabase-storage" AND _time:24h | limit 1
```

**2. Wrong label key for the store.** Loki uses `service`, VictoriaLogs uses
`appname`. Querying `{appname="..."}` against Loki matches nothing and
raises no error.

Field names differ too. VictoriaLogs flattens nested objects into dotted
keys (`metadata.req.method`), Loki stores the event as one JSON blob that
has to be unwrapped first. See [log-fields.md](log-fields.md#how-fields-are-stored).

**3. The service hasn't logged anything.** Several are quiet by default - see
[log-levels.md](log-levels.md). Confirm with `docker logs <container>`
before assuming the pipeline is at fault.

**4. Loki only: not flushed to disk yet.** Loki buffers incoming lines in
memory and only writes them out - "flushes" them - once a batch (a *chunk*)
goes idle. Its own default `chunk_idle_period` is 30 minutes, so a line
isn't queryable until then. This repo ships `config/loki/loki-config.yaml`
with `chunk_idle_period: 30s`, so you shouldn't hit this - but if you
wrote your own Loki config and `docker logs` shows events that queries
can't find, check this setting.

---

## Loki rejects logs as "timestamp too new"

The host clock jumped forward while a container was running. Docker stamped
that container's log lines with a future time, permanently, in its log
file.

This pipeline replaces ("clamps") any timestamp more than 60 seconds ahead
of ingest time - the moment Vector read the line - and keeps the original
in `metadata.timestamp_future`, so Loki accepts the events and the error
stops. Seeing that field in your data means the host clock is, or was,
wrong - fix the clock first.

Clamping keeps the store usable but doesn't clean the container's log file.
`docker restart` won't help either, since it appends to the same file. The
container needs a fresh log file:

```bash
cd "$SUPABASE_DIR"
sh run.sh recreate <service>
```

On VictoriaLogs there's no error to see - it accepts future timestamps
silently, so the same clock problem shows up as duplicated or
oddly-ordered entries instead.

---

## Request fails, but the service shows nothing

Every request goes through the gateway first. If the API key is missing or
invalid, the gateway rejects it before it reaches auth, rest, storage, or
anything else. The error lives in the gateway's logs, not the service you
called.

| Your gateway | Query |
| --- | --- |
| Envoy | `appname:"supabase-envoy" AND metadata.response.status_code:* AND _time:5m` |
| Kong | `appname:"supabase-kong" AND metadata.response.status_code:* AND _time:5m` |

`metadata.response.status_code:*` narrows this to access lines. Both
gateways also write their own internal logs to the same stream, and those
would otherwise dominate the result.

Look for the status code:

```
172.19.0.1 - - [...] "GET /rest/v1/ HTTP/1.1" 401 81 "-" "curl/8.18.0"
```

If the request appears here but nothing appears in the target service, it
never got past the gateway. Check your `apikey` header before raising that
service's log level. Raising it won't help if the request never arrived.

The gateway's own internal logs carry a different shape. Envoy tags them
with a component:

```
[2026-08-04 11:45:44.167][1][warning][misc] ...
```

Kong writes nginx error lines:

```
2026/08/10 11:59:19 [warn] 1#0: the "user" directive makes sense only ...
```

---

## Insert or update fails with "row-level security policy"

Your app sees:

```json
{"code":"42501","message":"new row violates row-level security policy for table \"...\""}
```

That message doesn't say which policy or why. Postgres logs the exact query
that was rejected, including which role ran it, but only once its log level
is raised.

In `.env`, set:

```
SUPABASE_DB_LOG_LEVEL=warning
```

Then:

```bash
scripts/set-log-levels.sh apply
```

Reproduce the request, then query:

```
appname:"supabase-db" AND _time:5m
```

You get two lines:

| Line | Contains |
| --- | --- |
| `ERROR:` | The violation itself |
| `STATEMENT:` | The exact INSERT/UPDATE PostgREST generated, and the role it ran as (`authenticator`, `anon`, `authenticated`, ...) |

The `STATEMENT` line is usually what you need. Check which role ran the
query and compare it against your policy's `USING` / `WITH CHECK` clause.

The `STATEMENT` line carries no severity of its own and lands as `LOG`, so
it will not appear under `severity:"error"`. Query by time alongside its
`ERROR:` line.

```bash
scripts/set-log-levels.sh reset
```

---

## File upload fails with a vague error

In `.env`, set `SUPABASE_STORAGE_LOG_LEVEL=info`, then:

```bash
scripts/set-log-levels.sh apply
```

Query:

```
appname:"supabase-storage" AND metadata.error:* AND _time:5m
```

Look at the `metadata.error` object. The exact key for the error identifier
varies (`code` or `errorCode`, depending on where in storage-api the error
originates), but the object carries enough context either way.

| Value | Means |
| --- | --- |
| `NoSuchBucket` | The bucket doesn't exist |
| `AccessDenied` | A storage policy, RLS rule, or an invalid/expired token is blocking it |

The request that failed is on the same line: `metadata.req.url`,
`metadata.req.method`, `metadata.role`, and `metadata.res.statusCode`.

Storage logs with Pino, a Node.js library that writes severity as a number,
so `metadata.level:50` is an error line. Filtering on `severity:"error"`
avoids having to remember that.

```bash
scripts/set-log-levels.sh reset
```

---

## Sign-in fails with no useful detail

In `.env`, set `SUPABASE_AUTH_LOG_LEVEL=info`, then:

```bash
scripts/set-log-levels.sh apply
```

Query:

```
appname:"supabase-auth" AND metadata.error_code:* AND _time:5m
```

`metadata.error_code` holds the reason: `invalid_credentials`,
`email_not_confirmed`, and so on. `metadata.path` and `metadata.status` on
the same line tell you which request it was.

`info` is enough for this. Don't reach for `debug` on auth unless you
specifically need to trace an OAuth flow. At `debug`, auth logs the OAuth
exchange code in full. It's short-lived and single-use, but it's a
credential sitting in your log store until retention clears it.

```bash
scripts/set-log-levels.sh reset
```

---

## Database connections fail through the pooler

Supavisor has no runtime log level control, but it logs connection failures
at `error` by default, so they're already there:

```
appname:"supabase-pooler" AND severity:"error" AND _time:15m
```

Connection errors carry the client details as parsed fields:

| Field | Example |
| --- | --- |
| `metadata.user` | `postgres` |
| `metadata.mode` | `session` |
| `metadata.peer_ip` | `172.19.0.3` |
| `metadata.app_name` | `psql` |

A common one is `(ENOIDENTIFIER) no tenant identifier provided`, which means
the client connected without a tenant in the username or SNI hostname.

Health check traffic is filtered out of the store, so what you see here is
real traffic only.

---

## A note on log levels and restarts

`scripts/set-log-levels.sh apply` restarts the containers whose level
actually changed. That's fine in development. In production: raise the
level, reproduce the issue, capture what you need, then run
`scripts/set-log-levels.sh reset` right away.

`scripts/set-log-levels.sh status` shows what's currently applied against
what `.env` asks for.

Note that `make verify-logs` temporarily raises `rest` and `db`, then puts
them back at their upstream defaults when it finishes. If you had levels
applied deliberately, re-apply them afterwards.
