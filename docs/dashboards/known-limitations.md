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

## Numbers that differ from Studio's or from Supabase's detection checks

| Panel | What differs, and from what |
|---|---|
| Request counts and error rates | Studio counts every request in its logs. Envoy creates the counter for a status class the first time a service returns a response of that class, so requests counted before the counter's first scrape do not show up in `increase()` or `rate()`. This happens once for each service and status class after Envoy starts. |
| API server errors (1h), Auth server errors (1h) | Supabase's detection check also asks for at least 20 errors and at least twice the rate of the hour before. A single panel cannot compare two hours, so the panels apply only the 1% rate and the 100-request minimum. |
| Longest open transaction | The panel measures from the start of the transaction. Supabase's detection check measures an active query from the start of the query. |
