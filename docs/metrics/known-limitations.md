# Metrics known limitations

What is currently wrong or incomplete in the metrics pipeline, where each
issue comes from, and whether there is a workaround.

## Gaps in what is collected

| Service | Status | Note |
| --- | --- | --- |
| Edge Functions | Not collected | Supabase's self-hosted compose runs the edge runtime without `--event-worker` (as of 2026-09-21) |
| Kong | Not scraped by default | `config/metrics/otel-collector.yaml` has a commented-out `supabase-kong` job, not verified against this stack. `overrides/metrics-envoy.yml` applies to Envoy only - leave it out of `COMPOSE_FILE` if you run Kong |
| Studio, postgres-meta | Not collected | No scrape job defined |

## Issues in how the pipeline behaves

| Issue | Where it's from | Status |
| --- | --- | --- |
| Metrics waiting in the collector's send queue are lost if the collector restarts | `prometheusremotewrite` only has an in-memory queue - no `sending_queue`, no `file_storage`. See [pipeline internals](pipeline-internals.md#its-queue-is-memory-only) | Open upstream: [opentelemetry-collector-contrib#33137](https://github.com/open-telemetry/opentelemetry-collector-contrib/issues/33137) |
| Nothing is scraped while the collector is down, so every scraped service has a gap for that window | Pull model - there is no history to fetch afterwards | No workaround. Whether Storage retries pushes that failed during the outage has not been determined |
| Storage has no `up` metric, so it can't be alerted on the way the other services can | Storage pushes; `up` only exists for scrape targets | Check that its series are arriving - see [README.md](README.md#confirm-it-works) |
| Storage's `instance` label changes on every container recreate, starting a new series for each metric | OTel resource identity, which includes the container ID | Aggregate it away in queries that span a recreate, e.g. `sum without (instance) (...)` |
| The Supavisor/Realtime scrape credential is `ANON_KEY`, and there is no metrics-only secret | Supabase's compose sets `METRICS_JWT_SECRET` to `${JWT_SECRET}` for both services | After rotating keys, re-run `scripts/generate-metrics-secrets.sh` and force-recreate the collector - see [README.md](README.md#how-the-secrets-are-generated) |
| `pg_stat_activity_*` carries `application_name` and `wait_event` labels, whose values aren't bounded | postgres-exporter's own labels | Not reduced yet |
| Scraping Realtime produces "same timestamp, different value" warnings | Source metric not identified | Open |
| Moving or deleting this repo breaks Supabase's `run.sh` and `docker compose` commands while the overrides are registered | `COMPOSE_FILE` holds absolute paths into this repo, and Compose errors on a missing one | By design - loud rather than silent. Remove the two entries first - see [README.md](README.md#stopping-and-removing) |

## Not covered yet

Dashboards, alerting, and traces are tracked on the
[repo README](../../README.md#status), not here.