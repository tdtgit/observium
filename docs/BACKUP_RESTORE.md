# Backup and Restore

How to back up this stack, how to restore it into a fresh `./data` tree, and how
to prove the backup actually restores. Every command runs from the repository
directory (the one with `compose.yaml`), because the Compose project name, the
`.env` file and the `./data` bind mounts all resolve from there.

Back up three things: the database, the RRD tree, and the configuration you
added on top of the repository (`compose.yaml` edits, `.env`, override files).
The database is the only one you cannot rebuild.

## What is stateful

| Host path | Container path | Contents | Rebuildable |
|---|---|---|---|
| `./data/db` | `/var/lib/mysql` | MariaDB datadir: devices, ports, users, dashboards, alert state, event log, plus the `.observium-lower-case-table-names` marker | no |
| `./data/rrd` | `/opt/observium/rrd` | RRDtool files, one directory per device (`<hostname>/`) | only forwards: history is gone, graphs restart empty |
| `./data/logs` | `/opt/observium/logs` | Observium logs | yes, diagnostics only |

`./data/db`, `./data/rrd` and `./data/logs` are ignored by `.gitignore`; nothing
inside them is in version control.

Nothing else needs saving, because the containers regenerate it on every start:

- `/opt/observium/config.php` is rewritten by `docker/entrypoint.sh` from the
  `OBSERVIUM_*` environment variables (`prepare_config`), so the real inputs are
  `compose.yaml`, `.env` and any `compose.override.yaml`;
- `/etc/mysql/conf.d/zz-observium.cnf` is written by `docker/db-entrypoint.sh`
  from the mode of the datadir;
- the nginx configuration and `/etc/cron.d/observium` come from the image.

That means your backup set is:

1. the database dump (or the raw `./data/db` tree from a cold backup),
2. a tar of `./data/rrd`,
3. optionally a tar of `./data/logs`,
4. the repository copy plus `.env` (keep `.env` with the backup, it is not in
   git and it carries credentials).

### What has to be consistent with what

- **The database is authoritative.** It holds the device list. RRD files are
  derived per-device data.
- **A few minutes of skew between DB and RRD is harmless.** A device that exists
  in the database but has no RRD directory gets one on the next poll. An RRD
  directory without a database row is just unreferenced storage — the poller
  never reads it, and you can delete it by hand once you are sure the device is
  gone.
- **A torn database is not harmless.** This is why the procedure below never
  copies `./data/db` while MariaDB is running, and why the cold backup stops the
  stack first.
- **RAM-disk mode adds a window.** With `OBSERVIUM_ENABLE_RAMDISK=true` the
  current data lives in `/dev/shm/observium-rrd` inside the container and
  `docker/entrypoint.sh` rsyncs it to `./data/rrd` every
  `OBSERVIUM_RAMDISK_SYNC_INTERVAL` seconds (default 300). Stopping the
  container does not flush, so `./data/rrd` can be up to one interval behind.
  Flush manually before a backup (see below).
- **Wrap the whole procedure in a quiet window.** Backups are read-mostly, but
  the dump plus RRD copy of a large deployment takes minutes; run it when you
  are not also adding devices.

## 1. Consistent logical database backup (preferred)

This is the backup you restore from. It is a plain SQL file, portable across
MariaDB versions and architectures, and small (a few MB for a few hundred
devices).

```bash
cd /path/to/observium
BACKUP_DIR=/var/backups/observium
STAMP="$(date +%Y%m%dT%H%M%S)"
DB_USER="${OBSERVIUM_DB_USER:-observium}"
DB_PASSWORD="${OBSERVIUM_DB_PASSWORD:-observium}"
DB_NAME="${OBSERVIUM_DB_NAME:-observium}"

mkdir -p "$BACKUP_DIR"
docker compose exec -T -e MYSQL_PWD="$DB_PASSWORD" db \
  mariadb-dump -u"$DB_USER" --single-transaction --quick --routines --triggers --events "$DB_NAME" \
  | gzip > "$BACKUP_DIR/observium-${STAMP}.sql.gz"
gzip -t "$BACKUP_DIR/observium-${STAMP}.sql.gz" && ls -l "$BACKUP_DIR/observium-${STAMP}.sql.gz"
```

