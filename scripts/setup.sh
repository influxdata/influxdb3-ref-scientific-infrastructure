#!/usr/bin/env bash
# Prompts for INFLUXDB3_ENTERPRISE_EMAIL if not yet set in .env.
# Creates .env from .env.example if missing. Idempotent.

set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
    cp .env.example .env
    echo "[setup] created .env from .env.example"
fi

if grep -q '^INFLUXDB3_ENTERPRISE_EMAIL=.\+' .env; then
    EMAIL=$(grep '^INFLUXDB3_ENTERPRISE_EMAIL=' .env | cut -d= -f2-)
    echo "[setup] using existing INFLUXDB3_ENTERPRISE_EMAIL=${EMAIL}"
    exit 0
fi

echo
echo "InfluxDB 3 Enterprise requires email-based license validation."
echo "On first startup, a validation email is sent to the address below."
echo "You must click the validation link before the stack finishes starting."
echo
read -rp "Enter email for license validation: " EMAIL

if [[ -z "${EMAIL}" ]]; then
    echo "[setup] empty email; aborting" >&2
    exit 1
fi

if grep -q '^INFLUXDB3_ENTERPRISE_EMAIL=' .env; then
    python3 - "$EMAIL" <<'PY'
import pathlib, re, sys
email = sys.argv[1]
p = pathlib.Path(".env")
p.write_text(re.sub(r'^INFLUXDB3_ENTERPRISE_EMAIL=.*$',
                    f'INFLUXDB3_ENTERPRISE_EMAIL={email}',
                    p.read_text(), flags=re.M))
PY
else
    echo "INFLUXDB3_ENTERPRISE_EMAIL=${EMAIL}" >> .env
fi

echo "[setup] wrote INFLUXDB3_ENTERPRISE_EMAIL=${EMAIL} to .env"
