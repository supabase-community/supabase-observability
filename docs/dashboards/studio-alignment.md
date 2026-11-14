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

The data behind the table is different from Studio's.

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

## Auth dashboard

Grafana loads the dashboard from `config/dashboards/auth.json`. It follows the
Auth page in Studio's Observability section and uses that page's chart names.
Studio builds that page from Auth's logs and the gateway's request logs. This
dashboard reads Auth's own metrics, which the metrics stack
[scrapes from Auth's metrics port](../metrics/README.md#what-gets-scraped),
and the Envoy gateway's metrics for the `auth` cluster, so it works with any
Prometheus-compatible metrics backend.

Auth's metrics count requests by endpoint, in `http_route`. Each chart below
counts the requests to the endpoint that does that job. Auth's logs record
each event with its type and its user, so Studio's user counts and its split
by sign-in type cannot be reproduced from metrics.

### Usage

| Studio | This dashboard | Metric |
|---|---|---|
| Auth Activity | Not shown | Studio counts distinct users from Auth's logs, and Auth's metrics have no user. |
| Sign In Attempts by Type | Sign In Attempts, split into succeeded and failed | `http_status_codes_total{http_route="/token"}` |
| Sign Ups | Sign Ups | `http_status_codes_total{http_route="/signup"}` for 2xx status codes |
| Password Reset Requests | Password Reset Requests | `http_status_codes_total{http_route="/recover"}` for 2xx status codes |

- **Sign In Attempts** counts every request to `/token`, the endpoint that
  handles every sign-in type. Studio splits successful sign-ins by type, such
  as password, PKCE, refresh token and ID token. The type is in the request
  body and not in the metric, so this chart shows the succeeded and failed
  requests instead.
- **Sign Ups** counts successful requests to `/signup`. Studio counts every
  new user, including users who sign up through an OAuth provider, SSO or an
  invite, which do not use that endpoint.

### Monitoring

| Studio | This dashboard | Metric |
|---|---|---|
| API Gateway Auth Errors | API Gateway Auth Errors, with one series for each status code | `envoy_cluster_upstream_rq_total{envoy_cluster_name="auth"}` for status codes 400 to 599 |
| Auth Errors by Code | Auth Errors by Route, with one series for each Auth endpoint | `http_status_codes_total` for status codes 400 to 599, by `http_route` |

Studio reads the error code, such as `invalid_credentials`, from the
`x_sb_error_code` response header. Neither Envoy's metrics nor Auth's metrics
carry it, so **Auth Errors by Route** shows which endpoint failed instead.

Envoy creates the counter for a status code the first time Auth returns it, so
a code appears in **API Gateway Auth Errors** only after it has happened once
and been scraped. The 401 and 403 responses the gateway returns itself never
reach Auth, so they are not in this chart.

### Performance

| Studio | This dashboard | Metric |
|---|---|---|
| Sign In Processing Time, Sign In Processing Time Percentiles | Sign In Processing Time, as an average and the 50th, 95th and 99th percentiles | `http_server_request_duration_seconds{http_route="/token"}` for 2xx status codes |
| Sign Up Processing Time, Sign Up Processing Time Percentiles | Sign Up Processing Time, as an average and the 50th, 95th and 99th percentiles | `http_server_request_duration_seconds{http_route="/signup"}` for 2xx status codes |

- Studio shows the minimum and the maximum next to the average, and the
  percentiles in a second chart. A histogram keeps no minimum or maximum, so
  this dashboard shows the average and the percentiles in one chart.
- The percentiles are estimated inside the histogram's buckets, which Auth
  sets at 5, 10, 25, 50, 75, 100, 250 and 500 milliseconds and up.
- **Sign In Processing Time** includes token refreshes. A refresh does not
  check a password, so it is much faster than a sign-in, and the average is
  lower than Studio's when clients refresh their sessions often.
- The first requests after Auth starts, or after a route first returns a new
  status code, do not appear in these charts until more requests follow,
  because a rate needs two readings of the counter.

### Auth API Gateway

The fourth row has Studio's four charts for the requests that reach Auth.

| Studio | This dashboard | Metric |
|---|---|---|
| Total Requests | Total Requests | `envoy_cluster_upstream_rq_total{envoy_cluster_name="auth",envoy_response_code=""}` |
| Response Errors | Response Errors, split into 4xx and 5xx | `envoy_cluster_upstream_rq_xx_total{envoy_cluster_name="auth"}` for status classes 4 and 5 |
| Response Speed | Response Speed, as an average and a 95th percentile | `envoy_cluster_upstream_rq_time_sum`, `envoy_cluster_upstream_rq_time_count` and `envoy_cluster_upstream_rq_time_bucket` for `auth` |
| Network Traffic | Network Traffic, as ingress and egress | `envoy_cluster_upstream_cx_tx_bytes_total` for ingress and `envoy_cluster_upstream_cx_rx_bytes_total` for egress, for `auth` |

`envoy_cluster_upstream_rq_total` needs `envoy_response_code=""`. Envoy also
writes one series with that name for each response code, and the filter keeps
only the series that counts every request, so each request is counted once.

The numbers differ from Studio's in these ways.

- **Response Speed** shows the average that Studio shows, plus a 95th
  percentile. Requests the gateway rejects itself never reach Auth, so they
  have no response time to count.
- **Network Traffic** counts the bytes on the connection between the gateway
  and Auth, headers included. Studio counts only the `Content-Length` of
  requests and responses, so the numbers here are larger. Studio shows only
  ingress. It notes that egress is billable and links to the organization's
  Usage page for it. A self-hosted stack has no Usage page, so this panel
  shows both, with egress below the axis.

### Auth server

The last row has no counterpart on Studio's Auth page. It reads Auth's own
metrics.

| Panel | Metric |
|---|---|
| Emails | `global_auth_email_send_operations_total` and `global_auth_email_send_errors_total` |
| Email Rate Limit Hits | `gotrue_email_rate_limit_counter_total`, by `path` |
| Database Query Time | `db_sql_latency_milliseconds_sum`, `db_sql_latency_milliseconds_count` and `db_sql_latency_milliseconds_bucket` |

- **Emails** counts attempts. A failed email is in both Attempted and Failed,
  so the number of emails that went out is Attempted minus Failed.
- Auth's connection gauges read zero whenever no query is running at the
  moment Auth is scraped, so they say little about load. The dashboard shows
  how long queries take instead.

## Known limitations

See [known-limitations.md](known-limitations.md).