The credentials come from the same names the `observium` service uses in
`compose.yaml`. If you changed them in `.env`, export the same variables before
running the block (or edit the three assignments).

Why these flags:

- `--single-transaction` starts one read-only transaction and dumps from that
  snapshot, so the tables are consistent with each other without locking out the
  UI or the poller;
- `--quick` streams rows instead of buffering a full table in memory;
- `--routines --triggers --events` makes the dump complete, so a restore does
  not silently lose objects that are not tables (the Observium schema itself
  only needs the tables, but a dump should not depend on that);
- `-T` on `docker compose exec` disables the TTY, which is required when stdout
  is piped (with a TTY, the output is mangled).

`mariadb-dump` writes no `CREATE DATABASE` and no `USE` without `--databases`,
so the target database must exist and must be named on the restore command.

**Caveat: table engines.** `--single-transaction` guarantees a consistent
snapshot for InnoDB tables only. Check once:

```bash
docker compose exec -T -e MYSQL_PWD="${OBSERVIUM_DB_PASSWORD:-observium}" db \
  mariadb -u"${OBSERVIUM_DB_USER:-observium}" --batch observium \
  -e "SELECT TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'observium' AND ENGINE <> 'InnoDB';"
```

No rows means the dump above is fully consistent. If it lists MyISAM tables,
stop the writer before dumping (it also makes the RRD copy below consistent):

```bash
docker compose stop observium
# dump, RRD tar, logs tar (sections 1-2)
docker compose start observium
```

### Why a raw copy of `./data/db` while MariaDB runs is unsafe

`./data/db` is a live database, not a set of files you can `cp`:

- InnoDB keeps committed pages in memory, replays `ib_logfile*` on crash
  recovery, and writes pages in the background. A file-level copy is a
  point-in-time mix of files from different moments, so the copy is equivalent
  to a crash with a half-written redo log.
- The data dictionary and the table files must agree. Copying `devices.ibd`
  while an `ALTER TABLE` runs can give you a table definition that does not
  match its data.
- Permission and ownership changes mid-copy generally produce a datadir MariaDB
  refuses to start, which turns a backup into a second outage.

Copy the datadir only when MariaDB is **stopped** (section 3), or not at all.

## 2. RRD and logs

RRD files are rewritten on every poll. A tar that catches a file mid-rewrite can
archive a truncated RRD; `rrdtool` then refuses that one file and the graph
stays empty. That is recoverable — delete the broken file and the next poll
recreates it with empty history — but stopping the poller avoids it entirely.

```bash
cd /path/to/observium
BACKUP_DIR=/var/backups/observium
STAMP="$(date +%Y%m%dT%H%M%S)"

# RAM-disk mode only: flush /dev/shm/observium-rrd to ./data/rrd first.
# Same rsync form the entrypoint's sync loop uses.
docker compose exec -T observium rsync -a /dev/shm/observium-rrd/ /opt/observium/rrd/

tar -czf "$BACKUP_DIR/observium-rrd-${STAMP}.tar.gz" -C . data/rrd
tar -czf "$BACKUP_DIR/observium-logs-${STAMP}.tar.gz" -C . data/logs
```

`-C . data/rrd` stores the paths as `data/rrd/...`, so the archive extracts at
the repository root without touching anything else.

The skip of the `rsync` line when RAM-disk mode is off is deliberate: with
`OBSERVIUM_ENABLE_RAMDISK=false` (the Compose default) nothing writes
`/dev/shm/observium-rrd`, and `rsync` would fail on the missing source.

To reduce RRD skew to zero, stop the poller for the duration of the copy. Cron
is the only writer, and `docker compose stop observium` stops it:

```bash
docker compose stop observium
tar -czf /var/backups/observium/observium-rrd-"$(date +%Y%m%dT%H%M%S)".tar.gz -C . data/rrd
docker compose start observium
```

The stack is not monitoring while `observium` is stopped, so keep that window
short and outside of expectations.

### Hardlinks and inodes

Observium writes ordinary per-device files; nothing in `./data/rrd` is normally
hardlinked. Verify instead of assuming:

