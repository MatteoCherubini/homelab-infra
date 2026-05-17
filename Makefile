.PHONY: help up down restart logs ps pull check init check-env gpu-check verify health up-auto

# Variabili per formattazione
SHELL := /bin/bash
YELLOW := \033[33m
RESET  := \033[0m

help: ## Mostra questo help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

init: ## Setup iniziale: crea .env, directory e config
	@./scripts/init.sh

up: ## Avvia tutto (profilo CPU) e rimuove orfani
	COMPOSE_PARALLEL_LIMIT=1 docker compose --profile cpu up -d --remove-orphans

up-gpu: ## Avvia tutto (profilo GPU NVIDIA) e rimuove orfani
	docker compose --profile gpu up -d --remove-orphans

up-auto: ## Rileva hardware e avvia il profilo corretto (GPU se presente, altrimenti CPU)
	@if nvidia-smi --query-gpu=name --format=csv,noheader > /dev/null 2>&1; then \
		echo -e "$(YELLOW)🚀 GPU NVIDIA rilevata. Avvio profilo GPU...$(RESET)"; \
		$(MAKE) up-gpu; \
	else \
		echo -e "$(YELLOW)💻 Nessuna GPU rilevata. Avvio profilo CPU...$(RESET)"; \
		$(MAKE) up; \
	fi

down: ## Ferma tutto (qualsiasi profilo attivo)
	docker compose --profile cpu --profile gpu down

restart: ## Restart di tutti i servizi
	docker compose restart

logs: ## Log live (tutti i servizi)
	docker compose logs -f --tail=50

verify: ## Confronta le versioni su disco con quelle EFFETTIVAMENTE in esecuzione
	@echo "🔍 Verifica allineamento Repo <-> Runtime..."
	@echo "------------------------------------------------------------------------------------------------"
	@printf "%-25s %-40s %-40s %s\n" "SERVIZIO" "DICHIARATO (Repo)" "ATTIVO (Docker)" "STATO"
	@echo "------------------------------------------------------------------------------------------------"
	@comm --output-delimiter='|' \
		<(docker compose --profile "*" config --format json | jq -r '.services | to_entries[] | "\(.key) \(.value.image)"' | sort) \
		<(docker compose ps --format json | jq -r 'if type=="array" then .[] else . end | "\(.Service // .service) \(.Image // .image)"' | sort -u) \
		| awk -F'|' '{ \
			if ($$3 != "") { split($$3, a, " "); printf "%-25s %-40s %-40s ✅ OK\n", a[1], a[2], a[2] } \
			else if ($$2 != "") { split($$2, a, " "); printf "%-25s %-40s %-40s ❌ DISALLINEATO\n", a[1], "N/A", a[2] } \
			else { split($$1, a, " "); printf "%-25s %-40s %-40s ⚪ FERMO\n", a[1], a[2], "-" } \
		}'

ps: ## Stato dei servizi attivi
	docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

pull: ## Scarica immagini aggiornate (senza avviare)
	docker compose --profile "*" pull

check: check-env ## Verifica prerequisiti e validità configurazioni
	@echo "Docker:  $$(docker --version)"
	@echo "Compose: $$(docker compose version)"
	@echo ""
	@docker compose --profile "*" config --quiet && echo "✅ Compose config valida" || echo "❌ Errore nella config"
	@echo ""
	@if [ -f .env ]; then \
		grep -c "CHANGE_ME" .env && echo "⚠️  Ci sono password da cambiare nel .env!" || echo "✅ Nessun CHANGE_ME trovato"; \
	fi

check-env: ## Verifica che .env sia allineato a .env.example
	@bash scripts/check-env.sh

gpu-check: ## Verifica presenza GPU NVIDIA (usato dai workflow di deploy)
	@nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null \
		&& echo "GPU_OK" || echo "GPU_MISSING"

health: ## Mostra solo i container non in stato healthy
	@docker compose ps --format "table {{.Name}}\t{{.Status}}" | grep -v "healthy\|running" || echo "✅ Tutti i container sono healthy"

manifest-json: ## Genera il manifest JSON Single Source of Truth (SSoT) dei servizi
	@python3 ./scripts/generate_manifest.py
