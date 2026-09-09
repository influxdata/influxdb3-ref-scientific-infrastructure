# Architecture

Deep-dive companion to `README.md`. Read the README first for the quickstart
and headline story; read this for the topology, the per-agent filter and
reshape tables, the downsampling alignment, the Grafana provisioning, the
gotchas, and how to scale to production.

## Table of contents

1. Domain model and topology
2. Boot order and the token
3. Nanosecond timestamps
4. Schema and retention
5. Filtering and reshaping, per agent
6. collectd on the DAQ node
7. Processing Engine downsampling
8. Grafana: datasource, dashboards, alerts
9. Gotchas found while building this
10. Security notes
11. Scaling to production
12. Extending: more nodes, more metrics

## 1. Domain model and topology

A small research facility has three kinds of machines worth watching: the
**data-acquisition** host that sits next to the instrument (`daq`), the
**compute** host that processes what it captures (`compute`), and the
**storage** host that keeps it (`storage`). Each is a *network node* running a
Telegraf agent; a fourth node is the *sink* — InfluxDB 3 Enterprise and
Grafana. Everything is one `docker compose` stack:

| Node | Containers | Role |
|---|---|---|
| sink | `sci-influxdb3` (`influxdb:3-enterprise`, `--mode all`, plugin dir inside the data volume), `sci-grafana` (13.2), one-shots `sci-token-bootstrap`, `sci-plugin-installer`, `sci-influxdb3-init` | database `sci`, Processing Engine, dashboards |
| daq | `sci-telegraf-daq` (Telegraf 1.40), `sci-collectd` (Debian bookworm `collectd-core`) | collectd → UDP 25826 → Telegraf; temperature from `inputs.mock`, uptime from `inputs.system` |
| compute | `sci-telegraf-compute` | `inputs.mock` for cpu/load/mem/temp, `inputs.system` for uptime, `inputs.processes` collected and dropped |
| storage | `sci-telegraf-storage` | same agent shape as compute, different value ranges; sine-wave temperature and a 3-min-on / 2-min-off outage cycle so alerts fire periodically |

The "node" grouping is conceptual — compose gives each container its own
network identity — but every agent behaves as a remote host would: it knows
only the sink's URL and a token, and it ships line protocol to
`/api/v2/write` once a second.

Why three sources for the same five metrics: it is the point of the demo.
collectd, a mock that mimics `inputs.cpu`/`inputs.mem`/`inputs.temp`, and the
real `inputs.system` all name things differently. The agents are where that
gets reconciled, so the database sees one schema (§4) and Grafana never has
to know where a number came from.

## 2. Boot order and the token

```
token-bootstrap ─► influxdb3 (healthy) ─► plugin-installer ─► influxdb3-init ─► telegraf-* (+ collectd), grafana
```

- **token-bootstrap** creates the offline admin token (`.sci-operator-token`,
  JSON, mode 600) and a plain-text copy (`.sci-token-plain`, mode 644) in the
  `influxdb-data` volume, plus the plugin directory the server needs to exist.
- **influxdb3**'s healthcheck sends the plain token as a Bearer header
  (`/health` requires auth).
- **plugin-installer** waits for the API, then installs the pinned plugin (§7).
- **influxdb3-init** creates the database, the tables and the triggers (§4, §7).
- The **Telegraf agents** and **Grafana** start only after init, so explicit
  table creation never races implicit creation-on-first-write, and Grafana's
  datasource token file exists before Grafana reads it.

The agents and Grafana mount the volume read-only at `/tokens` and read the
plain token from it. That is a **demo shortcut**: a real remote node cannot
see the database server's disk. See §10 and §11.

## 3. Nanosecond timestamps

Every Telegraf config sets

```toml
[agent]
  interval = "1s"
  precision = "1ns"
```

Telegraf's default `precision = "0s"` means "round to the interval's order of
magnitude, capped at 1 s" (`agent/agent.go`, `getPrecision`), so with a 1 s
interval every timestamp would be a whole second. With `1ns`, regular inputs
(`mock`, `system`, `processes`) keep the full `time.Now()` — the rows show up
as `…T17:49:59.003041667`. collectd is a *service* input: the agent precision
does not apply and collectd's own timestamps (2⁻³⁰ s resolution over the
network protocol) pass through untouched. `outputs.influxdb_v2` serialises
nanosecond line protocol and InfluxDB 3's v2-compatible write endpoint stores
it as `Timestamp(ns)`.

