SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --warn-undefined-variables --no-builtin-rules
.SUFFIXES:

.DEFAULT_GOAL := help

COMPOSE_LOGS := docker compose -f docker-compose.o11y-logs.yml
COMPOSE_METRICS := docker compose -f docker-compose.o11y-metrics.yml

.PHONY: help up-logs down-logs verify-logs restart-vector up-metrics down-metrics generate-metrics-secrets

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*## "}; {printf "  %-16s %s\n", $$1, $$2}'

up-logs: ## Start the log pipeline (backend set by BACKEND_LOGS in .env)
	$(COMPOSE_LOGS) up -d

down-logs: ## Stop the log pipeline
	$(COMPOSE_LOGS) down

verify-logs: ## Check that every routed service is reaching the log store
	scripts/verify-logs.sh

restart-vector: ## Restart Vector after a config change, then show its startup log
	$(COMPOSE_LOGS) restart vector
	sleep 2
	docker logs supabase-observability-vector --tail 20

up-metrics: generate-metrics-secrets ## Start the metrics pipeline (backend set by BACKEND_METRICS in .env)
	$(COMPOSE_METRICS) up -d

generate-metrics-secrets:
	scripts/generate-metrics-secrets.sh

down-metrics: ## Stop the metrics pipeline
	$(COMPOSE_METRICS) down
