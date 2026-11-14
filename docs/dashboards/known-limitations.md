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
| Slow queries | This needs `pg_stat_statements` queries in postgres-exporter. |
| Database in the **Service health** table | Studio builds this row from Postgres log events by severity, and the Overview reads only metrics. |
| 401 and 403 failures | The gateway's own totals group responses only by class, so 401 and 403 cannot be told apart from 404. |
| Sessions that block other sessions | postgres-exporter has no metric for them. |
| Storage in **Targets down** | Storage pushes its metrics instead of being scraped, so it has no `up` series. |
| Auth Activity (Auth dashboard) | Studio counts distinct users from Auth's logs, and Auth's metrics have no user. |
| Sign-in types (Auth dashboard) | The sign-in type is in the request body, so **Sign In Attempts** cannot split password, PKCE, refresh token and ID token sign-ins the way Studio does. |
| Auth Errors by Code (Auth dashboard) | The error code is only in a response header, which neither Envoy's metrics nor Auth's metrics carry. The dashboard shows **Auth Errors by Route** instead. |
| Add filter (Auth dashboard) | Studio filters the Auth API Gateway charts with fields from its request logs. Envoy's metrics have no request path or other log fields, so the dashboard has no filter. |

## Numbers that differ from Studio's or from Supabase's detection checks

| Panel | What differs, and from what |
|---|---|
| Request counts and error rates | Studio counts every request in its logs. Envoy creates the counter for a status class the first time a service returns a response of that class, so requests counted before the counter's first scrape do not show up in `increase()` or `rate()`. This happens once for each service and status class after Envoy starts. |
| API server errors (1h), Auth server errors (1h) | Supabase's detection check also asks for at least 20 errors and at least twice the rate of the hour before. A single panel cannot compare two hours, so the panels apply only the 1% rate and the 100-request minimum. |
| Longest open transaction | The panel measures from the start of the transaction. Supabase's detection check measures an active query from the start of the query. |
| Sign Ups (Auth dashboard) | Studio counts every new user. The panel counts successful requests to `/signup`, so users who sign up through an OAuth provider, SSO or an invite are not counted. |
| Sign In Processing Time (Auth dashboard) | The panel times every successful request to `/token`, including token refreshes, which are faster than a password check, so its average is lower than Studio's. It shows percentiles where Studio shows the minimum and maximum. |
| Response Speed (Auth dashboard) | The panel does not count requests the gateway rejected itself, because they never reach Auth and so have no response time. |
| Network Traffic (Auth dashboard) | The panel counts every byte on the connection between the gateway and Auth, headers included. Studio counts only the `Content-Length` of requests and responses, so the panel's numbers are larger. |
