# Dashboards

Grafana shows what the logs and metrics stacks collect. This page covers the
dashboards this repo ships, what to look at when an Overview panel turns red,
and how Grafana loads them. To start Grafana, see
[Start Grafana](../README.md#start-grafana).

## Open the Overview

Open <http://127.0.0.1:3000/d/supabase-overview> and log in as `admin` with
the `GRAFANA_ADMIN_PASSWORD` from `.env`. In Grafana's menu it is under
**Dashboards > Supabase > Overview**.

The dashboard shows the last hour by default and refreshes every minute. It
reads only from the metrics store, so the metrics stack has to be running.
See [Start metrics](../README.md#start-metrics).

## What the Overview shows

The Overview follows the Observability Overview page in Supabase Studio.
[studio-alignment.md](studio-alignment.md) lists where it matches Studio and
where it differs.

| Row | What it answers |
|---|---|
| Needs attention | Is anything wrong right now? Each panel turns red at the threshold of one of Supabase's [detection checks](https://supabase.com/docs/guides/observability/detecting), or at a threshold that matters when you run the stack yourself. |
| Database | How busy is Postgres, and how close are its connections and replication slots to their limits? Connections by role, database size, rollbacks, cache hits, deadlocks and replication slot headroom. |
| Service health | Which service is failing? Requests, error rate, 95th percentile latency and status for each service behind the gateway, plus a bar chart of responses by status class for each one. |

## Open the API Gateway dashboard

Open <http://127.0.0.1:3000/d/supabase-gateway>, or select **API Gateway
dashboard** in the menu of the API Gateway bar chart or the Service health
table on the Overview. It is in the same **Supabase** folder.

The dashboard follows the API Gateway page in Supabase Studio.
[studio-alignment.md](studio-alignment.md#api-gateway-dashboard) lists where
it matches Studio and where it differs.

| Row | What it answers |
|---|---|
| API Gateway | How many requests does the gateway answer, how many fail, how fast are the services, and how much data goes through? Total Requests, Response Errors, Response Speed and Network Traffic for the whole gateway. |
| By service | Which service do the requests, errors, slow responses or traffic come from? The same four charts with one series for each service. |

If Response Errors shows 4xx responses that no service shows under
**Response Errors by service**, the gateway rejected those requests itself,
or they went to Studio or pg-meta, which the second row leaves out. A
rejected request usually means a client sends a missing or wrong API key.
[Request fails, but the service shows nothing](../logs/troubleshooting.md#request-fails-but-the-service-shows-nothing)
shows how to find those requests in the gateway's logs.

## When a panel turns red

| Panel | What to look at first |
|---|---|
| Targets down | Run the query `up == 0` in VictoriaMetrics to see which job failed, then follow [Troubleshooting: a metrics job shows 0 or is missing](../metrics/README.md#troubleshooting-a-metrics-job-shows-0-or-is-missing). |
| API server errors (1h) | Find the service whose bar chart under **Service health** shows 5xx responses, then read that service's logs. [Finding the actual error when your app breaks](../logs/troubleshooting.md) has a section for each common case. |
| Auth server errors (1h) | Read the Auth logs. [Sign-in fails with no useful detail](../logs/troubleshooting.md#sign-in-fails-with-no-useful-detail) covers the usual causes. |
| Connection pressure | Check which role grows in **Database Connections**. If Postgres or Other roles grows, connect those clients through the pooler instead of directly. PostgREST opens at most a fixed number of connections, set by its pool size. If Reserved (`supabase_admin`) grows, those connections belong to Supabase's own services, such as Realtime and the pooler. |
| Longest open transaction | List the open transactions in Postgres, oldest first, as shown below. |
| Inactive replication slots | List the slots, as shown below. Realtime and logical replication create slots of their own, so find out what a slot belongs to before you drop it. |
| Deadlocks | Read the Postgres logs. Each deadlock is logged with the statements involved. |

To list open transactions, oldest first:

```bash
docker exec supabase-db psql -U supabase_admin -d postgres -c \
  "select pid, usename, application_name, state, now() - xact_start as age, left(query, 80) as query
   from pg_stat_activity
   where xact_start is not null
   order by xact_start
   limit 10;"
```

To list replication slots and how much WAL each one keeps:

```bash
docker exec supabase-db psql -U supabase_admin -d postgres -c \
  "select slot_name, slot_type, active, wal_status,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as retained_wal
   from pg_replication_slots;"
```

## How Grafana loads the dashboards

Grafana reads these files from `config/dashboards/`.

| File | What it does |
|---|---|
| `grafana-provider.yaml` | Tells Grafana to load every dashboard file from one folder in the container and put the dashboards in the **Supabase** folder. |
| `overview.json` | The Overview dashboard. |
| `gateway.json` | The API Gateway dashboard. |

`docker-compose.o11y-dashboards.yml` mounts each file at a fixed path, the
same way it mounts the datasource files.

The dashboards are read-only in Grafana, so the JSON files in this repo stay
the only copies. To change a dashboard, edit its JSON file and restart
Grafana:

```bash
docker restart supabase-observability-grafana
```

The restart is needed because each file is mounted on its own. When an editor
or `git` replaces the file instead of writing into it, the container keeps
seeing the old file until it restarts.

## Known limitations

See [known-limitations.md](known-limitations.md).
