#!/usr/bin/env bash
# One-shot end-to-end demo of the scientific-infrastructure reference.
# Brings the stack up, waits for data on all three nodes and for the
# rollups, opens Grafana, shows a few query results.
#
# Usage:
#   ./scripts/demo.sh             # reuse existing license volume if present
#   ./scripts/demo.sh --fresh     # wipe first; forces re-validation
#   ./scripts/demo.sh --no-browser
#   ./scripts/demo.sh --no-pause  # skip the intro keypress (scripted runs)
#   ./scripts/demo.sh --help

set -euo pipefail

cd "$(dirname "$0")/.."

# ── args ──────────────────────────────────────────────────────────────────
FRESH=0
OPEN_BROWSER=1
PAUSE=1
[[ -t 0 ]] || PAUSE=0
for arg in "$@"; do
    case "$arg" in
        --fresh) FRESH=1 ;;
        --no-browser) OPEN_BROWSER=0 ;;
        --no-pause) PAUSE=0 ;;
        -h|--help)
            sed -n '2,11p' "$0" | sed 's/^# //; s/^#//'
            exit 0
            ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# ── colors ────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
    FG_BLUE=$'\033[38;5;75m'; FG_GREEN=$'\033[38;5;42m'; FG_YELLOW=$'\033[38;5;221m'
    FG_CYAN=$'\033[38;5;80m'; FG_MAGENTA=$'\033[38;5;177m'
    FG_GREY=$'\033[38;5;244m'; FG_TEXT=$'\033[38;5;252m'
else
    BOLD= DIM= RESET= FG_BLUE= FG_GREEN= FG_YELLOW= FG_CYAN= FG_MAGENTA= FG_GREY= FG_TEXT=
fi

STEP=0
step() { STEP=$((STEP + 1)); echo; echo "${BOLD}${FG_BLUE}┌─ Step ${STEP}: $1${RESET}"; }
info()  { echo "${FG_GREY}│${RESET}  $*"; }
ok()    { echo "${FG_GREEN}│  ✓${RESET} $*"; }
warn()  { echo "${FG_YELLOW}│  ⚠${RESET}  $*"; }
note()  { echo "${FG_CYAN}│  ◆${RESET}  $*"; }
cmd()   { echo "${FG_MAGENTA}│  \$${RESET} ${DIM}$*${RESET}"; }
close_step() { echo "${FG_BLUE}└───────${RESET}"; }

spin_until() {
    local label="$1" check="$2" timeout="${3:-180}"
    local start; start=$(date +%s)
    while true; do
        if eval "${check}" >/dev/null 2>&1; then ok "${label}"; return 0; fi
        if (( $(date +%s) - start > timeout )); then warn "timeout waiting: ${label}"; return 1; fi
        sleep 2
    done
}

iql() {
    docker compose exec -T influxdb3 bash -c \
        'TOKEN=$(cat /var/lib/influxdb3/.sci-token-plain); influxdb3 query --database sci --token "$TOKEN" "'"$1"'"' 2>/dev/null | grep -v deprecated
}

exited_ok() { docker inspect --format '{{.State.ExitCode}}{{.State.Status}}' "$1" 2>/dev/null | grep -q '^0exited$'; }

# ── banner ────────────────────────────────────────────────────────────────
echo
echo "${BOLD}${FG_TEXT}  Precision Scientific Infrastructure Monitoring — InfluxDB 3 Enterprise reference${RESET}"
echo "${FG_GREY}  ───────────────────────────────────────────────────────────────────────────${RESET}"
echo "${FG_TEXT}  What this demo shows:${RESET}"
echo "${FG_TEXT}    • three remote nodes (daq, compute, storage), each a Telegraf agent${RESET}"
echo "${FG_TEXT}      — daq fed by collectd, the others by inputs.mock — writing every 1 s${RESET}"
echo "${FG_TEXT}    • nanosecond timestamps kept end to end (precision = \"1ns\")${RESET}"
echo "${FG_TEXT}    • one database with 5-year retention and explicit tables${RESET}"
echo "${FG_TEXT}    • the Processing Engine rolling raw 1 s rows into 5 s dashboard tables${RESET}"
echo "${FG_TEXT}    • Grafana: fleet overview, three identical node dashboards, muted alerts${RESET}"
echo
echo "${FG_GREY}  Actor key:  [script] this script   [db] InfluxDB 3   [agent] Telegraf/collectd   [ui] Grafana${RESET}"
echo
if (( PAUSE )); then read -rp "  Press Enter to start…"; fi

