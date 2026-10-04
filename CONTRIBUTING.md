# Contributing

Early-stage repo - the structure is still moving, so open an issue before
starting anything sizeable. Small fixes are welcome without one.

## Ground rules

- Never modify files under your Supabase `docker/` directory. Compose
  overrides and runtime mechanisms only.
- Verify parser behavior against real captured log lines in `vector vrl`
  before claiming it works.

Working on the pipeline itself and need `vector top`/`vrl`/`tap`? See
[docs/logs/debugging.md](docs/logs/debugging.md).

## Before opening a PR

```bash
bash -n scripts/*.sh
docker exec supabase-observability-vector vector validate \
  --no-environment /etc/vector/base.yaml /etc/vector/backend.yaml
touch jwt
docker run --rm \
  -v "$PWD/config/metrics/otel-collector.yaml:/etc/otel/base.yaml:ro" \
  -v "$PWD/config/metrics/backends/victoriametrics/otel-collector-exporter.yaml:/etc/otel/backend.yaml:ro" \
  -v "$PWD/jwt:/etc/otel/jwt:ro" \
  otel/opentelemetry-collector-contrib:0.153.0 \
  validate --config=/etc/otel/base.yaml --config=/etc/otel/backend.yaml
make verify-logs
```

`touch jwt` keeps Docker from creating a directory at that path when the
file does not exist yet. CI runs the same validate command on every
metrics backend.

Group commits by feature, not by file.

## License

Contributions are under [Apache 2.0](LICENSE).