The check that this holds is one query: `SELECT count(*) FROM cpu WHERE
CAST(time AS BIGINT) % 1000000000 = 0` → 0 (`make cli-example
name=whole-second-rows`).

## 4. Schema and retention

See `influxdb/schema.md` for the table reference. Highlights:

- **One tag, five raw tables, five rollup tables.** `cpu.usage_active`,
  `load.load1/load5/load15`, `mem.used_percent`, `temperature.temp_c`,
  `uptime.uptime` (int64), all tagged only by `host`; and `<table>_5s` with
  `<field>_avg` (`uptime_max` for uptime) plus the downsampler's
  `record_count`, `time_from`, `time_to`.
- **Explicit table creation** (`init.sh`, CLI `create table --tags host
  --fields …`) before any agent writes. The schema is a contract: an agent that
  leaks a field or a tag adds a column, which the plan's gates catch.
- **Five-year retention on the database**, inherited by every table:
  `create database sci --retention-period 5y`. `influxdb3 show retention`
  reports it as `43830.0000h` per table. A write with a timestamp older than
  the cutoff is rejected outright (HTTP 400, `write timestamp … is older than
  the retention period cutoff`) — no silent backfill. There is no backfill in
  this repo; the retention is configured, not exercised.
- No Last Value Cache and no Distinct Value Cache: the dashboards read one row
  per host from tables that are tiny, and there is nothing high-cardinality.

## 5. Filtering and reshaping, per agent

Telegraf offers pairs of filters; this repo picks one of each: `namepass`
(not `namedrop`), `fieldinclude` (not `fieldexclude`), `taginclude` as the
tag-*key* allowlist, and — on the DAQ agent only — `tagpass` as a tag-*value*
allowlist. Reshaping is `processors.rename`.

Common to all three agents, on the output:

```toml
[[outputs.influxdb_v2]]
  namepass = ["cpu", "load", "mem", "temperature", "uptime"]   # the write contract
  taginclude = ["host"]                                        # every other tag is stripped
```

**compute / storage (mock):**

| Input emits | Filter / reshape | Lands as |
|---|---|---|
| `[[inputs.mock]] cpu{cpu=cpu-total}` random `usage_active`, `usage_user`, `usage_system`, `usage_iowait`, `usage_steal` | `fieldinclude = ["usage_active"]`; output `taginclude` strips `cpu` | `cpu.usage_active` |
| `[[inputs.mock]] load` random `load1`, `load5`, `load15` | — | `load.*` |
| `[[inputs.mock]] mem` random `used_percent`, `available_percent`, `cached_percent` | `fieldinclude = ["used_percent"]` | `mem.used_percent` |
| `[[inputs.mock]] temp{sensor=…}` random `temp` (the shape `inputs.temp` produces) | rename `temp`→`temperature`, field `temp`→`temp_c`; `taginclude` strips `sensor` | `temperature.temp_c` |
| `[[inputs.system]]` legacy layout: `load1/5/15`, `n_cpus`, `n_users`, `uptime`, `uptime_format` | `fieldinclude = ["uptime"]`; rename `system`→`uptime` | `uptime.uptime` |
| `[[inputs.processes]]` — collected on purpose | dropped by output `namepass` | nothing |

**daq (collectd + mock temperature + system):** the collectd parser (join
mode) names each measurement after the collectd *plugin*, puts the value(s) in
fields named by `types.db`, and carries `host`, `type`, `type_instance` and
`instance` tags. `name_prefix = "collectd_"` makes the origin visible in the
pre-rename names.

