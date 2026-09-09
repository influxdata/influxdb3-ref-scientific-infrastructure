SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help
COMPOSE := docker compose

.PHONY: help up down clean demo demo-fresh logs ps open dashboards cli query cli-example

help: ## Show targets
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[1;36m%-20s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

demo: ## End-to-end scripted demo: stack up → Grafana → query results
	@./scripts/demo.sh

demo-fresh: ## Same as demo, but wipes state first (forces license re-validation)
	@./scripts/demo.sh --fresh

up: ## Prompt for email (if needed), write .env, then bring the stack up
	@./scripts/setup.sh
	@echo
	@echo "============================================================="
	@echo "  InfluxDB 3 Enterprise is starting."
	@echo "  Check the email you provided and CLICK THE VALIDATION LINK."
	@echo "  Telegraf agents start writing and Grafana provisions itself"
	@echo "  automatically once validation completes."
	@echo "  Grafana: http://localhost:3000    API: http://localhost:8181"
	@echo "============================================================="
	@$(COMPOSE) up -d

down: ## Stop services (preserves data volume)
	@$(COMPOSE) down

clean: ## Stop services and drop the data volume (requires re-validation next time)
	@$(COMPOSE) down -v

logs: ## Tail all service logs
	@$(COMPOSE) logs -f

ps: ## Show service status
	@$(COMPOSE) ps

open: ## Open Grafana in the browser
	@(command -v open >/dev/null && open "http://localhost:$${GRAFANA_PORT:-3000}") || \
	 (command -v xdg-open >/dev/null && xdg-open "http://localhost:$${GRAFANA_PORT:-3000}") || \
	 echo "open http://localhost:$${GRAFANA_PORT:-3000}"

dashboards: ## Regenerate the per-node Grafana dashboards from grafana/dashboards/node.json.tmpl
	@./scripts/gen-node-dashboards.sh

cli: ## Shell into influxdb3 container; TOKEN is exported, `iql <sql>` runs queries
	@$(COMPOSE) exec influxdb3 bash -c '\
	  export TOKEN=$$(cat /var/lib/influxdb3/.sci-token-plain); \
	  iql() { influxdb3 query --database sci --token "$$TOKEN" "$$1"; }; \
	  export -f iql; \
	  echo ""; \
	  echo "  TOKEN is exported. Try:"; \
	  echo "    iql \"SELECT host, count(*) FROM cpu WHERE time > now() - INTERVAL '"'"'30 seconds'"'"' GROUP BY host\""; \
	  echo "    iql \"SELECT * FROM cpu_5s ORDER BY time DESC LIMIT 3\""; \
	  echo ""; \
	  exec bash'

query: ## One-shot query. Usage: make query sql='SELECT COUNT(*) FROM cpu'
	@test -n "$(sql)" || (echo "usage: make query sql='<SQL>'"; exit 1)
	@$(COMPOSE) exec -T -e "SQL=$(sql)" influxdb3 bash -c 'TOKEN=$$(cat /var/lib/influxdb3/.sci-token-plain); influxdb3 query --database sci --token "$$TOKEN" "$$SQL"'

cli-example: ## Run a named curated CLI example. Usage: make cli-example name=list-databases
	@test -n "$(name)" || (echo "usage: make cli-example name=<example>"; exit 1)
	@awk -v want="$(name)" '/^## /{on=($$2==want)} on && /^```bash/{inb=1; next} on && inb && /^```/{exit} on && inb{print}' CLI_EXAMPLES.md \
	  | while read -r line; do echo "+ $$line"; $(COMPOSE) exec -T influxdb3 bash -lc "export TOKEN=\$$(cat /var/lib/influxdb3/.sci-token-plain); $$line" | grep -v deprecated; done
