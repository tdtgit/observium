# Upgrade and Rollback

How to move this stack to a new image, how to keep the option of going back, and
what actually breaks when you roll back the wrong half.

The short version: the database schema is migrated forward by Observium itself
at container start, and there is no supported downgrade. An upgrade is therefore
only safe to roll back if you took a database dump first and pinned the image
you came from.

Every command runs from the repository directory, where `compose.yaml` and
`.env` live. The commands use the `compose.yaml` defaults — database
`observium`, user `observium`, password `observium`, web port `8080` — so
substitute your `.env` values if you changed them.

## What an upgrade does

`docker compose pull` only downloads. `docker compose up -d` recreates a
container whose image changed; Compose compares the image the container was
created from with the image the tag now resolves to, so a moved `mariadb:11` tag
recreates the `db` container as well.

For the `observium` service, the new container's entrypoint runs this sequence on
every start (`docker/entrypoint.sh`):

| Step | Function | What it changes |
|---|---|---|
| 1 | `configure_php_runtime` | writes `/etc/php/8.5/fpm/conf.d/99-observium-tuning.ini` and the CLI copy |
| 2 | `setup_rrd_ramdisk` | if RAM-disk mode is on, rsyncs `./data/rrd` into `/dev/shm/observium-rrd` |
| 3 | `prepare_config` | rewrites `/opt/observium/config.php`: deletes the `BEGIN/END Docker Managed Settings` block and regenerates it from the `OBSERVIUM_*` env vars |
| 4 | `init_db_schema` | runs `./discovery.php -u` when `OBSERVIUM_INIT_DB_SCHEMA=true` (the Compose default) and retries once on failure |
| 5 | `verify_db_schema` | warns on `lower_case_table_names=2`, repairs `devices.device_id` if it lost `AUTO_INCREMENT`, probes for unreachable tables |
| 6 | `create_admin_user` | creates the admin only when it does not exist |
| 7 | `create_default_dashboard` | creates the default dashboard and seeds widgets only when missing |
| 8 | `start_php_fpm`, `start_cron_if_enabled`, `start_rrd_ramdisk_sync` | starts php-fpm, cron and the RAM-disk sync loop |

Steps 4 and 5 are the ones that touch the database. **The schema migration is
Observium's own update scripts, executed by `discovery.php -u`** — there is no
separate migration tool in this repository and no migration version to track by
hand. That is the whole reason rollback needs a dump.

Step 3 also means: `config.php` is not a user file. The container is replaced by
the upgrade, so anything you edit inside it is gone. Put configuration in
`compose.yaml`, `.env`, or a `compose.override.yaml` that mounts your own file.

## Tags and what to pin

From the README ("Tags and releases"): releases are identified by **build date**.

| Docker tag | Meaning | Stable for rollback |
|---|---|---|
| `:{date}` (e.g. `2026.10.22`) | immutable, one per build | yes — this is the pinning tag |
| `:{version}` (e.g. `25.4.0`) | current image for that Observium version, moves when rebuilt | no |
| `:latest` | rolling | no |

`compose.yaml` uses `${OBSERVIUM_IMAGE:-tuantuantuantuantuan/observium}`; with no
tag that resolves to `:latest`.

### Pin before you upgrade

Pinning *before* pulling is what makes a rollback possible at all: without a
recorded tag or digest you cannot name the image you are leaving.

```bash
cd /path/to/observium
# what the default points at right now
docker compose config --images
# the exact image the running container was created from, and its digest
docker compose images
docker image inspect -f '{{.Id}} {{index .RepoDigests 0}}' tuantuantuantuantuan/observium:latest
```

Write those values down (ticket, runbook, or a comment in `.env`). Then pin:

```bash
# .env in the repository directory
OBSERVIUM_IMAGE=tuantuantuantuantuan/observium:2026.10.22
```

```bash
OBSERVIUM_IMAGE=tuantuantuantuantuan/observium:2026.10.22 docker compose config --images
```

For a digest pin (immune to tag rewrites, and the only way to pin the `db`
service, whose image is not parameterized in `compose.yaml`) see
[docs/PINNING.md](PINNING.md). The digest form is
`tuantuantuantuantuan/observium@sha256:<digest>` and, for the database,
`mariadb@sha256:<digest>` set through a `compose.override.yaml`:

```yaml
services:
  db:
    image: mariadb@sha256:<digest>
```

Pin the database as well if you care about rollback. MariaDB 11.x cannot start a
data directory that a *newer* MariaDB has already upgraded, and there is no
supported downgrade. A moved `mariadb:11` tag can therefore remove your rollback
path even when the Observium image did not change.

## Pre-upgrade checklist

