# Contributing

Early-stage repo - the structure is still moving, so open an issue before
starting anything sizeable. Small fixes are welcome without one.

## Ground rules

- Never modify files under your Supabase `docker/` directory. Compose
  overrides and runtime mechanisms only.
- Verify parser behavior against real captured log lines in `vector vrl`
  before claiming it works.

Working on the pipeline itself and need `vector top`/`vrl`/`tap`? See
[docs/log-debugging.md](docs/log-debugging.md).

## Before opening a PR

```bash
bash -n scripts/*.sh
docker exec supabase-observability-vector vector validate \
  --no-environment /etc/vector/base.yaml /etc/vector/backend.yaml
make verify-logs
```

Group commits by feature, not by file.

## License

Contributions are under [Apache 2.0](LICENSE).
