# Supabase Observability

Community-maintained observability for self-hosted
[Supabase](https://github.com/supabase/supabase). Logs and metrics
collected into open-source backends. Traces and Grafana dashboards built
around the Supabase services are planned - see [Status](#status) for what
ships today.

For anything about Supabase itself, see the
[official documentation](https://supabase.com/docs).

## Why this exists

Supabase Cloud has a strong observability story: a Metrics API, a Logs
Explorer, and Log Drains. Self-hosting trades those for control over your
own infrastructure. This project brings logs and metrics back with
open-source components you run yourself.

## Status

| Signal | State | Default components |
| --- | --- | --- |
| [Logs](docs/logs/README.md) | Available | Vector into VictoriaLogs, or Loki |
| [Metrics](docs/metrics/README.md) | Available | OpenTelemetry Collector into VictoriaMetrics |
| Traces | Planned | OpenTelemetry Collector, OTLP |
| Dashboards | Planned | Grafana |
| Alerting | Planned | vmalert, Alertmanager |
| Kubernetes | Planned | Helm chart |

Start here: [docs/README.md](docs/README.md)

## How it runs

```
your machine
├── supabase/docker/                   your Supabase deployment
│     ├── docker-compose.yml
│     └── .env
│           └── COMPOSE_FILE           metrics only
│                 └── lists ─────────────────┐
│                                            │
└── supabase-observability/                  │
      ├── overrides/                         │
      │     ├── metrics.yml  ◄───────────────┤
      │     └── metrics-envoy.yml  ◄─────────┘
      │           └── turn Supabase's metrics endpoints on
      │
      ├── docker-compose.o11y-logs.yml
      │     └── reads container logs via the Docker socket
      │
      └── docker-compose.o11y-metrics.yml
            └── scrapes those endpoints
```

`supabase/docker/` is your existing Supabase deployment.
`supabase-observability/` is this project, its own Compose project.

Logs, metrics, and traces are each a separate Compose file inside this
project, so you run only the ones you want. This repo currently ships
logs and metrics; traces will add its own file when it lands, and you'll
bring it up the same way, alongside whichever ones you already have
running.

Logs reads Supabase's containers from the outside and needs nothing on
Supabase's side. Metrics can't work that way: several of Supabase's
metrics endpoints are off by default or listen only inside their own
container. So you register two override files from this
repo in `COMPOSE_FILE` in Supabase's `.env` - a file Supabase's own git
ignores. This project never writes to anything under `supabase/docker/`
itself. See [docs/metrics/README.md](docs/metrics/README.md#enable-metrics-on-supabases-side).

## Replaceable backends

Each signal's store is chosen with one environment variable naming a
folder under `config/<signal>/backends/`, separate from the collection
logic itself. That folder holds everything the store needs: its
container, where the collector sends data, and the store's own config.
For logs, that's `BACKEND_LOGS` (`victorialogs` or `loki`) - see
[docs/logs/README.md](docs/logs/README.md#configure). For metrics, it's
`BACKEND_METRICS` (`victoriametrics`) - see
[docs/metrics/README.md](docs/metrics/README.md#configure).

## Support

Community-maintained, and separate from Supabase's official support. Please
open issues on this repository rather than the Supabase repositories.

## Contributing

Fork the repository and open a pull request. See
[CONTRIBUTING.md](CONTRIBUTING.md) for ground rules and pre-PR checks, and
[docs/README.md](docs/README.md) for local setup.

## License

[Apache 2.0](LICENSE)