1. **Read the release.** The GitHub release body lists component versions per
   architecture; `release-notes/` documents how non-standard releases are
   described. Check the upstream Observium version the image carries.
2. **Pin and record** the current image tag and digest (above).
3. **Back up**: database dump plus RRD tar, per
   [docs/BACKUP_RESTORE.md](BACKUP_RESTORE.md) sections 1 and 2. For an upgrade
   that touches the database container, take the cold whole-`./data` archive
   (section 3) instead — it is the only backup that restores the datadir mode
   and, in the worst case, the previous MariaDB datadir layout.
4. **Verify the backup restores** if the upgrade matters (the drill in
   BACKUP_RESTORE.md). An upgrade is the day a bad backup costs you the
   deployment.
5. **Record the baseline**:
   ```bash
   docker compose exec -T -e MYSQL_PWD=observium db mariadb -uobservium --batch observium \
     -e "SELECT @@lower_case_table_names; SELECT COUNT(*) AS devices FROM devices; SELECT COUNT(*) AS dashboards FROM dashboards; SELECT COUNT(*) AS widgets FROM dash_widgets;"
   ```
6. **Check the audit trail**: note the Observium version shown on the About page
   in the UI, so you can confirm the upgrade actually happened.
7. **Check disk space**: two image generations plus a dump must fit
   (`docker system df`, `df -h` on the `./data` filesystem).
8. **Pick a quiet window** and stay within it long enough to verify (below). The
   poller does not need stopping — an upgrade recreates the container either way —
   but a failure during a change window with nobody watching is a worse failure.

## Upgrade procedure

```bash
cd /path/to/observium

# 1. fetch the new images (nothing is recreated yet)
docker compose pull

# 2. recreate the containers
docker compose up -d

# 3. watch the boot sequence
docker compose logs --no-log-prefix --follow observium
docker compose logs --no-log-prefix --follow db
```

In the `observium` log, the schema step is explicit. Expect:

```
[entrypoint] Running discovery.php -u (database schema init/update)
...
[entrypoint] Admin user 'admin' already exists; skipping creation
[entrypoint] Starting php-fpm
[entrypoint] Starting cron
```

Interpretation:

- `Running discovery.php -u (database schema init/update)` — this is the schema
  migration. It can take a while on a large database; the container is not
  serving until php-fpm starts.
- `discovery.php -u exited with status N; retrying once` — the first attempt
  failed. The update scripts are idempotent, so the retry usually completes. If
  the retry also fails the next line is
  `ERROR: database schema update failed with status N`: the container still
  starts and serves, but the schema is half-updated. Stop here and roll back
  (below) — do not add devices or run the poller against a half-migrated schema.
- `WARNING: database uses lower_case_table_names=2` — the datadir was created
  with mode 2, which breaks mixed-case tables. That is not caused by the upgrade
  and cannot be fixed in place; see the README's `lower_case_table_names`
  section.
- `Repaired devices.device_id AUTO_INCREMENT` — the entrypoint modified the
  schema during boot. Harmless, but it is a schema write, which is why the dump
  has to be taken before the upgrade.
- `Cron disabled by OBSERVIUM_ENABLE_CRON=false` — expected only if you disabled
  cron; if you did not, it means the environment of the new container is not the
  one you think it is (check `.env` and any `compose.override.yaml`).

Then check the container state:

```bash
docker compose ps
```

Both services should report `healthy` (the `db` healthcheck is
`mariadb-admin ping`, the `observium` healthcheck is an HTTP request to itself).

## How do I know it worked

Run all of these; each one catches a different failure:

```bash
cd /path/to/observium
Q() { docker compose exec -T -e MYSQL_PWD=observium db \
  mariadb -uobservium --batch --skip-column-names observium -e "$1"; }

docker compose ps
docker compose config --images
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/
docker compose logs --no-log-prefix observium | grep -c ERROR
Q "SELECT @@lower_case_table_names;"
Q "SELECT EXTRA FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='observium' AND LOWER(TABLE_NAME)='devices' AND LOWER(COLUMN_NAME)='device_id';"
Q "SELECT COUNT(*) FROM devices;"
Q "SELECT COUNT(*) FROM users WHERE username='admin';"
Q "SELECT COUNT(*) FROM dashboards;"
docker compose exec -T observium php poller.php -h all
docker compose exec -T observium cat /etc/observium-components
```

Expected: `healthy` for both services; the intended image reference
(`docker compose config --images` is the honest answer — it is what Compose will
use, including an `OBSERVIUM_IMAGE` override from `.env`); HTTP `200`; zero
`ERROR` lines; `lower_case_table_names` unchanged from the pre-upgrade baseline;
`device_id` still `auto_increment`; device/user/dashboard counts unchanged
except for legitimate changes; the poller exits `0`; and the component versions
in `/etc/observium-components` match the release note.

