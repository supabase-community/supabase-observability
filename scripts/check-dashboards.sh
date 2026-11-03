#!/usr/bin/env bash
# Checks the dashboards in config/dashboards/: every query must use the
# metrics datasource (uid prometheus) and parse as PromQL. promtool from the
# Prometheus image does the parsing, so this needs Docker and python3.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

rules=$(mktemp)
trap 'rm -f "$rules"' EXIT
# promtool runs as nobody inside the container, so it needs read access.
chmod 644 "$rules"

python3 - config/dashboards/*.json > "$rules" <<'PY' || exit 1
import json
import sys


def panels(items):
    for panel in items:
        yield panel
        yield from panels(panel.get("panels", []))


print("groups:\n  - name: dashboards\n    rules:")
n = 0
for path in sys.argv[1:]:
    with open(path) as f:
        dashboard = json.load(f)
    for panel in panels(dashboard["panels"]):
        for target in panel.get("targets", []):
            uid = target.get("datasource", {}).get("uid")
            if uid != "prometheus":
                sys.exit(f"{path}: panel {panel.get('title')!r} uses datasource {uid!r}, not 'prometheus'")
            expr = target["expr"]
            for var in ("$__rate_interval", "$__interval", "$__range"):
                expr = expr.replace(var, "5m")
            n += 1
            print(f"      - record: dashboard_query_{n}")
            print(f"        expr: {json.dumps(expr)}")
PY

docker run --rm -v "$rules:/rules.yml:ro" --entrypoint promtool \
  prom/prometheus:v3.5.0 check rules /rules.yml
