#!/usr/bin/env bash
# Generate the per-node Grafana dashboards from one template.
#
# The three node dashboards are identical except for the host name. Edit
# grafana/dashboards/node.json.tmpl, run this script (or `make dashboards`),
# and commit the generated files; Grafana re-reads them within 10 s.
set -euo pipefail

cd "$(dirname "$0")/../grafana/dashboards"
for host in daq compute storage; do
    sed "s/__HOST__/${host}/g" node.json.tmpl > "node-${host}.json"
    echo "[dashboards] wrote node-${host}.json"
done
