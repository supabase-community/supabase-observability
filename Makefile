SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --warn-undefined-variables --no-builtin-rules
.SUFFIXES:

.DEFAULT_GOAL := help

COMPOSE_LOGS := docker compose -f docker-compose.o11y-logs.yml

.PHONY: help up-logs down-logs verify-logs restart-vector check-env

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*## "}; {printf "  %-16s %s\n", $$1, $$2}'

up-logs: check-env ## Start the log pipeline (backend set by BACKEND_LOGS in .env)
	$(COMPOSE_LOGS) up -d

down-logs: ## Stop the log pipeline, whichever backend is running
	$(COMPOSE_LOGS) --profile "*" down

verify-logs: check-env ## Check that every routed service is reaching the log store
	scripts/verify-logs.sh

restart-vector: check-env ## Restart Vector after a config change, then show its startup log
	$(COMPOSE_LOGS) restart vector
	sleep 2
	docker logs supabase-observability-vector --tail 20

check-env:
	@test -f .env || { \
	  echo "No .env found. Run: cp .env.example .env"; \
	  exit 1; \
	}
