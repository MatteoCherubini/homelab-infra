.PHONY: help up down restart logs ps pull check init

help: ## Mostra questo help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

init: ## Setup iniziale: copia .env e crea directory dati
	@./scripts/init.sh

up: ## Avvia tutto
	COMPOSE_PARALLEL_LIMIT=1 docker compose up -d

down: ## Ferma tutto
	docker compose down

restart: ## Restart tutto
	docker compose restart

logs: ## Log live (tutti)
	docker compose logs -f

ps: ## Stato servizi
	docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

pull: ## Scarica immagini aggiornate (non avvia)
	docker compose pull

check: ## Verifica prerequisiti
	@echo "Docker:  $$(docker --version)"
	@echo "Compose: $$(docker compose version)"
	@echo ""
	@docker compose config --quiet && echo "✅ Compose config valida" || echo "❌ Errore nella config"

# ── Stack singoli ──────────────────────────────────────────────
up-%: ## Avvia uno stack (es: make up-ai)
	docker compose up -d $$(docker compose config --services | grep -f stacks/$*/compose.yml 2>/dev/null || echo "$*")

down-%: ## Ferma uno stack
	docker compose stop $$(docker compose config --services | grep -f stacks/$*/compose.yml 2>/dev/null || echo "$*")

logs-%: ## Log di uno stack
	docker compose logs -f $*

# ── GPU ────────────────────────────────────────────────────────
up-gpu: ## Avvia con supporto GPU NVIDIA
	docker compose --profile gpu up -d
