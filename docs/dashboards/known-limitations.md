# Dashboards known limitations

Charts that Supabase Studio has and these dashboards do not, and charts whose
numbers are worked out in a different way from Studio's, with the reason for
each.

## Things left out of the dashboards

Each row is something Supabase Studio shows, or a check that this stack could
make, that the dashboards cannot show.

| Item left out | Why it is not in the dashboards |
|---|---|
| CPU and memory usage | These need host and container metrics, which are not among the [metrics this stack collects](../metrics/README.md#what-gets-scraped) yet. |
| Free space on the disk | Studio's Disk Usage shows how full the disk is, which needs host metrics. The Overview shows only the size of the `postgres` database, in **Database size**. |
| Disk IO balance | This is the burst balance of the managed platform's disks. Self-hosted disks have no equivalent value. |
| Slow queries | A slow queries panel needs `pg_stat_statements` queries in postgres-exporter. Studio's **Query Performance** page, under Observability, lists slow queries on self-hosted Supabase as well. |
| Database in the **Service health** table | Studio builds this row from Postgres log events by severity, and the Overview reads only metrics. |
| 401 and 403 failures | The gateway's own totals group responses only by class, so 401 and 403 cannot be told apart from 404. |
| Sessions that block other sessions | postgres-exporter has no metric for blocking sessions. Studio's **Database Connections** page, under Observability, shows them live on self-hosted Supabase as well. |
| Storage in **Targets down** | Storage pushes its metrics instead of being scraped, so it has no `up` series. |
| Auth Activity (Auth dashboard) | Studio counts distinct users from Auth's logs, and Auth's metrics have no user. |
| Sign-in types (Auth dashboard) | The sign-in type is the request's `grant_type` parameter, which neither Auth's metrics nor Envoy's metrics record, so **Sign In Attempts** cannot split password, PKCE, refresh token and ID token sign-ins the way Studio does. |
| Auth Errors by Code (Auth dashboard) | The error code is only in a response header, which neither Envoy's metrics nor Auth's metrics carry. The dashboard shows **Auth Errors by Route** instead. |
| Add filter (Auth dashboard) | Studio filters the Auth API Gateway charts with fields from its request logs. Envoy's metrics have no request path or other log fields, so the dashboard has no filter. |
| Provider filter (Auth dashboard) | Studio filters the Usage charts by sign-in provider from Auth's logs, and Auth's metrics have no provider. |
| Top routes (Auth dashboard) | Envoy's metrics have no request path, so the Auth API Gateway row cannot list the busiest, failing or slowest routes the way Studio does. |

## Numbers that differ from Studio's or from Supabase's detection checks

| Panel | What differs, and from what |
|---|---|
| Request counts and error rates | Studio counts every request in its logs. Envoy creates the counter for a status class the first time a service returns a response of that class. VictoriaMetrics counts the counter's first reading in `increase()` only when the reading is small compared with how fast the counter grows afterwards. For example, 9 responses before the first scrape are counted, but 15 are not when no more follow. `rate()` always needs two readings, so it never counts the first one. This can happen once for each service and status class after Envoy starts. |
| API server errors (1h), Auth server errors (1h) | Supabase's detection check also asks for at least 20 errors and at least twice the rate of the hour before. A single panel cannot compare two hours, so the panels apply only the 1% rate and the 100-request minimum. |
| Longest open transaction | The panel measures from the start of the transaction. Supabase's detection check measures an active query from the start of the query. |
| Sign Ups (Auth dashboard) | Studio counts a sign-up when Auth records a confirmed new user, including users who sign up through an OAuth provider, SSO, an invite or the admin API. The panel counts successful requests to `/signup`, so with email confirmation on, which is the default, it also counts sign-ups that are never confirmed, and it leaves out the other ways of signing up. |
| Password Reset Requests (Auth dashboard) | Studio counts Auth's recovery events, which Auth records only for existing users, including magic links and one-time codes sent to them. The panel counts successful requests to `/recover`, which also include requests for an email address that has no account. |
| Total Requests and Response Errors (Auth dashboard) | Studio counts every request to an `/auth` path in the gateway's logs. The panels count only the requests that reached Auth, so requests the gateway rejected itself are not included. |
| Sign In Processing Time (Auth dashboard) | The panel times every successful request to `/token`, including token refreshes, which are faster than a password check, so its average is lower than Studio's. It shows percentiles where Studio shows the minimum and maximum. |
| Response Speed (Auth dashboard) | The panel does not count requests the gateway rejected itself, because they never reach Auth and so have no response time. |
| Network Traffic (Auth dashboard) | The panel counts every byte on the connection between the gateway and Auth, headers included. Studio's chart shows ingress only, as the sum of the `Content-Length` header of each request, so the panel's numbers are larger. |