| collectd sends (after prefix, distinguishing tags) | Fate |
|---|---|
| `collectd_cpu{type=percent,type_instance=active}` `value` | keep; scoped rename → `cpu.usage_active` |
| `collectd_load{type=load}` `shortterm`, `midterm`, `longterm` | keep; scoped rename → `load.load1/load5/load15` |
| `collectd_memory{type=percent,type_instance=used}` `value` | keep; scoped rename → `mem.used_percent` |
| `collectd_memory{type_instance=free,cached,buffered,slab_*}` | dropped by `tagpass` |
| `collectd_uptime{type=uptime}` (no `type_instance`) | dropped by `tagpass` — uptime is standardised on `inputs.system` on every node |
| `collectd_interface{instance=eth0,type=if_octets…}` (no `type_instance`) | dropped by `tagpass` |
| `collectd_df{instance=root,type=percent_bytes,type_instance=used}` | passes `tagpass` (it *is* `used`), dropped by output `namepass` — why both filters exist |
| `temp{sensor=…}` from `inputs.mock` | rename → `temperature.temp_c`; `taginclude` strips `sensor` |
| `system` from `inputs.system` | `fieldinclude = ["uptime"]`; rename → `uptime.uptime` |
| leftover tags `type`, `type_instance`, `instance` | stripped by output `taginclude = ["host"]` |

The `tagpass` table is an OR across keys:

```toml
  [inputs.socket_listener.tagpass]
    type_instance = ["active", "used"]
    type = ["load"]
```

Why `tagpass` is needed at all: collectd multiplexes one measurement across
`type_instance` values (six `collectd_memory` rows per second). Selecting
`used` has to happen *before* `taginclude` strips the tag, otherwise the six
rows collapse onto one series and overwrite each other.

Why the renames are scoped: a `processors.rename` field rename applies to
every metric that has the field. `value`→`usage_active` in an unscoped block
would also rename `collectd_memory`'s `value`. Each block therefore carries
`namepass = ["collectd_cpu"]` etc.

## 6. collectd on the DAQ node

`collectd/collectd.conf`: `Interval 1` (matching Telegraf), `Hostname "daq"`,
plugins `cpu` (`ReportByCpu false`, `ReportByState false`,
`ValuesPercentage true` → one `percent-active` value), `load`, `memory`
(`ValuesPercentage true`), plus `uptime`, `interface` and `df` sent so that
Telegraf can visibly drop them, and `network` → `Server "telegraf-daq" "25826"`.
Logs go to stderr so `docker compose logs collectd` shows them.

`telegraf/types.db` is a six-line file of this repo's own: Telegraf's collectd
parser ships no type definitions, and without one a multi-value type such as
`load` surfaces as fields `0`, `1`, `2`.

Temperature is deliberately *not* a collectd concern: Docker Desktop's Linux
VM exposes no `/sys/class/thermal` zones, so neither collectd's `thermal`
plugin nor Telegraf's `inputs.temp` produces data on the target machine. All
three agents use the same `inputs.mock` temperature block; on a Linux host
with sensors, swap it for `[[inputs.temp]]` (same measurement and field
names, so the rename block already fits).

## 7. Processing Engine downsampling

**Provisioning.** The one-shot `plugin-installer` (stdlib-only Python, copied
from `influxdb3-ref-auto-manufacturing`) resolves `installer/plugins.lock`
(`downsampler` `1.4.0`) against the registry index, downloads the artifact,
verifies its sha256 against the index, and uploads every file through
`POST /api/v3/plugins/files` as `downsampler-1.4.0/<file>`. No `gh:` paths,
no plugin bind mount; the server's `--plugin-dir` lives inside the data
volume. Re-running is an overwrite no-op.

**Triggers.** `init.sh` registers one schedule trigger per raw table (tables
first, triggers second), delete-and-recreate on every boot so flag changes
take effect:

```
--trigger-spec "cron:*/5 * * * * *"
--path "downsampler-1.4.0/downsampler.py"
--trigger-arguments "source_measurement=cpu,target_measurement=cpu_5s,target_database=sci,interval=5s,window=5s,offset=5s,calculations=avg"
```

`uptime` uses `calculations=max`. The plugin names output fields
`<field>_<calc>` (`usage_active_avg`), adds `record_count`, `time_from`,
`time_to`, and buckets with `DATE_BIN` anchored to the epoch, so every rollup
timestamp is on the wall-clock 5-second grid.

