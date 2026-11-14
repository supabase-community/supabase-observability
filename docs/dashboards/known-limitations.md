# Dashboards known limitations

What the dashboards do not show or count differently, and why.

## Not shown

| Item | Reason |
|---|---|
| CPU and memory usage | These need host and container metrics, which are not among the [metrics this stack collects](../metrics/README.md#what-gets-scraped) yet. |
| Free space on the disk | Studio's Disk Usage shows how full the disk is, which needs host metrics. The Overview shows only the size of the `postgres` database, in **Database size**. |
| Disk IO balance | This is the burst balance of the managed platform's disks. Self-hosted disks have no equivalent value. |
| Slow queries | This needs `pg_stat_statements` queries in postgres-exporter. |
| Database in the **Service health** table | Studio builds this row from Postgres log events by severity, and the Overview reads only metrics. |
| 401 and 403 failures | The gateway's own totals group responses only by class, so 401 and 403 cannot be told apart from 404. |
| Sessions that block other sessions | postgres-exporter has no metric for them. |
| Storage in **Targets down** | Storage pushes its metrics instead of being scraped, so it has no `up` series. |
| Requests by Geography (API Gateway) | Studio takes the country from Cloudflare, and a self-hosted gateway has no country for a request. |
| Top routes (API Gateway) | Envoy's metrics have no request path, so the API Gateway dashboard cannot list the busiest, failing or slowest routes the way Studio does. |
| Realtime in **Response Speed** (API Gateway) | Envoy records no response time for WebSocket requests, so there is nothing to chart for Realtime. |
| Kong gateway | The Overview's **Service health** row and the API Gateway dashboard read Envoy's metrics, so they stay empty when you run the Kong override. Upstream has marked Kong for removal and recommends Envoy. |


## Counted differently

| Panel | Difference |
|---|---|
| Request counts and error rates | Envoy creates the counter for a status class the first time a service returns a response of that class. Requests counted before the counter's first scrape do not show up in `increase()` or `rate()`. This happens once for each service and status class after Envoy starts. |
| API server errors (1h), Auth server errors (1h) | The detection check also asks for at least 20 errors and at least twice the rate of the hour before. A single panel cannot compare two hours, so the panels apply only the 1% rate and the 100-request minimum. |
| Longest open transaction | It measures from the start of the transaction. The detection check measures an active query from the start of the query. |
| Response Speed (API Gateway) | It does not count requests the gateway rejected itself, because those never reach a service. |
| Network Traffic (API Gateway) | It counts every byte on the connections between the gateway and the services, headers included. Studio counts only the `Content-Length` of requests and responses. |
