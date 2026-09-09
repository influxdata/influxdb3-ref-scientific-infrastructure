# Schema reference — database `sci`

One database, **5-year retention** set on the database (`create database sci
--retention-period 5y` in `init.sh`); every table inherits it. All ten tables
are created explicitly by `init.sh` (CLI `create table`) before any agent
writes, so the schema below is a contract: a Telegraf agent that emits a
measurement, field or tag not listed here is misconfigured, and the gates in
the implementation plan check for exactly these columns.

## Tags (every table)

| Tag | Values | Notes |
|---|---|---|
| `host` | `daq`, `compute`, `storage` | the node; the only tag that survives each agent's `taginclude = ["host"]` |

## Raw tables — 1 row / second / host, written by the Telegraf agents

| Table | Fields | Source per node |
|---|---|---|
| `cpu` | `usage_active` f64 (%) | daq: collectd `cpu` (`percent-active`) · compute/storage: `inputs.mock` |
| `load` | `load1`, `load5`, `load15` f64 | daq: collectd `load` (shortterm/midterm/longterm) · mock |
| `mem` | `used_percent` f64 (%) | daq: collectd `memory` (`percent-used`) · mock |
| `temperature` | `temp_c` f64 | `inputs.mock` on all three nodes |
| `uptime` | `uptime` i64 (s) | `inputs.system` on all three nodes, `fieldinclude = ["uptime"]` |

Timestamps carry full nanosecond precision (`[agent] precision = "1ns"`;
collectd's own high-resolution timestamps pass through the service input).

## Dashboard tables — 1 row / 5 s / host, written by the `downsampler` plugin

| Table | Fields declared here | Added by the plugin's first write |
|---|---|---|
| `cpu_5s` | `usage_active_avg` f64 | `record_count` i64, `time_from`, `time_to` |
| `load_5s` | `load1_avg`, `load5_avg`, `load15_avg` f64 | same |
| `mem_5s` | `used_percent_avg` f64 | same |
| `temperature_5s` | `temp_c_avg` f64 | same |
| `uptime_5s` | `uptime_max` i64 | same |

Bucket timestamps sit on the wall-clock 5-second grid (`time % 5s = 0`).
Grafana reads only these tables and aliases the `_avg`/`_max` suffix away in
SQL (`usage_active_avg AS usage_active`).