**Why a cron and an offset rather than `every:5s`.** The plugin queries
`[call_time − offset − window, call_time − offset)` and formats both bounds as
whole seconds. A tick aligned to `:05`, `:10`, … with `offset=5s` and
`window=5s` therefore reads exactly one complete bucket — e.g. the tick at
`:10` reads `[:00, :05)` — and writes it once; `record_count` is 5 on every
completed bucket and the rollup average equals the raw average to the last
digit. `every:5s` is not wall-clock aligned: each tick would straddle two
buckets, and every bucket would be written twice with partial data. The 5 s
offset also leaves Telegraf's 1 s flush and the WAL a comfortable margin.

**Consequence for "freshness".** A bucket starting at `T` is written at
`T + 10 s` (offset, then up to 5 s until the next tick), so a healthy node's
newest rollup row is 10–16 s old. Anything that decides "is this node alive"
from the rollup tables has to allow for that (§8).

**Observability.** `system.processing_engine_triggers` lists the triggers;
`system.processing_engine_logs` holds the plugin's INFO/ERROR lines (persisted
lazily — it trails real time by a minute or so).

## 8. Grafana: datasource, dashboards, alerts

Everything under `grafana/provisioning/` is provisioned from files; nothing is
created by hand in the UI, and provisioned dashboards are read-only there.

- **Datasource** `influxdb3`: `type: influxdb`, `version: SQL` (Flight SQL on
  the same port as HTTP), `dbName: sci`, `insecureGrpc: true` (plain http
  inside the compose network), token `$__file{/tokens/.sci-token-plain}`.
- **Fleet overview** (`sci-fleet`): one status stat per node — `UP` when the
  newest `uptime_5s` row is under 30 s old, `DOWN` otherwise or with no data
  (30 s, not 15: see §7) — an uptime stat per node, and an alert-list panel.
  Node titles link to the node dashboards.
- **Node dashboards** (`sci-node-<host>`): generated from
  `node.json.tmpl` by `scripts/gen-node-dashboards.sh` so the three are
  byte-identical modulo host. Rows: *Status* (UP/DOWN, uptime, seconds since
  last sample), *Current values* (cpu, load1, mem, temperature gauges),
  *History* (four time series over `$__timeFilter(time)`). Every query reads a
  `_5s` table and aliases the `_avg` suffix away.
- **Alert rules** (`alerting/rules.yaml`, one group, 10 s evaluation): `CPU
  high` (`usage_active_avg` > 90 for 30 s), `Temperature high` (`temp_c_avg` >
  80 for 30 s), `Node down` (newest `uptime_5s` row older than 45 s for 30 s,
  over a 24 h look-back so a stopped node keeps an alert instance instead of
  vanishing from the result set). The SQL returns `host` plus one number per
  row, which Grafana's expression engine turns into one instance per host.
- **Delivery goes nowhere, twice over.** Grafana 13 ships no contact points
  and a built-in `empty` root receiver; on top of that a catch-all child
  route (`alertname =~ .+`) carries an always-on mute timing. Alerts show as
  Firing in the UI and in the overview's alert list; nothing is sent, nothing
  errors. (A mute timing directly on the root route is rejected by Grafana.)

- **Something is always alerting (chaos on the storage node).** A demo whose
  alert list is empty teaches nothing, so the `storage` node misbehaves on
  purpose, in two independent ways:
  - its mock temperature is a **sine wave** (`inputs.mock.sine_wave`, base
    75 °C, amplitude 12, `period = 0.00833333` = 240 samples per cycle at 1 Hz)
    that sits above the 80 °C threshold for about 87 s of every 4-minute cycle;
    `Temperature high{storage}` fires ~40 s after the crossing (30 s max window
    + 30 s pending) and clears ~30 s after the wave drops back;
  - its agent runs under `telegraf/flap.sh`: **3 min on, 2 min off** (`timeout`
    sends SIGTERM, Telegraf flushes and exits, the script sleeps, repeat). The
    overview card goes `DOWN` ~30 s into the outage, `Node down{storage}` fires
    after ~80 s of silence and clears ~25 s after the agent returns. The
    minimum outage that fires the alert is ~90 s; 30 s never gets past Pending.
  `STORAGE_FLAP`, `STORAGE_UP_S`, `STORAGE_DOWN_S` in `.env` control the
  cycle; `STORAGE_FLAP=false` runs the storage agent like the other two.

