# Supabase Observability

Community-maintained, vendor-neutral observability for a
[Supabase](https://github.com/supabase/supabase) instance running self-hosted —
logs, metrics, and (where upstream emits them) traces through a single
OpenTelemetry pipeline, surfaced in a purpose-built Grafana dashboard set.

For any information regarding Supabase itself you can refer to the
[official documentation](https://supabase.com/docs).

## What this adds

Self-hosted already ships logs via Vector. This project adds metrics
collection, dashboards, and correlation between the two — as one pipeline.

Default stack: Grafana · VictoriaMetrics · VictoriaLogs · Vector · OpenTelemetry
Collector. Every backend is swappable by editing one file under `exporters/`.

## How to use ?

You can find the documentation inside the [docs directory](docs/quick-start/README.md).

# Roadmap

- [ ] Core log path
- [ ] Metrics plane
- [ ] Dashboards
- [ ] Alerting
- [ ] Kubernetes

## Support

This project is supported by the community and not officially supported by
Supabase. Please do not create any issues on the official Supabase repositories
if you face any problems using this project, but rather open an issue on this
repository.

## Contributing

You can contribute to this project by forking this repository and opening a
pull request. See [docs/quick-start](docs/quick-start/README.md) for local setup.

## License

[Apache 2.0 License.](LICENSE)
