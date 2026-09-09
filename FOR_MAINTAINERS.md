# For maintainers

## Refreshing a license-validated `influxdb-data` volume artifact

A demo machine (or CI) can skip the validation email by restoring a volume
that already holds a validated license:

1. Locally: `make clean && make up`, click the validation link.
2. Wait until `make ps` shows `sci-influxdb3` as `healthy`.
3. `make down` (preserves the volume).
4. Export the volume contents:
   ```bash
   docker run --rm -v influxdb3-ref-scientific-infrastructure_influxdb-data:/data -v "$PWD":/out busybox \
     sh -c "tar czf /out/influxdb-data.tar.gz -C /data ."
   ```
5. Restore it elsewhere with `docker volume create` + a `busybox` copy before
   `make up` (see the portfolio's other repos for the CI workflow shape).

Refresh cadence: monthly, or when the license terms change. Note the license
lives under the cluster id (`/var/lib/influxdb3/sci/trial_or_home_license`).

## Bumping the plugin pin

1. Edit `installer/plugins.lock` (new `version`).
2. `make up` — the installer re-downloads, re-verifies, and overwrites; init's
   delete-and-recreate re-points every trigger at the new
   `downsampler-{version}/downsampler.py` path (init.sh reads the lock file).
3. Check `make cli-example name=rollup-rows` still shows `record_count = 5`
   and `make cli-example name=plugin-logs` shows no `ERROR`.

## Regenerating the node dashboards

`grafana/dashboards/node.json.tmpl` is the source; `make dashboards` writes
`node-daq.json`, `node-compute.json`, `node-storage.json`. Commit the
generated files. Grafana re-reads provisioned dashboards within 10 s; no
restart needed.

## Reloading alert rules without a restart

Alerting provisioning is read at start-up. After editing
`grafana/provisioning/alerting/rules.yaml`:

```bash
curl -s -X POST -u admin:admin http://localhost:3000/api/admin/provisioning/alerting/reload
```

A parse error comes back as HTTP 500 with the reason in `docker compose logs grafana`.

## Common gotchas

- **collectd measurement names.** With `collectd_parse_multivalue = "join"`
  Telegraf names the measurement after the collectd *plugin* only
  (`collectd_cpu`, `collectd_load`, `collectd_memory` with the `collectd_`
  prefix from `name_prefix`); the type is the `type` tag. `split` mode is where
  `<plugin>_<dsname>` names such as `cpu_value` come from.
- **types.db is required** for named multi-value fields. Telegraf ships none;
  without `telegraf/types.db`, `load` arrives as fields `0`, `1`, `2`.
- **`[inputs.x.tagpass]` must be the last thing in its plugin block** — any
  `key = value` after the table header becomes part of the table.
- **The newest rollup row is 10–16 s old by construction** (bucket start
  + 5 s offset + up to 5 s to the next tick). Anything that treats "fresh" as
  younger than that (dashboard status, the node-down alert) flaps.
- **Deleting a table only soft-deletes it** (`<name>-<timestamp>` lingers in
  `information_schema.tables` and cannot be hard-deleted afterwards). Use
  `influxdb3 delete table … --hard-delete now --yes` the first time.
- **Writes older than the retention cutoff are rejected** (HTTP 400, "older
  than the retention period cutoff") — there is no silent backfill past 5 y.
- **License env names.** InfluxDB 3.11 deprecates `INFLUXDB3_ENTERPRISE_LICENSE_*`
  in favour of `INFLUXDB3_LICENSE_EMAIL` / `INFLUXDB3_LICENSE_TYPE` (compose
  already uses the new names). A `home` license runs on 2 cores and is enough
  for this demo; an expired trial fails with `TrialExpired`.
- **The storage node is supposed to flap.** `[flap]` lines in its log and a
  red card for 2 minutes of every 5 are by design (`STORAGE_FLAP=false` to
  stop). Count-based checks on the storage host are only valid during its
  up phase.
- **All three nodes report the same uptime** inside Docker: `inputs.system`
  reads the kernel uptime and every container shares the VM kernel.