Anonymous viewers can open every dashboard; `admin` (password from `.env`) is
only needed for the HTTP API and for editing.

Inside Docker all three nodes show the **same uptime**: `inputs.system` reads
the kernel uptime and every container shares the VM kernel. On real hosts it
is per node.

## 9. Gotchas found while building this

- **collectd measurement names in join mode** are the plugin name only
  (`collectd_cpu`), not `<plugin>_<type>`; the type is the `type` tag.
- **`[inputs.x.tagpass]` must be the last table in its plugin block**; any
  `key = value` after the header becomes part of the tagpass table.
- **The processing-engine log table trails real time** by a minute or more;
  query it with a wide window.
- **Deleting a table only soft-deletes it**: `<name>-<timestamp>` stays in
  `information_schema.tables` and cannot be hard-deleted afterwards. Use
  `--hard-delete now` the first time.
- **License env names.** 3.11 deprecates `INFLUXDB3_ENTERPRISE_LICENSE_*` for
  `INFLUXDB3_LICENSE_EMAIL` / `INFLUXDB3_LICENSE_TYPE`; `home` runs on 2 cores.
- **Alertmanager weekday ranges start on Sunday** (`monday:sunday` is
  invalid), and **mute timings cannot sit on the root route**.

## 10. Security notes

Demo scope, single trust boundary:

- One offline admin token, shared by every service through the volume. The
  plain-text copy is world-readable *inside the volume* because the
  influxdb3 healthcheck, the Telegraf agents and Grafana all read it as
  non-root users.
- No TLS anywhere; Grafana's datasource uses `insecureGrpc` for that reason.
- Grafana anonymous access is `Viewer` only; sign-up is off.
- collectd's network plugin runs with `SecurityLevel None`.

## 11. Scaling to production

- **Tokens.** Give every agent its own write-scoped token
  (`influxdb3 create token --permission "db:sci:write"`) delivered by your
  config management, and give Grafana a read-only token. Drop the `/tokens`
  volume mounts.
- **Real inputs.** On real hosts replace the mocks with `inputs.cpu`,
  `inputs.mem`, `inputs.temp` and keep `inputs.system`; the rename and filter
  blocks already expect those shapes. Keep collectd where it already runs.
- **Retention.** The brief keeps everything for five years. The usual
  production split is a short retention on the raw tables (`create table …
  --retention-period 30d`) and five years on the `_5s` rollups — per-table
  retention overrides the database default.
- **Collection interval.** 1 s is for the demo. At scale, collect every 10 s
  and roll up to 1 min; the trigger arguments (`interval`, `window`, `offset`)
  and the cron are the only knobs.
- **Object store and topology.** Swap `--object-store file` for S3/GCS/Azure,
  and split ingest/query/process nodes as in
  `influxdb3-ref-network-telemetry`. Pin schedule triggers to one node with
  `--node-spec`.
- **TLS** on InfluxDB 3 and Grafana; `insecureGrpc: false` in the datasource.
- **Alert delivery.** Add a contact point and re-point the root policy;
  delete the `always` mute timing.
- **Chaos off.** `STORAGE_FLAP=false`, and give the storage node a real
  temperature input; the sine wave and the outage cycle exist only so the demo
  always has an alert to show.

## 12. Extending: more nodes, more metrics

- **Another node** = another Telegraf config (copy `compute.conf`, change
  `hostname` and ranges) and another compose service. Nothing in InfluxDB or
  Grafana changes for the overview's queries; add a status/uptime card to
  `fleet-overview.json` and a line to `scripts/gen-node-dashboards.sh`.
- **Another metric** = a field on an existing table or a new table: add it to
  `init.sh` (both the raw and the `_5s` table), give the agent an input plus
  the filter/rename lines, add a trigger loop entry, and a panel to the
  template.
- **Alert thresholds** are three numbers in `rules.yaml`.