```bash
find ./data/rrd -type f -links +1 | head
```

No output means a plain file tree and any `tar` handles it. If entries are
printed, the files are hardlinked (a `cp -al` or `rsync --link-dest` restore
does that); `tar` keeps links inside one archive, but two separate archives of
the same tree would silently double the size.

## 3. Cold full-stack backup (whole `./data` tree)

Simplest and most faithful: no dump, no consistency reasoning, one archive. It
costs downtime and it is the only backup that reproduces a non-default
`lower_case_table_names` mode byte for byte (it includes
`./data/db/.observium-lower-case-table-names`).

```bash
cd /path/to/observium
BACKUP_DIR=/var/backups/observium
STAMP="$(date +%Y%m%dT%H%M%S)"

docker compose stop
tar -czf "$BACKUP_DIR/observium-data-${STAMP}.tar.gz" -C . data
docker compose up -d
ls -l "$BACKUP_DIR/observium-data-${STAMP}.tar.gz"
```

`docker compose stop` sends SIGTERM and waits for MariaDB to shut down cleanly,
so the datadir in the archive is a clean shutdown, not a crash image.
`docker compose up -d` brings the same containers back.

On a Linux host the datadir files belong to the MariaDB uid inside the container
(999 by default) and `./data/logs` to `www-data`; read them as root and keep the
numeric owners so a restore does not change them:

```bash
sudo tar -czf "/var/backups/observium/observium-data-$(date +%Y%m%dT%H%M%S).tar.gz" \
  --numeric-owner -C /path/to/observium data
```

> **WARNING** — do not write the archive into `./data`. It would be picked up by
> the next cold backup, grows without bound, and is destroyed by the
> "reset all local data" procedure in the README (`rm -rf ./data/db ...`). Keep
> `BACKUP_DIR` outside the repository.

## Restore

Restore into a **fresh** `./data` tree. Do not restore over a live datadir, and
do not delete the old tree until the restore has been verified: rename it, keep
it, and remove it after the verification checklist passes.

### Step 0 - record the mode of the source database

`lower_case_table_names` can only be chosen while a data directory is created,
and a datadir keeps the mode it was created with. Read it from the source before
you touch anything, and from the backup if the source is already gone:

```bash
docker compose exec -T -e MYSQL_PWD="${OBSERVIUM_DB_PASSWORD:-observium}" db \
  mariadb -u"${OBSERVIUM_DB_USER:-observium}" --batch --skip-column-names observium \
  -e "SELECT @@lower_case_table_names;"
```

The expected value for a datadir created by this stack is `1`. A fresh
`./data/db` is always created with `1` by `docker/db-entrypoint.sh`, which also
records the mode in `./data/db/.observium-lower-case-table-names`.

Why the mode has to match: the dump stores table names as written
(``CREATE TABLE `bgpPeers` ``), and the mode decides how the restored datadir
stores and looks them up. Restoring a dump taken from a mode `1` database into a
datadir created with mode `0` gives you lowercase stored names while Observium
queries mixed case names (`bgpPeers`, `entPhysical`, `hrDevice`), so those tables
become unreachable and schema updates stop on the first missing table. The
reverse direction (mode `0` or `2` source into a fresh mode `1` tree) stores
everything lowercase and works, but the source mode `2` datadir was already
broken in other ways. See the `lower_case_table_names` section in the
[README](../README.md) for why mode `2` breaks the schema import — do not
duplicate that reasoning here, and do not try to change the mode of an existing
datadir.

If the source reports anything other than `1`, restore the cold `./data` archive
(section 3) instead of the logical dump: it carries the marker file, so the
restored datadir is created with the original mode automatically.

### Step 1 - stop the stack and move the old tree aside

> **WARNING** — every command below changes or removes data. `mv` first, delete
> only after the verification checklist passes.

```bash
cd /path/to/observium
STAMP="$(date +%Y%m%dT%H%M%S)"

docker compose down
mv ./data "./data.replaced-${STAMP}"
mkdir -p ./data/db ./data/rrd ./data/logs
```

