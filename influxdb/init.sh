#!/usr/bin/env bash
# Runs inside a one-shot container against the influxdb3 service. Idempotent.
#
# Creates the `sci` database with a 5-year retention period and every table
# explicitly (full tag/field schema declared up front, no sentinel rows), then
# registers the Processing Engine downsampling triggers (tables FIRST,
# triggers SECOND — a trigger created before its table exists never fires).
#
# Plugin files are NOT registered here — the plugin-installer service uploads
# them through POST /api/v3/plugins/files. Trigger --path values reference the
# installer's naming convention: {name}-{version}/{entry}.py, with versions
# read from installer/plugins.lock (single source of truth for pins).

set -euo pipefail

INFLUX_HOST="${INFLUX_HOST:-http://influxdb3:8181}"
INFLUX_DB="${INFLUX_DB:-sci}"
RETENTION="${RETENTION:-5y}"
TOKEN_FILE="/var/lib/influxdb3/.sci-operator-token"
TOKEN_PLAIN_FILE="/var/lib/influxdb3/.sci-token-plain"
LOCK_FILE="${LOCK_FILE:-/installer/plugins.lock}"

log() { echo "[init] $*"; }

read_token_json() {
    sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$1" | head -n1
}

ensure_token() {
    if [[ ! -s "${TOKEN_FILE}" ]]; then
        echo "[init] FATAL: ${TOKEN_FILE} missing — token-bootstrap service failed" >&2
        exit 1
    fi
    if [[ ! -s "${TOKEN_PLAIN_FILE}" ]]; then
        read_token_json "${TOKEN_FILE}" | tr -d '\n' > "${TOKEN_PLAIN_FILE}"
        # 644: healthcheck, Telegraf and Grafana read this as non-root.
        chmod 644 "${TOKEN_PLAIN_FILE}"
    fi
    log "admin token present"
}

wait_for_api() {
    local token
    token=$(read_token_json "${TOKEN_FILE}")
    # License validation can be interactive on first boot; wait generously.
    for _ in $(seq 1 900); do
        if curl -sf --max-time 2 -o /dev/null \
            -H "Authorization: Bearer ${token}" "${INFLUX_HOST}/health"; then
            return 0
        fi
        sleep 2
    done
    echo "[init] FATAL: influxdb3 API did not become ready" >&2
    exit 1
}

cli() {
    local token
    token=$(read_token_json "${TOKEN_FILE}")
    influxdb3 "$@" --host "${INFLUX_HOST}" --token "${token}"
}

idempotent() {
    local label="$1"; shift
    local out
    if out=$(cli "$@" 2>&1); then
        log "created ${label}"
    elif echo "$out" | grep -qE "already exists|Conflict|409"; then
        log "${label} already exists"
    else
        echo "[init] FATAL while creating ${label}: $out" >&2
        exit 1
    fi
}

# Five-year retention on the database; every table inherits it.
ensure_database() {
    idempotent "database ${INFLUX_DB} (retention ${RETENTION})" \
        create database "${INFLUX_DB}" --retention-period "${RETENTION}"
}

# Raw tables: one row per second per host, written by the Telegraf agents.
# Dashboard tables (<table>_5s): one row per 5 s per host, written by the
# registry downsampler plugin, which names its output fields <field>_<calc>
# and adds record_count/time_from/time_to on its first write.
ensure_tables() {
    local t
    while IFS='|' read -r t fields; do
        [[ -z "${t}" ]] && continue
        idempotent "table ${t}" create table "${t}" \
            --database "${INFLUX_DB}" \
            --tags host \
            --fields "${fields}"
    done <<'TABLES'
cpu|usage_active:float64
load|load1:float64,load5:float64,load15:float64
mem|used_percent:float64
temperature|temp_c:float64
uptime|uptime:int64
cpu_5s|usage_active_avg:float64
load_5s|load1_avg:float64,load5_avg:float64,load15_avg:float64
mem_5s|used_percent_avg:float64
temperature_5s|temp_c_avg:float64
uptime_5s|uptime_max:int64
TABLES
}

# Filled in when the plugin-installer service and the downsampling
# triggers are added (plan step 6).
ensure_triggers() {
    log "no triggers registered yet"
}

main() {
    ensure_token
    wait_for_api
    ensure_database
    ensure_tables
    ensure_triggers
    log "initialization complete"
}

main "$@"
