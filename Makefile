## Version 0.4.5
.PHONY: help up down restart logs ps pull check init check-env gpu-check verify health healthcheck test check-updates

SHELL := /bin/bash

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

init: ## First-run setup: .env, data directories, permissions
	@./scripts/init.sh

up: ## Start everything and remove orphan containers
	docker compose up -d --remove-orphans

down: ## Stop everything
	docker compose down

restart: ## Restart every service
	docker compose restart

logs: ## Follow logs from every service
	docker compose logs -f --tail=50

verify: ## Compare declared image tags against the running containers
	@echo "🔍 Repository <-> runtime alignment..."
	@echo "------------------------------------------------------------------------------------------------"
	@printf "%-25s %-40s %-40s %s\n" "SERVICE" "DECLARED (repo)" "RUNNING (docker)" "STATE"
	@echo "------------------------------------------------------------------------------------------------"
	@comm --output-delimiter='|' \
		<(docker compose config --format json | jq -r '.services | to_entries[] | "\(.key) \(.value.image)"' | sort) \
		<(docker compose ps --format json | jq -r 'if type=="array" then .[] else . end | "\(.Service // .service) \(.Image // .image)"' | sort -u) \
		| awk -F'|' '{ \
			if ($$3 != "") { split($$3, a, " "); printf "%-25s %-40s %-40s ✅ OK\n", a[1], a[2], a[2] } \
			else if ($$2 != "") { split($$2, a, " "); printf "%-25s %-40s %-40s ❌ MISMATCH\n", a[1], "N/A", a[2] } \
			else { split($$1, a, " "); printf "%-25s %-40s %-40s ⚪ STOPPED\n", a[1], a[2], "-" } \
		}'

ps: ## Status of running services
	docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

pull: ## Pull updated images without starting anything
	docker compose pull

check: check-env ## Validate prerequisites and compose configuration
	@echo "Docker:  $$(docker --version)"
	@echo "Compose: $$(docker compose version)"
	@echo ""
	@docker compose config --quiet && echo "✅ Compose configuration is valid" || echo "❌ Invalid compose configuration"
	@echo ""
	@if [ -f .env ]; then \
		n=$$(grep -c "CHANGE_ME" .env || true); \
		if [ "$$n" -gt 0 ]; then \
			echo "⚠️  $$n CHANGE_ME values still to replace in .env"; \
		else \
			echo "✅ No CHANGE_ME left"; \
		fi; \
	fi

check-env: ## Check .env against .env.example for drift
	@bash scripts/check-env.sh

gpu-check: ## Check for an NVIDIA GPU
	@nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
		&& echo "GPU_OK" || echo "GPU_MISSING"

test: ## Offline suite: lint, syntax, JSON/YAML, secrets, unit tests
	@./scripts/run-tests.sh

healthcheck: ## End-to-end check: health endpoints + data fingerprint (pre/post update)
	@./scripts/healthcheck.sh $(SERVICE)

health: ## Show only containers that are not healthy
	@docker compose ps --format "table {{.Name}}\t{{.Status}}" \
		| grep -iE "restarting|exited|dead|unhealthy|created|paused|starting" \
		|| echo "✅ Every container is healthy"

check-updates: ## Build the service manifest and check for new releases
	@python3 ./scripts/check_updates.py
