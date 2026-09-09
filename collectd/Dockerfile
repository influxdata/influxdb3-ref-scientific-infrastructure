# collectd for the DAQ node. Debian's collectd-core carries every plugin this
# demo uses (cpu, load, memory, uptime, interface, df, network, logfile).
FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends collectd-core \
 && rm -rf /var/lib/apt/lists/*
COPY collectd.conf /etc/collectd/collectd.conf
# -f: stay in the foreground; -C: this config only.
ENTRYPOINT ["collectd", "-f", "-C", "/etc/collectd/collectd.conf"]
