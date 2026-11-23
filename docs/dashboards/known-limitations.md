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
| Requests by Geography (API Gateway dashboard) | Studio maps each request to its country from its request logs. Envoy's metrics carry no country. |
| Top routes (API Gateway dashboard) | Envoy's metrics have no request path, so the API Gateway dashboard cannot list the busiest, failing or slowest routes the way Studio does. |
| Kong gateway | The Overview's **Service health** row and the API Gateway dashboard read Envoy's metrics, so they stay empty when you run the Kong override. Supabase has marked the Kong override for removal in a future release, and Envoy is the default gateway. |

## Numbers that differ from Studio's or from Supabase's detection checks

| Panel | What differs, and from what |
|---|---|
| Request counts and error rates | Studio counts every request in its logs. Envoy creates the counter for a status class the first time a service returns a response of that class. VictoriaMetrics counts the counter's first reading in `increase()` only when the reading is small compared with how fast the counter grows afterwards. For example, 9 responses before the first scrape are counted, but 15 are not when no more follow. `rate()` always needs two readings, so it never counts the first one. This can happen once for each service and status class after Envoy starts. |
| API server errors (1h), Auth server errors (1h) | Supabase's detection check also asks for at least 20 errors and at least twice the rate of the hour before. A single panel cannot compare two hours, so the panels apply only the 1% rate and the 100-request minimum. |
| Longest open transaction | The panel measures from the start of the transaction. Supabase's detection check measures an active query from the start of the query. |
| Response Speed (API Gateway dashboard) | The panel does not count requests the gateway rejected itself, because they never reach a service and so have no response time. Realtime's response time covers only its HTTP API requests, such as broadcasts sent over REST, because Envoy records no response time for WebSocket connections. |
| Network Traffic (API Gateway dashboard) | The panel counts every byte on the connections between the gateway and the services, headers included. Studio's chart shows ingress only, as the sum of the `Content-Length` header of each request, so the panel's numbers are larger. |