Finish in the UI, because the database checks cannot see a PHP-level
incompatibility:

- log in and open the dashboard — it renders, with widgets;
- open a device and two graphs — RRDs are readable by the new RRDtool;
- **About** (Cog menu) shows the new Observium version;
- the footer still shows `FastCache: Yes`, `OPcache: Yes` and your memory limit.

Cleaning up the old image is optional and is not a `docker image prune` job. If
the upgrade moved a tag that nothing else references (typically a fresh
`:latest`, or a `:{version}` tag that has been re-published), the previous image
becomes dangling and `docker image prune` can remove it. A `:{date}` tag is
immutable and still points at the old image, so that one is only removed when
you ask for it by name — `docker image rm <ref>` — and until then it is your
local rollback target. This is exactly why step 2 of the checklist records the
tag and the digest: it tells you which ref to keep and which to remove.

## Rollback

Three cases. Pick the one that matches what the upgrade actually changed.

### Case A — app-only rollback (no schema change)

The new image changed code, PHP or bundled tools, but `discovery.php -u` had
nothing to migrate. Restore the pinned image:

```bash
cd /path/to/observium
export OBSERVIUM_IMAGE=tuantuantuantuantuan/observium:2026.10.22   # or the digest
docker compose up -d
docker compose logs --no-log-prefix --follow observium
```

Keep the variable exported for every later `docker compose` command, or put the
same value in `.env`, otherwise the next `up -d` silently returns to `:latest`.
The dated tag is immutable and stays pullable, so the rollback works even if the
old image is no longer in the local store — and a locally kept `:{date}` image is
not affected by `docker image prune`, because prune only removes dangling
images.

### Case B — rollback after a schema migration

`discovery.php -u` already ran the forward-only update scripts. Restoring the old
image is **not** enough: the old PHP code would run against the new schema.

> **WARNING** — restoring the dump destroys the data written since the backup
> (devices added, alert state, event log). Move the current tree aside instead
> of deleting it, exactly as in BACKUP_RESTORE.md.

Order matters — database first, old image second:

```bash
cd /path/to/observium
STAMP="$(date +%Y%m%dT%H%M%S)"
DUMP=/var/backups/observium/observium-20260101T020000.sql.gz      # pre-upgrade dump
RRD=/var/backups/observium/observium-rrd-20260101T020000.tar.gz   # pre-upgrade RRD tar
export OBSERVIUM_IMAGE=tuantuantuantuantuan/observium:2026.10.22

docker compose down
mv ./data "./data.failed-upgrade-${STAMP}"
mkdir -p ./data/db ./data/rrd ./data/logs

# fresh datadir with the same lower_case_table_names mode as the source
docker compose up -d --wait db
gunzip -c "$DUMP" | docker compose exec -T -e MYSQL_PWD=observium db \
  mariadb -uobservium observium
tar -xzf "$RRD" -C .

docker compose up -d
```

Then run the full post-restore verification in
[docs/BACKUP_RESTORE.md](BACKUP_RESTORE.md). If the upgrade also moved the
`db` image, restore the cold whole-`./data` archive instead of a dump, and pin
the previous MariaDB digest — a datadir upgraded by a newer MariaDB cannot be
opened by the older one.

### Case C — rollback of the database container only

Only possible from a cold `./data` archive (or from a datadir that the newer
MariaDB never opened). MariaDB upgrades the datadir on first start and does not
downgrade. There is no `mariadb-dump`-level fix that makes a newer datadir
readable by an older server.

## What breaks if you roll back the app without the database

Observium's update scripts only go forward. Once a new version has added or
renamed columns, tables or indexes, the old code queries a schema it does not
understand, and you get a deployment that starts and then fails per page:

- SQL errors in the UI (`Unknown column ...`, `Table ... doesn't exist`) and
  blank pages or a stack trace where a device or port list should be;
- the poller failing per device, so graphs stop updating while the cron still
  fires every 5 minutes;
- the entrypoint's own `verify_db_schema` probe reporting unreachable tables and
  advising a schema recreation, which is the "your schema is not what this code
  expects" message;
- data written by the new version being unreadable by the old one — the reason
  Case B restores the dump instead of trying a partial fix.

Upstream does not support schema downgrades. There is no "undo the update
scripts" path in this repository or in the image, and the entrypoint will not
help: it re-runs the same forward updates and then repairs what it can. The
supported recovery is restoring the pre-upgrade dump.

That is the trade the pin buys you: the old image is always available, the old
schema is only available if you took the dump.
