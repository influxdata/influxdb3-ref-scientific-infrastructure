#!/bin/sh
# Container command for the storage node's Telegraf agent.
#
# With STORAGE_FLAP=true (the default) the agent runs for STORAGE_UP_S
# seconds, is then stopped (SIGTERM, clean flush) and stays silent for
# STORAGE_DOWN_S seconds, forever — a simulated flapping node, so the
# overview's status card and the "Node down" alert have something to show.
# The node-down alert needs roughly 80 s of silence to fire and clears about
# 25 s after the agent returns, so keep STORAGE_DOWN_S well above 90.
# With STORAGE_FLAP=false the agent runs like the other nodes.
set -eu

export INFLUX_TOKEN="$(cat /tokens/.sci-token-plain)"

if [ "${STORAGE_FLAP:-true}" != "true" ]; then
    exec telegraf --config /etc/telegraf/telegraf.conf
fi

while true; do
    echo "[flap] agent up for ${STORAGE_UP_S:-180}s"
    timeout "${STORAGE_UP_S:-180}" telegraf --config /etc/telegraf/telegraf.conf || true
    echo "[flap] agent silent for ${STORAGE_DOWN_S:-120}s (simulated outage)"
    sleep "${STORAGE_DOWN_S:-120}"
done
