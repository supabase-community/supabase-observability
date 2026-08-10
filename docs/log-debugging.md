# Debugging the pipeline

Tools for working on the pipeline itself - adding a parser, changing a
transform, or finding where events disappear.

If your app broke and you need the real error, you want
[log-troubleshooting.md](log-troubleshooting.md) instead. If you want to
know why the pipeline is shaped this way, see
[log-pipeline-internals.md](log-pipeline-internals.md).

## Every command below needs two things

`docker exec -it` (both flags) and `--url http://127.0.0.1:9001`.

| What you see | What's missing |
| --- | --- |
| `Terminal must be a teletype (TTY)` | `-it` |
| The REPL opens and exits immediately | `-it` - stdin closes at EOF |
| Connection refused, or the command hangs | `--url` - this stack runs Vector's API on 9001, not the default 8686 |

Older examples show `--url http://127.0.0.1:9001/graphql`. That suffix no
longer applies: Vector's observability API moved from GraphQL to gRPC in
0.55.0.

## `vector top` - find where events disappear

```bash
docker exec -it supabase-observability-vector \
  vector top --url http://127.0.0.1:9001
```

Compare `Events In` against `Events Out` for each component.

| Reading | Means |
| --- | --- |
| In and Out roughly equal | Component is passing events through |
| In present, Out `N/A` or much lower | That component is dropping events |
| Both 0 | Nothing is reaching it - look upstream, not here |

The `--/s` column is an instantaneous rate and reads 0 with no traffic.
The cumulative counters next to it are still valid.

A drop is not automatically a bug: `kong_logs`/`kong_err` and
`envoy_access_logs`/`envoy_engine_logs` are supposed to drop most of what
they receive, since each pair acts as the other's filter. Check the
abort-vs-graceful table in
[log-pipeline-internals.md](log-pipeline-internals.md#failure-behavior-abort-vs-graceful)
before treating a gap as a defect.

## `vector vrl` - test a parser against a real line

```bash
docker exec -it supabase-observability-vector vector vrl
```

Fallible functions must be received as a pair, or the REPL rejects the
expression:

```
p, e = parse_regex("13:37:20.170 region=local [info] hello", r'^(?P<time>\d+:\d+:\d+\.\d+) (?P<meta>(?:\S+=\S+ )*)\[(?P<level>\w+)\] (?P<msg>.*)$')
```

The REPL prints only the last expression, so wrap multiple values in an
array to see them together:

```
[p, e]
```

**One REPL-only caveat.** The REPL infers types from the literal you typed,
but in the running pipeline the same field is `any`-typed. So the REPL can
report `??` as unnecessary on an expression that genuinely needs it in the
real pipeline. A type complaint here is not on its own evidence that error
handling can be removed.

Always test against a line you actually captured, not one you typed from
memory:

```bash
docker logs supabase-auth --tail 5
```

## `vector tap` - watch events live

```bash
docker exec -it supabase-observability-vector \
  vector tap router.envoy --url http://127.0.0.1:9001
```

Takes a component name (`docker_host`, `storage_logs`) or a route output
(`router.<name>`).

Open it **before** generating the traffic you want to see. It only streams
events from the moment it attaches - it does not replay.

## Checking remap failures

```bash
docker logs supabase-observability-vector 2>&1 | grep -i "mapping failed"
```

## Validating a config change before restarting

Both files together - `base.yaml` has no sinks, so it doesn't validate
alone:

```bash
docker exec supabase-observability-vector vector validate \
  --no-environment /etc/vector/base.yaml /etc/vector/backend.yaml
```

Vector doesn't reload config on its own. After editing anything under
`config/vector/`:

```bash
make restart-vector
```

That restarts the container and prints its startup log, which is where a
config error shows up.

## Inspecting containers

The Loki and VictoriaLogs images are distroless - no shell, no `env`, no
`grep`. `docker exec <container> env` fails, and the empty output can look
like a missing variable rather than a missing shell. Use `docker inspect`:

```bash
docker inspect supabase-rest --format '{{range .Config.Env}}{{println .}}{{end}}'
docker inspect supabase-envoy --format '{{range .Config.Cmd}}{{println .}}{{end}}'
docker inspect supabase-db --format '{{.State.Running}}'
docker inspect supabase-auth --format '{{.LogPath}}'
```

`docker port <container>` is worth checking too, separately from
`docker inspect` - a container can report `healthy` with its intended port
binding visible in `HostConfig.PortBindings` while never having actually
bound it. See
[log-troubleshooting.md](log-troubleshooting.md#everything-looks-healthy-but-nothing-responds).

## Counting results

`wc -l` on a store's response counts lines of NDJSON framing, not events.
Use the store's own aggregation:

```bash
curl -s http://localhost:9428/select/logsql/query \
  --data-urlencode 'query=appname:"supabase-db" AND _time:15m | count()'
```

## Pre-flight checks before opening a PR

```bash
bash -n scripts/*.sh
docker exec supabase-observability-vector vector validate \
  --no-environment /etc/vector/base.yaml /etc/vector/backend.yaml
make verify-logs
```
