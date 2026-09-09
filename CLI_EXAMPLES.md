# Curated CLI examples

Run any example with:

```bash
make cli-example name=<example>
```

Each block runs inside the `influxdb3` container with `TOKEN` exported.
(For an interactive shell instead: `make cli`.)

## list-databases

```bash
influxdb3 show databases --token $TOKEN
```

## show-retention

Five years on every table, inherited from the database:

```bash
influxdb3 show retention --token $TOKEN
```

## rate-per-node

One row per second per node — three agents, three sources, one table:

```bash
influxdb3 query --database sci --token $TOKEN "SELECT host, count(*) AS rows_last_30s FROM cpu WHERE time > now() - INTERVAL '30 seconds' GROUP BY host ORDER BY host"
```

## nanosecond-timestamps

Nine fractional digits on every row (the Telegraf default would round these to whole seconds):

```bash
influxdb3 query --database sci --token $TOKEN "SELECT time, host, usage_active FROM cpu ORDER BY time DESC LIMIT 5"
```

## whole-second-rows

The same claim as a number — should be 0:

```bash
influxdb3 query --database sci --token $TOKEN "SELECT count(*) AS whole_second_rows FROM cpu WHERE CAST(time AS BIGINT) % 1000000000 = 0"
```

## rollup-rows

5-second rollups with the downsampler's audit metadata — `record_count` is 5 on every complete bucket:

```bash
influxdb3 query --database sci --token $TOKEN "SELECT time, host, usage_active_avg, record_count FROM cpu_5s ORDER BY time DESC LIMIT 6"
```

## rollup-vs-raw

The rollup average equals the raw average over the same bucket:

```bash
influxdb3 query --database sci --token $TOKEN "SELECT c.time, c.host, c.usage_active_avg, r.avg_raw FROM cpu_5s c JOIN (SELECT date_bin(INTERVAL '5 seconds', time) AS b, host, avg(usage_active) AS avg_raw FROM cpu WHERE time > now() - INTERVAL '2 minutes' GROUP BY b, host) r ON r.b = c.time AND r.host = c.host ORDER BY c.time DESC LIMIT 6"
```

## compression-ratio

Raw rows versus rollup rows (5:1 at steady state):

```bash
influxdb3 query --database sci --token $TOKEN "SELECT (SELECT count(*) FROM cpu) AS raw_rows, (SELECT count(*) FROM cpu_5s) AS rollup_rows"
```

## list-triggers

The five downsampling triggers as the engine sees them:

```bash
influxdb3 query --database sci --token $TOKEN "SELECT trigger_name, plugin_filename, trigger_specification, disabled FROM system.processing_engine_triggers ORDER BY trigger_name"
```

## plugin-logs

What the downsampler is logging (the log table trails real time by a minute or so):

```bash
influxdb3 query --database sci --token $TOKEN "SELECT event_time, trigger_name, log_level, log_text FROM system.processing_engine_logs ORDER BY event_time DESC LIMIT 10"
```