`docker compose down` here removes the containers, not the data; the trees are
bind mounts, so they survive and are simply moved.

### Step 2 - start only the database and let it initialise

```bash
docker compose up -d --wait db
docker compose exec -T db mariadb-admin ping -h 127.0.0.1 -uroot -pobservium-root
```

The MariaDB entrypoint creates the datadir (mode `1`), the `observium` database
and the `observium` user with its grants from the `MARIADB_*` values in
`compose.yaml`. `--wait` blocks until the service healthcheck passes, and the
ping confirms the credentials you are about to use (`observium-root` is the
compose default; substitute `MARIADB_ROOT_PASSWORD` if you changed it).
`docker compose ps db` shows the same health state.

### Step 3 - load the dump

> **WARNING** — this replaces every table in the target database.

```bash
cd /path/to/observium
DUMP=/var/backups/observium/observium-20260101T020000.sql.gz

gunzip -c "$DUMP" | docker compose exec -T \
  -e MYSQL_PWD="${OBSERVIUM_DB_PASSWORD:-observium}" db \
  mariadb -u"${OBSERVIUM_DB_USER:-observium}" observium
```

The database name is given to the client because the dump contains no `USE`.
If the restore stops with an error about `DEFINER` or `SUPER`, the dump contains
stored routines the `observium` user may not recreate; restore it as root
instead (`-uroot -pobservium-root`, or the `MARIADB_ROOT_PASSWORD` you set).
The reference stack runs MariaDB with `--skip-log-bin` (see the
`MARIADB_BINLOG_OPTION` row in the README), so binary logging normally does not
get in the way.

### Step 4 - restore RRD and logs

```bash
cd /path/to/observium
tar -xzf /var/backups/observium/observium-rrd-20260101T020000.tar.gz -C .
tar -xzf /var/backups/observium/observium-logs-20260101T020000.tar.gz -C .
```

`docker/entrypoint.sh` chowns `./data/rrd` and `./data/logs` to `www-data` on
start, so a restore as a different user does not leave the poller unable to
write.

### Step 5 - start the application

```bash
docker compose up -d
docker compose logs --no-log-prefix --follow observium
```

On this first start the entrypoint runs `discovery.php -u` (because
`OBSERVIUM_INIT_DB_SCHEMA` is `true` in `compose.yaml`), then
`verify_db_schema`, then the admin-user and dashboard steps. A restored
database already contains the schema, the admin user and the dashboards, so
these steps should log

- `Running discovery.php -u (database schema init/update)` with no following
  `ERROR: database schema update failed`;
- `Admin user 'admin' already exists; skipping creation`;
- `Starting php-fpm`.

Stop following the log with Ctrl-C once php-fpm is up.

## Post-restore verification

Run the checks below in order. They are the same checks the release smoke test
uses (`scripts/smoke-compose.sh`), applied to the restored deployment.

```bash
cd /path/to/observium
Q() { docker compose exec -T -e MYSQL_PWD="${OBSERVIUM_DB_PASSWORD:-observium}" db \
  mariadb -u"${OBSERVIUM_DB_USER:-observium}" --batch --skip-column-names observium -e "$1"; }

Q "SELECT @@lower_case_table_names;"
Q "SELECT EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='observium' AND LOWER(TABLE_NAME)='devices' AND LOWER(COLUMN_NAME)='device_id';"
Q "SELECT COUNT(*) FROM users WHERE username='admin';"
Q "SELECT COUNT(*) FROM dashboards;"
Q "SELECT COUNT(*) FROM dash_widgets;"
Q "SELECT COUNT(*) FROM devices;"
Q "SELECT COUNT(*) FROM ports;"
```

Expected:

- `@@lower_case_table_names` is `1` (or the mode the source reported).
- the `device_id` `EXTRA` contains `auto_increment` — the check from the
  [README](../README.md) "Verify the database schema" section and the failure
  mode it describes (`Duplicate entry '0' for key 'PRIMARY'` on the second
  device) must not be present;
- exactly `1` admin user row (more than one means the admin was created twice
  against a restored schema — a sign the dump did not come from this
  deployment);
- dashboards and `dash_widgets` are non-zero, and match what you expect from
  before the restore;
