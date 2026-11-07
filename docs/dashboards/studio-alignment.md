# Dashboards and Supabase Studio

The Overview dashboard follows the layout, names and status rules of the
Observability Overview page in Supabase Studio, so that it looks familiar to
people who know Supabase's managed platform. Self-hosted Supabase does not
have the data behind every Studio chart, so some charts are replaced or left
out. This page lists each difference and the reason for it.

## Overview dashboard

Grafana loads the dashboard from `config/dashboards/overview.json` into the
**Supabase** folder. It reads only from the metrics store, so it works with
any Prometheus-compatible metrics backend.

### Needs attention

Studio's Overview has no row like this one. The panels in this row use the
conditions of Supabase's
[detection checks](https://supabase.com/docs/guides/observability/detecting),
plus two checks that matter when you run the stack yourself.

| Panel | Turns red when | Based on |
|---|---|---|
| Targets down | Any scrape target reports `up == 0` | Self-hosted operation |
| API server errors (1h) | 5xx responses are at least 1% of gateway responses | Detection check "Measure API and Auth server errors" |
| Auth server errors (1h) | 5xx responses are at least 1% of Auth responses | Detection check "Measure API and Auth server errors" |
| Connection pressure | Client connections reach 80% of `max_connections` | Detection check "Check connection pressure" |
| Longest open transaction | A transaction that is active or idle in transaction is 30 seconds old | Detection check "Find long-running sessions and blockers" |
| Inactive replication slots | A slot stays inactive for 5 minutes | Self-hosted operation |

The two error panels show a value only when the gateway or Auth answered at
least 100 requests in the last hour, the same minimum the detection check
uses. The rest of the detection check's conditions are not applied; see
[known-limitations.md](known-limitations.md).

### Database

| Studio | This dashboard | Metric |
|---|---|---|
| Peak Connections | Peak Connections | `pg_stat_activity_count{backend_type="client backend"}`, `pg_settings_max_connections` |
| Database Connections (Database report) | Database Connections, stacked by role | `pg_stat_activity_count` by `usename` |
| Disk Usage | Database size, for the `postgres` database only | `pg_database_size_bytes`. Studio shows how full the disk is. This panel shows only the size of the database, because the size of the disk needs host metrics. |
| CPU, Memory | Not shown | These need host and container metrics, which are not among the [metrics this stack collects](../metrics/README.md#what-gets-scraped) yet. |
| Disk IO balance | Not shown | This is the burst balance of the managed platform's disks. Self-hosted disks have no equivalent value. |
| Slow Queries | Not shown | This needs `pg_stat_statements` queries in postgres-exporter. |

Database Connections names each role the way Studio does.

| Role | Shown as |
|---|---|
| `postgres` | Postgres |
| `authenticator` | PostgREST |
| `supabase_admin` | Reserved |
| `supabase_auth_admin` | Auth |
| `supabase_storage_admin` | Storage |
| Any other role | Other roles |

The row also has four panels that Studio's Overview does not have:
**Rollback ratio**, **Cache hit ratio**, **Deadlocks** and **Slot WAL
headroom**. Cache hit ratio has no fixed good value, so it is not colored.
Slot WAL headroom shows how much WAL can still be written before the
closest replication slot is invalidated. It has a value only when
`max_slot_wal_keep_size` is set to a limit, because Postgres reports no
headroom for a slot that may keep an unlimited amount of WAL. The panel reads
"No limit or no slots" when there are no slots or when the setting is `-1`.

### Service health

The table lists Studio's services in Studio's order, except Database, and
uses the same status rule.

| Status | Rule |
|---|---|
| Unknown | Fewer than 100 requests in the selected time range |
| Unhealthy | Errors are 1% of requests or more |
| Healthy | Anything else |

The data behind it is different.

- Studio counts log events per service by level. This dashboard counts
  responses at the gateway by status class. Errors are 5xx responses, and
  4xx responses show as warnings in the bar charts without counting as
  errors.
- **API Gateway** uses the gateway's own totals. These include requests the
  gateway rejects itself, such as a request with a missing or wrong API key.
  The other rows count only requests that reached that service.
- **Database** is not in the table. Studio builds its Database row from
  Postgres log events by severity, and this dashboard reads only metrics.
- The table adds a 95th percentile latency column, which Studio's Overview
  does not show.

## Known limitations

See [known-limitations.md](known-limitations.md).
