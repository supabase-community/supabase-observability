# Supabase Observability

Community-maintained observability for self-hosted
[Supabase](https://github.com/supabase/supabase). Metrics, logs, and traces
collected into open-source backends. Grafana dashboards built around the
Supabase services are planned - see [Status](#status) for what ships today.

For anything about Supabase itself, see the
[official documentation](https://supabase.com/docs).

## Why this exists

Supabase Cloud has a strong observability story: a Metrics API, a Logs
Explorer, and Log Drains. Self-hosting trades that platform layer for control
over your own infrastructure, and this project fills it back in with
open-source components you run yourself.

## Status

| Signal | State | Default components |
| --- | --- | --- |
| [Logs](docs/logs.md) | Available | Vector into VictoriaLogs, or Loki |
| Metrics | Planned | OpenTelemetry Collector into VictoriaMetrics |
| Traces | Planned | OpenTelemetry Collector, OTLP |
| Dashboards | Planned | Grafana |
| Alerting | Planned | vmalert, Alertmanager |
| Kubernetes | Planned | Helm chart |

Start here: [docs/README.md](docs/README.md)

## How it runs

```
your machine
├── supabase/docker/
│     └── docker-compose.yml
└── supabase-observability/
      └── docker-compose.o11y-logs.yml
                │
                └── reads container logs via the Docker socket
```

`supabase/docker/` is your existing Supabase deployment and stays untouched.
`supabase-observability/` is this project, its own Compose project.

Logs, metrics, and traces are each a separate Compose file inside this
project, so you run only the ones you want. This repo currently ships the
logs one (`docker-compose.o11y-logs.yml`); metrics and traces will each add
their own when they land, and you'll bring them up the same way, alongside
whichever ones you already have running.

## Replaceable backends

Each signal's storage and visualization backend is chosen with one
environment variable and one config file, separate from the collection
logic itself. For logs, that's `BACKEND_LOGS` (`victorialogs` or `loki`) -
see [docs/logs.md](docs/logs.md#configure). Point a signal at the default
backend, or at infrastructure you already operate.

## Support

Community-maintained, and separate from Supabase's official support. Please
open issues on this repository rather than the Supabase repositories.

## Contributing

Fork the repository and open a pull request. See
[CONTRIBUTING.md](CONTRIBUTING.md) for ground rules and pre-PR checks, and
[docs/README.md](docs/README.md) for local setup.

## License

[Apache 2.0](LICENSE)
