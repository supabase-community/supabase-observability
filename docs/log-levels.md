# Log level reference

Allowed values, defaults, and case sensitivity for every controllable
service, and what each level actually gets you.

Set a level in `.env`:

```
SUPABASE_REST_LOG_LEVEL=info
```

Then apply it:

```bash
scripts/set-log-levels.sh apply
```

This controls whether a service writes a line at all - not how that line
gets classified once it's stored. For the stored `.severity` field, see
[log-fields.md](log-fields.md#severity). For which services ship quiet and
why that matters, see
[logs.md](logs.md#known-upstream-defaults-that-suppress-logs).

| Service | Set in `.env` | Values | Default | Case |
| --- | --- | --- | --- | --- |
| REST | `SUPABASE_REST_LOG_LEVEL` | `crit` `error` `warn` `info` `debug` | `error` | lowercase only |
| Auth | `SUPABASE_AUTH_LOG_LEVEL` | `panic` `fatal` `error` `warn` `warning` `info` `debug` `trace` | `info` | any |
| Realtime | `SUPABASE_REALTIME_LOG_LEVEL` | `emergency` `alert` `critical` `error` `warning` `warn` `notice` `info` `debug` | `info` | lowercase only |
| Storage | `SUPABASE_STORAGE_LOG_LEVEL` | `trace` `debug` `info` `warn` `error` `fatal` `silent` | `info` | lowercase only |
| Edge Functions | `SUPABASE_FUNCTIONS_LOG_LEVEL` | `trace` `debug` `info` `warn` `error` `off` | `info` | any |
| Envoy | `SUPABASE_ENVOY_LOG_LEVEL` | `trace` `debug` `info` `warning` (= `warn`) `error` `critical` `off` | `info` | lowercase only |
| Kong | `SUPABASE_KONG_LOG_LEVEL` | `debug` `info` `notice` `warn` `error` `crit` `alert` `emerg` | `notice` | lowercase only |
| Postgres | `SUPABASE_DB_LOG_LEVEL` | `debug5`..`debug1` `info` `notice` `warning` `error` `log` `fatal` `panic` | `fatal` | any |
| Supavisor | none | | | no runtime control |

Every default above is the service's own, except Postgres. Supabase sets
`log_min_messages=fatal` in its compose `command:` to keep Realtime's
polling queries out of the log; Postgres on its own defaults to `warning`.
Leaving a variable unset in `.env` gives you the same value either way.

Only one gateway row applies to you - see
[logs.md](logs.md#gateway-routing) for which one your stack runs and how to
switch.

## Which level do you need

The table above is what each service accepts. This is what you get back.

### REST and Storage

Both classify an HTTP response the same way: 4xx at `warn`, 5xx at
`error`, everything else at `info`.

| You want to see | Set |
| --- | --- |
| 5xx only | `error` |
| 4xx too (auth failures, bad requests, RLS rejections) | `warn` |
| Successful requests too | `info` |
| The service's own internals | `debug` |

Two things specific to REST:

- `crit` is not silence. Startup, database connection, schema cache, and
  config reload messages are written at every level.
- `debug` and `info` log responses identically. The difference is pool
  connection state changes, JWT cache lookups and evictions, and Warp
  server events.

### Auth does not follow that rule

Auth writes its request line at `info` whatever the status was, so `warn`
and `error` hide it completely. `metadata.error_code`, which is the field
worth having on a failed sign-in, rides on that line. Leave auth at `info`
when you are debugging a request, and reach for `debug` only to trace an
OAuth flow - see [Security](#security) below first.

### Postgres works on message severity instead

Not on response status. One thing here is genuinely counterintuitive:
`LOG` outranks `ERROR`, so the threshold that turns on query errors also
turns on DDL, but not the other way round.

| Set | Query errors | Failing SQL (`STATEMENT:`) | DDL |
| --- | --- | --- | --- |
| `fatal` (the shipped default) | no | no | no |
| `log` | no | no | yes |
| `error` | yes | yes | yes |
| `warning` and below | yes | yes | yes |

So `error` is the level to reach for: it gets you the failed query, the
SQL that caused it, and a DDL trail in one step. `log` is legal but rarely
useful - operational messages without the errors. `warning` adds warnings
on top of everything `error` already gives you.

The `STATEMENT:` line is attached to its `ERROR:` entry rather than being
a message of its own, so it arrives and disappears with the error. It
comes from `log_min_error_statement`, which Supabase leaves at its default
of `error`. See [logs.md](logs.md#security-considerations) for what those
lines contain.

### The gateways only control their own internal logs

`SUPABASE_KONG_LOG_LEVEL` and `SUPABASE_ENVOY_LOG_LEVEL` affect each
gateway's error or engine log. Access lines are written regardless, so you
do not need to raise a level to see whether a request reached the gateway.

### Realtime

`error` and `warning` cover channel and connection failures. `info`, the
default, adds request lines and lifecycle messages. `debug` adds tenant
and extension startup messages that carry credentials in full, so read
[Security](#security) below before setting it.

### The two with no useful choice

| Service | Why |
| --- | --- |
| Supavisor | Nothing below `info` is in the binary |
| Edge Functions | `RUST_LOG` only reaches the runtime's own logging, not user function output |

## Before you change a level, know these

Five services don't behave the way you'd expect from the table above:

| Service | What actually happens |
| --- | --- |
| Realtime | An invalid value crashes the container instead of being ignored |
| Kong | Only the `error_log` is affected - access logs are written regardless of value |
| Postgres | `debug5`-`debug1` never appear as a line label - Postgres always prints plain `DEBUG`. They only affect the threshold itself |
| Supavisor | Nothing below `info` exists in the binary - it's stripped at compile time, so there's no way to enable it |
| Edge Functions | Only the runtime's own internal logging is affected - whether or how user function `console.log` output is captured is unverified, and expected to change once upstream's event-worker rework lands |

Postgres and Envoy are set through their container's `command:` array
rather than an environment variable. A `command:` change cannot be picked
up by a restart; the container has to be recreated, which is what
`scripts/set-log-levels.sh apply` does for you.

## Security

Raising a level can put credentials in the store. Check this before
turning on `debug` anywhere:

| Service | At `debug`, logs include |
| --- | --- |
| Auth | The full OAuth exchange code |
| Realtime | The tenant JWT secret, in plaintext |

Postgres doesn't need `debug` for this - at `error` or lower it already
logs the failed statement (`STATEMENT:`) next to any `ERROR:` line,
including literal values from the query. See
[logs.md](logs.md#security-considerations) for the full breakdown.

## Confirming what's applied

To see what each container is actually running with, against what `.env`
asks for:

```bash
scripts/set-log-levels.sh status
```

For the container inspection commands `status` uses under the hood, see
[log-debugging.md](log-debugging.md#inspecting-containers).

## What the scripts set for you

The `.env` names above are this project's. Each maps to whatever the
service itself reads. You only need this if you're reading
`docker inspect` output or editing the override files directly.

| `.env` | Becomes | Levels defined by |
| --- | --- | --- |
| `SUPABASE_REST_LOG_LEVEL` | `PGRST_LOG_LEVEL` | [PostgREST `log-level`](https://docs.postgrest.org/en/v14/references/configuration.html#log-level) |
| `SUPABASE_AUTH_LOG_LEVEL` | `GOTRUE_LOG_LEVEL` | [logrus `Level`](https://pkg.go.dev/github.com/sirupsen/logrus#Level) |
| `SUPABASE_REALTIME_LOG_LEVEL` | `LOG_LEVEL` | [Elixir `Logger`](https://hexdocs.pm/logger/1.14/Logger.html#module-levels) |
| `SUPABASE_STORAGE_LOG_LEVEL` | `LOG_LEVEL` | [Pino `level`](https://github.com/pinojs/pino/blob/main/docs/api.md#level-string) |
| `SUPABASE_FUNCTIONS_LOG_LEVEL` | `RUST_LOG` | [env_logger](https://docs.rs/env_logger/latest/env_logger/#enabling-logging) |
| `SUPABASE_ENVOY_LOG_LEVEL` | `--log-level` in `command:` | [Envoy log levels](https://www.envoyproxy.io/docs/envoy/latest/start/quick-start/run-envoy#debugging-envoy) |
| `SUPABASE_KONG_LOG_LEVEL` | `KONG_LOG_LEVEL` | [Kong Gateway logs](https://developer.konghq.com/gateway/logs/) |
| `SUPABASE_DB_LOG_LEVEL` | `log_min_messages` in `command:` | [Message Severity Levels](https://www.postgresql.org/docs/current/runtime-config-logging.html#RUNTIME-CONFIG-SEVERITY-LEVELS) |

Realtime and Storage both read plain `LOG_LEVEL` - the names only differ
on this project's side. Supavisor has no row because no variable reaches
it.

Everything on this page was checked against the images upstream's compose
currently pins: postgrest v14.12, gotrue v2.189.0, realtime v2.102.3,
storage-api v1.60.4, edge-runtime v1.74.0, postgres 17.6.1.136, supavisor
2.9.5, envoy v1.39.0, and kong 3.9.3. Behavior can change between image
versions - Auth's is already different on its main branch.

## Why the gateway has its own override file

Kong and Envoy share one compose service, `api-gw` - upstream swaps the
image rather than defining two services. But they take a log level
differently: Envoy reads it from the command array, Kong from an env var.
A single shared entry can't cover both. Kong's entrypoint ignores command
args, so Envoy's `--log-level` would silently do nothing under Kong while
still appearing in `docker inspect` - misleading either way.

So the gateway sits in `overrides/log-levels-envoy.yml` or
`overrides/log-levels-kong.yml`, not the shared `overrides/log-levels.yml`.
`scripts/set-log-levels.sh` adds whichever matches the running gateway.

If you switch gateways, reset the level first -
[logs.md](logs.md#switching-gateway) covers why.

## Why the scripts expand `COMPOSE_FILE` by hand

Supabase records its enabled overrides (Envoy, pg17, s3, ...) in
`COMPOSE_FILE` in its own `.env`. Docker Compose ignores that variable
entirely the moment any `-f` flag is passed, and both
`scripts/set-log-levels.sh` and `scripts/verify-logs.sh` have to pass `-f`
to layer `overrides/log-levels.yml` in.

So each script reads `COMPOSE_FILE`, splits it on `:`, and passes every
entry back as its own `-f`. Without that, applying a log level would
silently drop whichever of your other Supabase overrides weren't also
re-specified - the Envoy override among them, which is how a level applied
while running Envoy can end up talking to a project that thinks it's
running Kong.

The same applies if you run Compose against your Supabase directory by
hand: adding one `-f` discards the rest, unless you expand `COMPOSE_FILE`
yourself the same way.
