# Known limitations

What is currently wrong or incomplete in the log pipeline, where each issue
comes from, and whether there is a workaround.

Some of these come from upstream Supabase's own Vector config, which this
pipeline reuses the shape of, and some are this project's own. The
distinction matters mainly for where a fix would land, so each row says
which.

## Issues you can see in query results

| Issue | Where it's from | Workaround |
| --- | --- | --- |
| REST and Edge Functions carry no severity field, so they always land as `severity:"info"` | Neither service prints a severity marker in its log line at all | Filter by `appname` and read the message |
| `db_logs`'s severity regex is greedy - a `LOG:` line whose query text contains a word like `ERROR` can be misread as `error` | Upstream's `vector.yml`, same regex | Check the actual level in `_msg` |
| Postgres continuation lines (`STATEMENT`, `DETAIL`, `HINT`, `CONTEXT`) fall through to `LOG` instead of inheriting their parent line's severity | Upstream's `vector.yml` does not tag these either | They immediately follow their `ERROR:` line, so query by time |
| Gateway lines matching neither the access nor the error format are dropped by both transforms and never reach the store | Upstream's `vector.yml` uses the same abort-on-failure shape | Read them directly with `docker logs <gateway>`. See [pipeline internals](log-pipeline-internals.md#kong-and-envoy-each-split-into-two-transforms) for measured counts |
| Realtime's startup shell trace does not match its log format, so those lines reach the store with no `metadata.level` | Realtime's entrypoint script, not a parser problem | Query `_msg` rather than `metadata.level` for startup lines |
| A successful non-probe request to Realtime or Supavisor stores its request line but not its response line, so the status code is missing | This pipeline's health check filter, which judges responses by status | Failing requests keep both lines. For success rates, use metrics rather than logs |

## Issues in how the pipeline behaves

| Issue | Where it's from | Status |
| --- | --- | --- |
| `.stream` (stdout vs stderr) is deleted in `project_logs`, so that distinction never reaches the store | Matches upstream's own log shape | Not planned - would diverge from upstream's field set |
| Timestamp basis differs per service - some parse `_time` from the log body, others keep Docker's collection time, see [log-fields.md](log-fields.md#_time-and-metadatatimestamp) | Mostly upstream's `vector.yml`, same split | Design decision needed if this needs unifying |
| `docker_logs` replays a container's full log history on every Vector restart | Vector's own source behavior, not Supabase-specific | `timestamp_guard` prevents the future-timestamp fallout of this, not the duplicate ingestion itself. See [pipeline internals](log-pipeline-internals.md#docker_logs-replay-semantics) |
| `envoy_engine_logs`'s malformed-timestamp handling has never been observed running against a real malformed timestamp | This pipeline's own code (upstream has no transform for Envoy's engine-log format) | Compiles and passes `vector validate`; not known to be broken, just not confirmed live |
| `verify-logs.sh` confirms each service is reaching the store, not that each service's parsers produced fields | This pipeline's own scope choice | A service emitting only unparsed lines still passes - check fields with the queries in [log-fields.md](log-fields.md). Some services also produce traffic without a gateway request (Realtime's own health probe, direct `psql` calls to `db`), so their `✓` does not confirm the gateway path specifically |

## Fixed relative to upstream

These are differences in upstream Supabase's own `vector.yml` that this
pipeline does not carry. They are listed here because the behavior is
different from what you would see on a stock self-hosted stack, and because
anyone comparing the two configs will want to know the divergence is
deliberate.

| Upstream behavior | Here |
| --- | --- |
| `kong_err` reuses one `err` variable for the line parse and the request split, so an error line with no request block takes the failure path and is dropped | Separate variable for the split; startup warnings and other request-less error lines are kept |
| `kong_err` sets `status_code: 200` and `method: GET` before parsing, on a format that carries neither | Neither is set. Kong error lines have no `metadata.response.status_code` |
| `auth_logs` merges the parsed payload without deduping, leaving `metadata.time` alongside `metadata.timestamp` and the raw JSON in the message field | Deduped after merge, matching what `storage_logs` already did |
| `storage_logs` extracts 5 fields and drops the rest, including the whole `error` object | Full payload merged |
| `rest_logs` uses a greedy `.*` for the timestamp group, so a message containing a second `": "` fails the parse and the event is lost | Non-greedy `.*?` |
| `db_logs`'s severity list omits `DEBUG`, so debug lines land as `LOG` | `DEBUG` added |
| Realtime's metadata regex expects `time [level] msg` immediately, with no handling for the `key=value` pairs real lines carry in between, so those lines don't match and get no `metadata.level` | `(?:\S+=\S+ )*` plus `parse_key_value` |
| Envoy's engine-log format has no transform upstream - access logs already route through the shared Kong transforms, but engine lines hit `kong_err`'s abort-on-parse-failure and are dropped | Separate `envoy_engine_logs` transform added |
| No Supavisor route | Route added |

Where a difference looks like an upstream bug rather than a deliberate scope call, it is raised upstream separately rather than tracked here.

## Not covered yet

Edge Functions structured logging, metrics, traces, dashboards, and
Kubernetes are all tracked on the [repo README](../README.md#status), not
duplicated here.

## Reporting

If you hit something not listed here, open an issue on this repository
rather than the Supabase repositories. Include which gateway you run (Envoy
or Kong), your `BACKEND_LOGS` value, and the output of `make verify-logs`.
