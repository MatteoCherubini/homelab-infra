.PHONY: help up down restart logs ps pull check init

help: ## Mostra questo help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-18s\033[0m %s\n", $$1, $$2}'

init: ## Setup iniziale: crea .env, directory e config
	@./scripts/init.sh

up: ## Avvia tutto (CPU)
	COMPOSE_PARALLEL_LIMIT=1 docker compose --profile cpu up -d

down: ## Ferma tutto (qualsiasi profilo attivo)
	docker compose --profile cpu --profile gpu down

restart: ## Restart tutto
	docker compose restart

logs: ## Log live (tutti)
	docker compose logs -f --tail=50

ps: ## Stato servizi
	docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

pull: ## Scarica immagini aggiornate (non avvia)
	docker compose pull

check: ## Verifica prerequisiti e config
	@echo "Docker:  $$(docker --version)"
	@echo "Compose: $$(docker compose version)"
	@echo ""
	@docker compose config --quiet && echo "✅ Compose config valida" || echo "❌ Errore nella config"
	@echo ""
	@grep -c "CHANGE_ME" .env && echo "⚠️  Ci sono password da cambiare nel .env!" || echo "✅ Nessun CHANGE_ME trovato"

up-gpu: ## Avvia con supporto GPU NVIDIA
	docker compose --profile gpu up -d

health: ## Mostra solo i container non healthy
	@docker compose ps --format "table {{.Name}}\t{{.Status}}" | grep -v "healthy\|running" || echo "✅ Tutti i container sono healthy"