- the device and port counts match the source at backup time.

Then the application-level checks:

```bash
docker compose ps
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/
docker compose exec -T observium php poller.php -h all
docker compose logs --no-log-prefix observium | grep -c ERROR
```

- `docker compose ps` shows both services `healthy`.
- The web UI answers `200` (change `8080` if you set `OBSERVIUM_HTTP_PORT`).
- Log in through the UI, confirm the device list shows every device, and open one
  device's graphs — a rendered graph proves both the RRD tree and the database
  row for that device are present.
- One RRD file is readable by the image's own RRDtool. `rrdtool info` parses the
  header, so a truncated archive left by a mid-poll copy fails here instead of
  silently rendering an empty graph:

```bash
docker compose exec -T observium sh -c 'f=$(find /opt/observium/rrd -name "*.rrd" | head -n 1); echo "$f"; rrdtool info "$f" | head -n 5'
```

  Expected: a path under `/opt/observium/rrd` followed by `filename`,
  `rrd_version`, `step` and `last_update`. An empty `find` result means no device
  has been polled yet (`rrdtool info` then errors on the empty argument) — on a
  real restore that means the RRD archive did not go back, so check
  `./data/rrd` before continuing.
- The poller run exits `0` and prints one section per device. `-h all` is the
  upstream-documented "poll all devices" form; the cron scheduler uses
  `observium-wrapper poller` every 5 minutes (`docker/observium.cron`).
  `php poller.php -h all` is the one-shot form for a single verification run,
  the same way `php add_device.php` is used in `scripts/smoke-compose.sh`. If
  cron fires while your manual run is in progress, that device gets one extra
  poll, which is harmless.
- `grep -c ERROR` prints `0`; any `ERROR` line is a failure to investigate
  before you delete the old tree — the entrypoint uses that word specifically.

Finally check the UI footer for `FastCache: Yes`, `OPcache: Yes` and the
configured `Memory:` value, as described in the README.

Only after all of the above pass, remove the old tree:

```bash
rm -rf ./data.replaced-20260101T020000
```

## Backup verification drill

An unverified backup is not a backup. Once a month — and before any upgrade —
restore the newest dump into a throwaway project and check the counts. This is
the same idea as `scripts/smoke-compose.sh`, which boots the stack in a
`mktemp -d` directory against an empty database so the real `./data` is never
involved.

```bash
cd /path/to/observium
DRILL="$(mktemp -d "${TMPDIR:-/tmp}/observium-restore.XXXXXX")"
DUMP=/var/backups/observium/observium-20260101T020000.sql.gz
RRD=/var/backups/observium/observium-rrd-20260101T020000.tar.gz
PORT=18081

cp compose.yaml "$DRILL/compose.yaml"
cp -R docker "$DRILL/docker"
mkdir -p "$DRILL/data/db" "$DRILL/data/rrd" "$DRILL/data/logs"

compose=(docker compose --project-name observium-drill \
  --project-directory "$DRILL" -f "$DRILL/compose.yaml")
export OBSERVIUM_HTTP_PORT="$PORT"

"${compose[@]}" up -d --wait db
"${compose[@]}" exec -T db mariadb-admin ping -h 127.0.0.1 -uroot -pobservium-root
gunzip -c "$DUMP" | "${compose[@]}" exec -T \
  -e MYSQL_PWD="${OBSERVIUM_DB_PASSWORD:-observium}" db mariadb -uobservium observium
tar -xzf "$RRD" -C "$DRILL"
"${compose[@]}" up -d
```

Notes that make this a drill and not an incident:

- `--project-directory "$DRILL"` plus a distinct `--project-name` is what keeps
  the drill containers and network out of the production project's namespace,
  so `down` on the drill cannot touch the real stack. Do not reuse the
  production project name for a second stack.
- `cp -R docker` is required: `compose.yaml` bind-mounts
  `./docker/db-entrypoint.sh`, and Compose resolves that relative path against
  the directory of the compose file.
- A different `OBSERVIUM_HTTP_PORT` avoids colliding with the running stack.
- The drill's `./data` is the throwaway directory's own tree. Never point a
  second project at the production `./data`.

