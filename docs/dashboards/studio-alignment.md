# Dashboards and Supabase Studio

Each dashboard follows the layout, names and rules of a page in Supabase
Studio's Observability section, so that it looks familiar to people who know
Supabase's managed platform. Self-hosted Supabase does not
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

The **API Gateway** bar chart and the table both link to the API Gateway
dashboard, keeping the selected time range.

## API Gateway dashboard

Grafana loads the dashboard from `config/dashboards/gateway.json`. It follows
the API Gateway page in Studio's Observability section and uses that page's
chart names. Studio builds the page from the gateway's request logs. This
dashboard reads the Envoy gateway's own metrics instead, so it works with any
Prometheus-compatible metrics backend.

### API Gateway

The first row has Studio's four charts for the whole gateway.

| Studio | This dashboard | Metric |
|---|---|---|
| Total Requests | Total Requests | `envoy_http_downstream_rq_total{envoy_http_conn_manager_prefix="ingress_http"}` |
| Response Errors | Response Errors, split into 4xx and 5xx | `envoy_http_downstream_rq_xx_total{envoy_http_conn_manager_prefix="ingress_http"}` for status classes 4 and 5 |
| Response Speed | Response Speed, as an average and a 95th percentile | `envoy_cluster_upstream_rq_time_sum`, `envoy_cluster_upstream_rq_time_count` and `envoy_cluster_upstream_rq_time_bucket` for PostgREST, Auth, Edge Functions and Storage |
| Network Traffic | Network Traffic, as ingress and egress | `envoy_cluster_upstream_cx_tx_bytes_total` for ingress and `envoy_cluster_upstream_cx_rx_bytes_total` for egress, for the five services |
| Requests by Geography | Not shown | Studio takes the country from Cloudflare, and a self-hosted gateway has no country for a request. |
| Top routes under Total Requests, Response Errors and Response Speed | Not shown | Envoy's metrics have no request path. |

The metrics differ from Studio's logs in these ways.

- **Total Requests** and **Response Errors** use the gateway's own totals,
  the same ones as the Overview's API Gateway row. They include requests the
  gateway answers itself, such as a 401 for a missing API key, and requests
  to Studio and pg-meta. The `admin` prefix is left out, because those
  requests are the metrics collector's own scrapes.
- **Response Speed** uses the time the services take. Studio shows the
  average time the origin takes to respond, and this panel shows the same
  average plus a 95th percentile. It reads the per-service times instead of
  the gateway's own time, because those are the times the origin takes.
  Requests the gateway rejects itself never reach a service, so they have no
  response time to count. Envoy records no response time for Realtime's
  WebSocket requests, so Realtime is left out.
- **Network Traffic** counts the bytes on the connections between the
  gateway and the five services, headers included. Studio counts only the
  `Content-Length` of requests and responses, so the numbers here are larger.  
  Studio shows only ingress. It notes that egress is billable and links to
  the organization's Usage page for it. A self-hosted stack has no Usage
  page, so this panel shows both, with egress below the axis.

### By service

The second row repeats the four charts with one series for each service, in
the order and with the names the Overview uses.

| Panel | Metric |
|---|---|
| Total Requests by service | `envoy_cluster_upstream_rq_total{envoy_response_code=""}` |
| Response Errors by service | `envoy_cluster_upstream_rq_xx_total` for status classes 4 and 5 |
| Response Speed by service | `envoy_cluster_upstream_rq_time_sum` divided by `envoy_cluster_upstream_rq_time_count`, without Realtime |
| Network Traffic by service | `envoy_cluster_upstream_cx_tx_bytes_total` and `envoy_cluster_upstream_cx_rx_bytes_total` |

`envoy_cluster_upstream_rq_total` needs `envoy_response_code=""`. Envoy
also writes one series with that name for each response code, and the
filter keeps only the series that counts every request, so each request is
counted once. The `meta` and `studio` clusters are left out, because Studio
does not list them as services. Requests to those two clusters, and the
gateway's own 401 and 403 responses, are counted only in Total Requests and
Response Errors in the first row.

## Known limitations

See [known-limitations.md](known-limitations.md).
