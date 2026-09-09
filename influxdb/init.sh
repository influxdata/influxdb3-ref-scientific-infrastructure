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

# Read a pinned version out of installer/plugins.lock so trigger paths always
# match what the installer uploaded (single source of truth for pins).
lock_version() {
    local name="$1"
    awk -v want="$name" '
        $1 == "name"    && $3 == "\"" want "\"" { found = 1 }
        found && $1 == "version" { gsub(/"/, "", $3); print $3; exit }
    ' "${LOCK_FILE}"
}

RAW_TABLES="cpu load mem temperature uptime"

# Trigger flags don't update in place on re-run; delete-and-recreate corrects
# stale catalog entries on subsequent boots (a no-op on first boot).
delete_triggers() {
    local t
    for t in ${RAW_TABLES}; do
        cli delete trigger "downsample_${t}" --database "${INFLUX_DB}" --force 2>/dev/null || true
    done
}

# One downsampling trigger per raw table: raw (1 row/s/host) -> <table>_5s
# (1 row/5 s/host) via the registry downsampler plugin.
#
# Why a wall-clock cron and offset=5s/window=5s rather than every:5s: the
# plugin queries [call_time - offset - window, call_time - offset) and
# formats both bounds as whole seconds, so a tick aligned to :05/:10/... reads
# exactly one complete 5-second bucket and writes it once. every:5s is not
# wall-clock aligned, straddles two buckets every tick and rewrites each
# bucket twice with partial data.
ensure_triggers() {
    local ds_ver t calc
    ds_ver=$(lock_version downsampler)
    if [[ -z "${ds_ver}" ]]; then
        echo "[init] FATAL: downsampler version not found in ${LOCK_FILE}" >&2
        exit 1
    fi
    log "pinned versions: downsampler=${ds_ver}"
    delete_triggers
    for t in ${RAW_TABLES}; do
        calc=avg
        [[ "${t}" == "uptime" ]] && calc=max   # monotonic counter: keep the newest
        idempotent "trigger downsample_${t}" create trigger \
            --database "${INFLUX_DB}" \
            --trigger-spec "cron:*/5 * * * * *" \
            --path "downsampler-${ds_ver}/downsampler.py" \
            --trigger-arguments "source_measurement=${t},target_measurement=${t}_5s,target_database=${INFLUX_DB},interval=5s,window=5s,offset=5s,calculations=${calc}" \
            "downsample_${t}"
        cli enable trigger "downsample_${t}" --database "${INFLUX_DB}" 2>/dev/null || \
            log "trigger downsample_${t} enable no-op"
    done
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
