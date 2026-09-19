# Security Policy

## Scope

This repository ships configuration, Compose files, and scripts — no images, no hosted service.

**In scope:** a flaw in this repo's own config or scripts — an override that exposes something it shouldn't, a script leaking a credential, a default that weakens a deployment.

**Not in scope:** anything in Supabase itself or in an upstream component (Vector, Loki, VictoriaLogs, VictoriaMetrics, Grafana) — please report those to their own projects. For Supabase, see https://hackerone.com/supabase (policy: https://supabase.com/.well-known/security.txt).

## Reporting

Found something sensitive? Please don't open a public issue for it. Email jbyun0101@gmail.com instead, or reach out on the supabase-community Discord.

Include the log backend you're using, the Supabase version, and steps to reproduce.

This is a community project maintained in spare time, so response times will vary — but every report gets read.