# ── steps ─────────────────────────────────────────────────────────────────
if (( FRESH )); then
    step "Wipe state (--fresh)"
    cmd "make clean"
    docker compose down -v >/dev/null 2>&1 || true
    ok "volumes dropped — the next boot needs a fresh license validation"
    close_step
fi

step "Bring the stack up"
info "[script] docker compose up -d (token-bootstrap → influxdb3 → plugin-installer"
info "         → init → telegraf-daq/compute/storage + collectd → grafana)"
cmd "make up"
./scripts/setup.sh
docker compose up -d >/dev/null 2>&1
note "[db] first boot for a new email: check your inbox and CLICK THE VALIDATION LINK"
spin_until "influxdb3 healthy" \
    "docker inspect --format '{{.State.Health.Status}}' sci-influxdb3 2>/dev/null | grep -q '^healthy$'" 600
spin_until "plugin-installer finished (registry → files API, sha256 verified)" "exited_ok sci-plugin-installer" 300
spin_until "init finished (database, 5y retention, 10 tables, 5 triggers)" "exited_ok sci-influxdb3-init" 300
close_step

step "Watch the three agents arrive"
info "[agent] every node writes cpu, load, mem, temperature, uptime once a second"
spin_until "raw data from all three hosts (cpu)" \
    "iql \"SELECT count(DISTINCT host) AS hosts FROM cpu WHERE time > now() - INTERVAL '30 seconds'\" | grep -qE '\| 3 '" 180
spin_until "5 s rollups landing for all three hosts (cpu_5s)" \
    "iql \"SELECT count(DISTINCT host) AS hosts FROM cpu_5s WHERE time > now() - INTERVAL '60 seconds'\" | grep -qE '\| 3 '" 180
close_step

step "Open Grafana"
info "[ui] Fleet overview: status + uptime per node, alert list"
info "[ui] click a node title for its dashboard: status · current values · history"
if (( OPEN_BROWSER )); then
    (command -v open >/dev/null && open "http://localhost:3000/d/sci-fleet") || \
    (command -v xdg-open >/dev/null && xdg-open "http://localhost:3000/d/sci-fleet") || \
    info "open http://localhost:3000/d/sci-fleet manually"
else
    info "open http://localhost:3000/d/sci-fleet"
fi
close_step

step "Query both ends of the pipeline"
cmd "make cli-example name=nanosecond-timestamps"
iql "SELECT time, host, usage_active FROM cpu ORDER BY time DESC LIMIT 3" || true
note "nine fractional digits — the Telegraf default would have rounded these to whole seconds"
cmd "make cli-example name=rollup-rows"
iql "SELECT time, host, usage_active_avg, record_count FROM cpu_5s ORDER BY time DESC LIMIT 3" || true
note "record_count = 5: every bucket was complete when the plugin read it, and written once"
cmd "make cli-example name=show-retention"
docker compose exec -T influxdb3 bash -c 'TOKEN=$(cat /var/lib/influxdb3/.sci-token-plain); influxdb3 show retention --token "$TOKEN"' 2>/dev/null | grep -v deprecated | head -6 || true
note "43830 h = 5 years, on every table"
close_step

step "Summary"
ok "three Telegraf agents (collectd + mock) → one schema, via namepass / fieldinclude / taginclude / tagpass / rename"
ok "nanosecond timestamps end to end; 5-year retention; raw → 5 s rollups in the Processing Engine"
ok "Grafana provisioned from files: overview, node dashboards, alerts that fire and go nowhere"
note "docs: README.md · ARCHITECTURE.md · CLI_EXAMPLES.md · influxdb/schema.md"
close_step
echo
