# Quick start

## Prerequisites

| Requirement | Note |
| --- | --- |
| A running self-hosted Supabase instance | The `supabase/docker` directory, already up |
| Docker Compose v2 | |
| bash 4 or newer | `scripts/verify-logs.sh` and `scripts/set-log-levels.sh` use `declare -A` and `mapfile`. macOS ships bash 3.2 - see [Platform notes](logs.md#platform-notes) |
| `curl`, `jq` | Used by `scripts/verify-logs.sh` to query the log store |
| `make` | Optional, every command below has a plain Compose equivalent |

This stack binds two ports on localhost: `9428` for VictoriaLogs, or `3100`
for Loki, depending on which backend you choose. Neither should conflict
with anything Supabase itself uses.

## Setup

```bash
git clone <this-repo>
cd supabase-observability
cp .env.example .env
```

Edit `.env`. At minimum:

| Variable | Value |
| --- | --- |
| `SUPABASE_DIR` | Absolute path to your Supabase `docker/` directory (the folder containing Supabase's own `docker-compose.yml`) |

Example:

```bash
SUPABASE_DIR=/home/you/supabase/docker
```

If you cloned Supabase with `git clone --depth 1 https://github.com/supabase/supabase`
and ran the quickstart from inside it, this is `<that clone>/docker`.

**Which gateway are you running?** Envoy ships in upstream's base compose;
Kong is added as an override. Either works here, detected at runtime, but
it's worth knowing which one you have before you start:

```bash
docker ps --format '{{.Names}}' | grep -E 'supabase-(kong|envoy)'
```

## Start logs

```bash
make up-logs
# verify-logs briefly restarts rest and db to raise their log levels -
# see below before running
make verify-logs
```

Two things worth knowing about the second command before you run it:

- It **restarts your Supabase `rest` and `db` containers** to temporarily
  raise their log levels, confirms logs are flowing, then restarts them
  again to put the levels back. It prompts before doing so.
- A `✓` in its output means that service reached the log store, not that
  every field got parsed. See [log-fields.md](log-fields.md) if a query
  later returns less than you expect.

Full walkthrough, including what to do if it doesn't pass:
[logs.md](logs.md)

## Stopping

```bash
make down-logs
```

Stops the log pipeline and keeps what's already stored. To also delete
stored logs, or to put any log levels you changed back to Supabase's
defaults, see [Stopping and removing](logs.md#stopping-and-removing).

## Confirming nothing upstream was touched

This project's one hard rule is that it never modifies files under your
Supabase `docker/` directory - only Compose overrides and runtime
mechanisms. You can confirm that directly:

```bash
git -C "$SUPABASE_DIR/.." status --short
```

Nothing from this stack should appear here, before or after running it.

## Idle resource use

With one backend running and no traffic, measured with
`docker stats --no-stream`:

| Container | CPU | Memory |
| --- | --- | --- |
| `supabase-observability-vector` | 0.10% | 21.3MiB |
| `supabase-observability-victorialogs` | 0.27% | 6.7MiB |

Loki in place of VictoriaLogs:

| Container | CPU | Memory |
| --- | --- | --- |
| `supabase-observability-vector` | 0.02% | 21.3MiB |
| `supabase-observability-loki` | 0.53% | 34.8MiB |

Both combinations stay well under 150MB total.

## Other documents

| Document | Read it when |
| --- | --- |
| [logs.md](logs.md) | Setting up, starting, or confirming logs are flowing |
| [log-levels.md](log-levels.md) | A service is silent, or too loud |
| [log-fields.md](log-fields.md) | A query returns nothing you expected |
| [log-troubleshooting.md](log-troubleshooting.md) | Your app broke and you need the real error |
| [log-debugging.md](log-debugging.md) | You're working on the pipeline itself and need `vector top`/`vrl`/`tap` |
| [log-pipeline-internals.md](log-pipeline-internals.md) | You want to know why the log pipeline behaves the way it does |
| [log-known-limitations.md](log-known-limitations.md) | You want to know what's currently broken or incomplete in the log pipeline |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | You're opening a PR |
