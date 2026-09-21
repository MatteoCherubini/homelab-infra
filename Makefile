## Version 0.4.5
.PHONY: help up down restart logs ps pull check init check-env gpu-check verify health healthcheck test check-updates

SHELL := /bin/bash

help: ## Mostra questo help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

init: ## Setup iniziale: crea .env, directory e config
	@./scripts/init.sh

up: ## Avvia tutto e rimuove orfani
	docker compose up -d --remove-orphans

down: ## Ferma tutto
	docker compose down

restart: ## Restart di tutti i servizi
	docker compose restart

logs: ## Log live (tutti i servizi)
	docker compose logs -f --tail=50

verify: ## Confronta le versioni dichiarate con quelle in esecuzione
	@echo "🔍 Verifica allineamento Repo <-> Runtime..."
	@echo "------------------------------------------------------------------------------------------------"
	@printf "%-25s %-40s %-40s %s\n" "SERVIZIO" "DICHIARATO (Repo)" "ATTIVO (Docker)" "STATO"
	@echo "------------------------------------------------------------------------------------------------"
	@comm --output-delimiter='|' \
		<(docker compose config --format json | jq -r '.services | to_entries[] | "\(.key) \(.value.image)"' | sort) \
		<(docker compose ps --format json | jq -r 'if type=="array" then .[] else . end | "\(.Service // .service) \(.Image // .image)"' | sort -u) \
		| awk -F'|' '{ \
			if ($$3 != "") { split($$3, a, " "); printf "%-25s %-40s %-40s ✅ OK\n", a[1], a[2], a[2] } \
			else if ($$2 != "") { split($$2, a, " "); printf "%-25s %-40s %-40s ❌ DISALLINEATO\n", a[1], "N/A", a[2] } \
			else { split($$1, a, " "); printf "%-25s %-40s %-40s ⚪ FERMO\n", a[1], a[2], "-" } \
		}'

ps: ## Stato dei servizi attivi
	docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

pull: ## Scarica immagini aggiornate (senza avviare)
	docker compose pull

check: check-env ## Verifica prerequisiti e validità configurazioni
	@echo "Docker:  $$(docker --version)"
	@echo "Compose: $$(docker compose version)"
	@echo ""
	@docker compose config --quiet && echo "✅ Compose config valida" || echo "❌ Errore nella config"
	@echo ""
	@if [ -f .env ]; then \
		grep -c "CHANGE_ME" .env && echo "⚠️  Ci sono password da cambiare nel .env!" || echo "✅ Nessun CHANGE_ME trovato"; \
	fi

check-env: ## Verifica che .env sia allineato a .env.example
	@bash scripts/check-env.sh

gpu-check: ## Verifica presenza GPU NVIDIA
	@nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
		&& echo "GPU_OK" || echo "GPU_MISSING"

test: ## Suite offline: lint, sintassi, JSON/YAML, segreti, test unitari
	@./scripts/run-tests.sh

healthcheck: ## Verifica end-to-end: endpoint di salute + impronta dati (pre/post update)
	@./scripts/healthcheck.sh $(SERVICE)

health: ## Mostra solo i container non sani
	@docker compose ps --format "table {{.Name}}\t{{.Status}}" \
		| grep -iE "restarting|exited|dead|unhealthy|created|paused|starting" \
		|| echo "✅ Tutti i container sono sani"

check-updates: ## Genera il manifest JSON SSoT dei servizi
	@python3 ./scripts/check_updates.py