Then verify the drill the same way as a real restore (the `Q()` checks above,
run against the drill project), and tear it down — in the same shell, so the
`compose` array is still defined:

```bash
"${compose[@]}" down --remove-orphans
rm -rf "$DRILL"
```

Record the date and the device count of the last successful drill. A dump that
has never been restored is worth nothing on the day you need it.

## Automation and retention

Suggested policy: 14 daily dumps, the RRD and log tars for 7 days, one cold
full-`data` archive per month kept for a year. At a few hundred devices a
gzipped dump is single-digit MB, so retention is cheap; the RRD tar is the big
one, since it grows with the number of ports and the length of the history.

A cron-driven backup script (put it outside the repository, for example
`/usr/local/bin/observium-backup.sh`, and `chmod 0700` because it can read
credentials):

```bash
#!/usr/bin/env bash
set -euo pipefail

REPO=/path/to/observium
BACKUP_DIR=/var/backups/observium
DB_USER="${OBSERVIUM_DB_USER:-observium}"
DB_PASSWORD="${OBSERVIUM_DB_PASSWORD:-observium}"
DB_NAME="${OBSERVIUM_DB_NAME:-observium}"
STAMP="$(date +%Y%m%dT%H%M%S)"

# Run Compose from the repository: project name, .env and the ./data bind
# mounts all resolve from this directory.
cd "$REPO"
mkdir -p "$BACKUP_DIR"

dump="$BACKUP_DIR/observium-${STAMP}.sql.gz"
part="${dump}.part"
trap 'rm -f "$part"' EXIT
docker compose exec -T -e MYSQL_PWD="$DB_PASSWORD" db \
  mariadb-dump -u"$DB_USER" --single-transaction --quick \
  --routines --triggers --events "$DB_NAME" \
  | gzip > "$part"
gzip -t "$part"
mv "$part" "$dump"

tar -czf "$BACKUP_DIR/observium-rrd-${STAMP}.tar.gz" -C "$REPO" data/rrd
tar -czf "$BACKUP_DIR/observium-logs-${STAMP}.tar.gz" -C "$REPO" data/logs

find "$BACKUP_DIR" -type f -name 'observium-*.sql.gz' -mtime +14 -delete
find "$BACKUP_DIR" -type f -name 'observium-rrd-*.tar.gz' -mtime +7 -delete
find "$BACKUP_DIR" -type f -name 'observium-logs-*.tar.gz' -mtime +7 -delete
# Incomplete dumps from a killed run.
find "$BACKUP_DIR" -type f -name '*.part' -mtime +1 -delete
```

Install it in the root crontab (it needs read access to `./data` and to talk to
the Docker socket):

```cron
17 2 * * * /usr/local/bin/observium-backup.sh >> /var/log/observium-backup.log 2>&1
```

Rules for the script and the schedule:

- Write to `"${dump}.part"` and rename only after `gzip -t` passes, so a failed
  run never leaves a truncated file that looks like a good backup. The `EXIT`
  trap removes the partial file when the run dies, and the `*.part` line in the
  retention block covers a `SIGKILL` or a reboot.
- `set -o pipefail` is required: without it a failing `mariadb-dump` is masked by
  a successful `gzip`.
- `cd "$REPO"` is the project-directory correctness point. `docker compose` with
  only `-f /path/compose.yaml` also works (relative bind mounts resolve against
  the compose file's directory), but the project name then follows the compose
  file's directory, and a `-p` name that differs from the one the stack was
  created with addresses a different set of containers. Either always run from
  the repository, or always pass the same `-p` **and** `--project-directory`.
- Never let `BACKUP_DIR` live under `./data`: it would be swallowed by the next
  cold backup, grow every day, and be deleted by the data reset in the README.
- Send the archives off the host (rsync, restic, your existing backup system).
  A backup on the same disk as the datadir does not survive that disk.
- The dump requires the `db` service to be running. If the stack is down, take a
  cold backup (`docker compose stop` is a no-op then, and tar of `./data` works).
- Run the drill above against one of the archives at least monthly; the cron
  script cannot tell you whether a restore works.
