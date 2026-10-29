#!/usr/bin/env bash
# Prove that the documented backup/restore procedure actually works.
#
# Usage: scripts/restore-drill.sh <image-ref> [--keep]
#
# The drill boots the image twice, in two throwaway Compose projects:
#
#   stack A  empty database, a device added through the real add_device.php
#            against a sidecar SNMP agent (scripts/snmpd), one poller run so
#            the RRD tree exists. Then the documented logical dump and RRD tar
#            are taken, and the stack is torn down completely (containers,
#            volumes, project).
#   stack B  a new throwaway directory with a new empty data tree and a
#            different published port. The dump and the RRD tar are restored
#            into it and the result is verified: schema, admin user,
#            dashboards, the original device row, a readable RRD file and a
#            login against the restored web UI.
#
# Everything lives under one `mktemp` directory, so the repository's ./data is
# never touched and a failed drill leaves nothing behind. See
# docs/BACKUP_RESTORE.md for the procedure this script executes.
#
# Environment:
#   DRILL_HTTP_PORT_A      host port for stack A (default: a free port)
#   DRILL_HTTP_PORT_B      host port for stack B (default: a free port)
#   DRILL_ADMIN_USER       login to test (default: admin)
#   DRILL_ADMIN_PASSWORD   password to set and log in with (default:
#                          drill-admin-password)
#   DRILL_EXPECTED_LOWER_CASE_TABLE_NAMES
#                          mode the source must report and the restore must
#                          keep (default: 1, the mode a fresh datadir gets)
#   DRILL_SNMPD_IMAGE      prebuilt test SNMP agent image (default: build
#                          scripts/snmpd into observium-smoke-snmpd:local)
set -euo pipefail

usage() {
  printf 'usage: %s <image-ref> [--keep]\n' "${0##*/}" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
image="$1"
keep="${2:-}"
[ -z "$keep" ] || [ "$keep" = "--keep" ] || usage

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "$script_dir")"

admin_user="${DRILL_ADMIN_USER:-admin}"
admin_password="${DRILL_ADMIN_PASSWORD:-drill-admin-password}"
expected_lctn="${DRILL_EXPECTED_LOWER_CASE_TABLE_NAMES:-1}"
db_user="observium"
db_password="observium"
db_name="observium"
root_password="observium-root"
device_host="drill-host-1"

free_port() {
  local fallback="$1" port=""
  if command -v python3 >/dev/null 2>&1; then
    port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()' || true)"
  fi
  if [ -n "$port" ]; then
    printf '%s' "$port"
  else
    printf '%s' "$fallback"
  fi
}

port_a="${DRILL_HTTP_PORT_A:-$(free_port 18081)}"
port_b="${DRILL_HTTP_PORT_B:-$(free_port 18082)}"
if [ "$port_a" = "$port_b" ]; then
  port_b="$(free_port 18082)"
  [ "$port_a" = "$port_b" ] && port_b=$((port_a + 1))
fi

SECONDS=0
workdir="$(mktemp -d "${TMPDIR:-/tmp}/observium-restore-drill.XXXXXX")"
stack_a="$workdir/stack-a"
stack_b="$workdir/stack-b"
backup_dir="$workdir/backup"
project_a="observium-drill-a-$$"
project_b="observium-drill-b-$$"

log() { printf '[drill] %s\n' "$*"; }

active_stack=""

# A small read-only SNMP agent (scripts/snmpd/) stands in for a monitored host,
# so the drill uses the real add_device.php path instead of inserting rows
# behind Observium's back. Same image the smoke test builds.
snmpd_image="${DRILL_SNMPD_IMAGE:-observium-smoke-snmpd:local}"
if [ -z "${DRILL_SNMPD_IMAGE:-}" ]; then
  log "building the SNMP test host image"
  if ! docker build -q -t "$snmpd_image" "$repo_root/scripts/snmpd" >/dev/null; then
    log "FAIL: could not build the SNMP test host image"
    exit 1
  fi
fi

# The variables below are pinned explicitly instead of inherited, so a shell
# that exports deployment settings (OBSERVIUM_HTTP_PORT, OBSERVIUM_DB_PASSWORD,
# ...) cannot point the drill at a different stack or database. Cron is off:
# the drill polls explicitly, and a cron poller would only add a writer during
# the dump and RRD copy window the procedure says to keep quiet.
compose_a() {
  OBSERVIUM_IMAGE="$image" \
  OBSERVIUM_HTTP_PORT="$port_a" \
  OBSERVIUM_ADMIN_USER="$admin_user" \
  OBSERVIUM_ADMIN_PASSWORD="$admin_password" \
  OBSERVIUM_DB_USER="$db_user" \
  OBSERVIUM_DB_PASSWORD="$db_password" \
  OBSERVIUM_DB_NAME="$db_name" \
  OBSERVIUM_INIT_DB_SCHEMA=true \
  OBSERVIUM_CREATE_ADMIN=true \
  OBSERVIUM_ENABLE_CRON=false \
  OBSERVIUM_ENABLE_RAMDISK=false \
    docker compose --project-name "$project_a" --project-directory "$stack_a" \
      -f "$stack_a/compose.yaml" -f "$stack_a/compose.drill.yaml" "$@"
}

compose_b() {
  OBSERVIUM_IMAGE="$image" \
  OBSERVIUM_HTTP_PORT="$port_b" \
  OBSERVIUM_ADMIN_USER="$admin_user" \
  OBSERVIUM_ADMIN_PASSWORD="$admin_password" \
  OBSERVIUM_DB_USER="$db_user" \
  OBSERVIUM_DB_PASSWORD="$db_password" \
  OBSERVIUM_DB_NAME="$db_name" \
  OBSERVIUM_INIT_DB_SCHEMA=true \
  OBSERVIUM_CREATE_ADMIN=true \
  OBSERVIUM_ENABLE_CRON=false \
  OBSERVIUM_ENABLE_RAMDISK=false \
    docker compose --project-name "$project_b" --project-directory "$stack_b" \
      -f "$stack_b/compose.yaml" "$@"
}

dump_stack() {
  case "${1:-}" in
    a)
      compose_a ps >&2 || true
      compose_a logs --no-log-prefix >&2 || true
      ;;
    b)
      compose_b ps >&2 || true
      compose_b logs --no-log-prefix >&2 || true
      ;;
    *) ;;
  esac
}

fail() {
  printf '[drill] FAIL: %s\n' "$*" >&2
  dump_stack "$active_stack"
  exit 1
}

cleanup() {
  local status=$?
  set +e
  [ -n "${stack_a:-}" ] && compose_a down --volumes --remove-orphans --timeout 20 >/dev/null 2>&1
  [ -n "${stack_b:-}" ] && compose_b down --volumes --remove-orphans --timeout 20 >/dev/null 2>&1
  if [ "$keep" = "--keep" ]; then
    log "Keeping ${workdir}"
  elif [ "$status" -ne 0 ] && [ "${DRILL_KEEP_ON_FAILURE:-0}" = "1" ]; then
    log "Keeping ${workdir} because the drill failed"
  else
    rm -rf "$workdir" 2>/dev/null || log "Could not remove ${workdir} (root-owned files); it is temporary"
  fi
}
trap cleanup EXIT

# Copy the Compose file and the docker/ directory into a throwaway project
# directory. compose.yaml bind-mounts ./docker/db-entrypoint.sh and Compose
# resolves that relative path against the directory of the compose file, so the
# whole directory has to come along. The project name and project directory
# keep the drill containers out of the real stack's namespace.
prepare_stack() {
  mkdir -p "$1/data/db" "$1/data/rrd" "$1/data/logs"
  cp "$repo_root/compose.yaml" "$1/compose.yaml"
  if [ -d "$repo_root/docker" ]; then
    cp -R "$repo_root/docker" "$1/docker"
  fi
}

db_scalar_a() {
  compose_a exec -T -e MYSQL_PWD="$db_password" db \
    mariadb -u"$db_user" --batch --skip-column-names "$db_name" -e "$1"
}

db_scalar_b() {
  compose_b exec -T -e MYSQL_PWD="$db_password" db \
    mariadb -u"$db_user" --batch --skip-column-names "$db_name" -e "$1"
}

wait_for_dir() {
  local path="$1" timeout="$2"
  local deadline=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -d "$path" ] && return 0
    sleep 1
  done
  return 1
}

wait_http() {
  local url="$1" timeout="$2"
  local deadline=$((SECONDS + timeout)) code=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)"
    [ "$code" = "200" ] && return 0
    sleep 2
  done
  printf '[drill] last HTTP status: %s\n' "${code:-no response}" >&2
  return 1
}

# Read the port Docker actually published instead of assuming the compose file
# honoured OBSERVIUM_HTTP_PORT.
published_port() {
  local stack="$1" published=""
  case "$stack" in
    a) published="$(compose_a port observium 80)" ;;
    b) published="$(compose_b port observium 80)" ;;
  esac
  printf '%s\n' "$published" | sed -n '1s/.*://p'
}

mkdir -p "$backup_dir"
prepare_stack "$stack_a"
prepare_stack "$stack_b"

# One SNMP host, reachable by name from the observium container, attached to
# the drill network only. No ports are published.
cat > "$stack_a/compose.drill.yaml" <<EOF
services:
  drill-host-1:
    image: ${snmpd_image}
    hostname: ${device_host}
EOF

log "image: ${image}"
log "workdir: ${workdir}"
log "stack A: project ${project_a}, port ${port_a}"
log "stack B: project ${project_b}, port ${port_b}"

# --- stack A: state to back up ---------------------------------------------
active_stack="a"
log "booting stack A from an empty database"
if ! compose_a up -d --wait --wait-timeout 300; then
  container="$(compose_a ps -a -q observium | sed -n '1p')"
  restarts=0
  if [ -n "$container" ]; then
    restarts="$(docker inspect -f '{{.RestartCount}}' "$container" 2>/dev/null || true)"
    restarts="$(printf '%s' "$restarts" | tr -d '[:space:]')"
    [ -n "$restarts" ] || restarts=0
  fi
  fail "docker compose up on stack A did not reach a healthy state (restarts: ${restarts})"
fi
port_a="$(published_port a)"
[ -n "$port_a" ] || fail "could not determine the published web port of stack A"
log "stack A web UI: http://127.0.0.1:${port_a}"
wait_http "http://127.0.0.1:${port_a}/" 240 || fail "the stack A web UI did not return HTTP 200"

log "waiting for the SNMP test host"
snmp_ready=0
for ((i = 0; i < 60; i++)); do
  if compose_a exec -T observium snmpget -v2c -c public -t 1 -r 0 \
    "$device_host" 1.3.6.1.2.1.1.2.0 >/dev/null 2>&1; then
    snmp_ready=1
    break
  fi
  sleep 1
done
[ "$snmp_ready" = "1" ] || fail "the SNMP test host ${device_host} did not answer"

# add_device.php is the real path: SNMP reachability, OS detection, insert.
# `-p` skips the ICMP check (the container may not answer ping).
log "adding ${device_host} through add_device.php"
if ! compose_a exec -T observium php add_device.php -p "$device_host" public v2c \
  > "$workdir/add-device.log" 2>&1; then
  cat "$workdir/add-device.log" >&2
  fail "add_device.php failed for ${device_host}"
fi
device_id_a="$(db_scalar_a "SELECT device_id FROM devices WHERE hostname='${device_host}';")"
case "$device_id_a" in
  ''|*[!0-9]*) cat "$workdir/add-device.log" >&2; fail "add_device.php did not add ${device_host}" ;;
esac
[ "$device_id_a" -gt 0 ] || fail "the drill device got device_id ${device_id_a}"
log "device_id=${device_id_a} for ${device_host}"

# The poller is what creates rrd/<hostname>/ and the RRD files inside it, so
# run it once against the live SNMP agent.
log "polling ${device_host} to create its RRD directory"
if ! compose_a exec -T observium php poller.php -h "$device_host" \
  > "$workdir/poller-a.log" 2>&1; then
  cat "$workdir/poller-a.log" >&2
  fail "poller.php failed for ${device_host}"
fi
rrd_dir_a="$stack_a/data/rrd/$device_host"
wait_for_dir "$rrd_dir_a" 120 || fail "the poller did not create ${rrd_dir_a}"
find "$rrd_dir_a" -name '*.rrd' -type f | grep -q . \
  || fail "the poller did not create any RRD file in ${rrd_dir_a}"
log "RRD directory created with $(find "$rrd_dir_a" -name '*.rrd' -type f | wc -l | tr -d ' ') RRD file(s)"

# --- record the source mode, then take the documented backup ----------------
log "recording the source lower_case_table_names"
source_lctn="$(db_scalar_a 'SELECT @@lower_case_table_names;')"
[ -n "$source_lctn" ] || fail "could not read @@lower_case_table_names from the source database"
log "source lower_case_table_names=${source_lctn} (expected ${expected_lctn})"
# This is the documented mismatch failure: a dump taken from a mode 1 database
# restored into a datadir created with a different mode loses the mixed case
# tables. Asserting the source mode here makes the drill fail before it can
# certify a restore that could never work.
[ "$source_lctn" = "$expected_lctn" ] \
  || fail "the source database reports lower_case_table_names=${source_lctn}, expected ${expected_lctn}"

stamp="$(date +%Y%m%dT%H%M%S)"
dump="$backup_dir/observium-${stamp}.sql.gz"
rrd_tar="$backup_dir/observium-rrd-${stamp}.tar.gz"
case "$backup_dir/" in
  */data/*) fail "the backup directory ${backup_dir} is inside a data tree" ;;
esac
log "backing up the database to ${dump}"
if ! compose_a exec -T -e MYSQL_PWD="$db_password" db \
  mariadb-dump -u"$db_user" --single-transaction --quick \
  --routines --triggers --events "$db_name" \
  | gzip > "$dump"; then
  fail "mariadb-dump failed"
fi
gzip -t "$dump" || fail "the database dump is not a valid gzip archive"
[ -s "$dump" ] || fail "the database dump is empty"

log "archiving the RRD tree to ${rrd_tar}"
if ! tar -czf "$rrd_tar" -C "$stack_a" data/rrd; then
  fail "could not archive ${stack_a}/data/rrd"
fi
[ -s "$rrd_tar" ] || fail "the RRD archive is empty"
log "backup files: $(du -h "$dump" "$rrd_tar" | awk '{ print $2 " (" $1 ")" }' | tr '\n' ' ')"

# --- tear stack A down completely -------------------------------------------
log "tearing stack A down (containers, volumes, project)"
compose_a down --volumes --remove-orphans --timeout 20 >/dev/null \
  || fail "could not tear stack A down"
[ -z "$(compose_a ps -a -q 2>/dev/null)" ] || fail "stack A still has containers after down"
# The data tree is gone as well: stack B must not be able to read it.
if [ "$keep" != "--keep" ]; then
  rm -rf "$stack_a/data"
fi

# --- stack B: restore into a fresh tree -------------------------------------
active_stack="b"
log "booting stack B from an empty database on port ${port_b}"
if ! compose_b up -d --wait --wait-timeout 300 db; then
  fail "the stack B database did not reach a healthy state"
fi
compose_b exec -T db mariadb-admin ping -h 127.0.0.1 -uroot -p"$root_password" >/dev/null \
  || fail "mariadb-admin ping failed for the stack B database"

log "restoring the database dump into stack B"
if ! gunzip -c "$dump" | compose_b exec -T \
  -e MYSQL_PWD="$db_password" db \
  mariadb -u"$db_user" "$db_name"; then
  fail "the database restore failed"
fi

log "restoring the RRD tree into stack B"
tar -xzf "$rrd_tar" -C "$stack_b" || fail "the RRD restore failed"
[ -d "$stack_b/data/rrd/$device_host" ] \
  || fail "the restored RRD tree has no directory for ${device_host}"

log "starting the rest of stack B on top of the restored data"
if ! compose_b up -d --wait --wait-timeout 300; then
  fail "stack B did not start on top of the restored data"
fi
port_b="$(published_port b)"
[ -n "$port_b" ] || fail "could not determine the published web port of stack B"
log "stack B web UI: http://127.0.0.1:${port_b}"
wait_http "http://127.0.0.1:${port_b}/" 240 || fail "the restored web UI did not return HTTP 200"

restarts="$(docker inspect -f '{{.RestartCount}}' "$(compose_b ps -q observium)")"
[ "$restarts" = "0" ] || fail "the stack B observium container restarted ${restarts} time(s) after the restore"

# --- post-restore assertions (the documented verification checklist) --------
log "verifying the restored schema"
restored_lctn="$(db_scalar_b 'SELECT @@lower_case_table_names;')"
[ "$restored_lctn" = "$expected_lctn" ] \
  || fail "the restored database uses lower_case_table_names=${restored_lctn}, expected ${expected_lctn}"

auto_increment="$(db_scalar_b "SELECT EXTRA FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA='${db_name}' AND LOWER(TABLE_NAME)='devices' AND LOWER(COLUMN_NAME)='device_id';")"
case "$auto_increment" in
  *auto_increment*) ;;
  *) fail "devices.device_id is not AUTO_INCREMENT after the restore (truncated schema import)" ;;
esac

admin_count="$(db_scalar_b "SELECT COUNT(*) FROM users WHERE username='${admin_user}';")"
[ "$admin_count" = "1" ] || fail "expected exactly 1 admin user after the restore, found ${admin_count}"

dashboards="$(db_scalar_b 'SELECT COUNT(*) FROM dashboards;')"
widgets="$(db_scalar_b 'SELECT COUNT(*) FROM dash_widgets;')"
[ -n "$dashboards" ] && [ "$dashboards" -ge 1 ] \
  || fail "expected at least 1 dashboard after the restore, found ${dashboards:-none}"
[ -n "$widgets" ] && [ "$widgets" -ge 6 ] \
  || fail "expected at least 6 dashboard widgets after the restore, found ${widgets:-none}"
log "restored ${dashboards} dashboard(s) with ${widgets} widget(s)"

restored_device_id="$(db_scalar_b "SELECT device_id FROM devices WHERE hostname='${device_host}';")"
[ "$restored_device_id" = "$device_id_a" ] \
  || fail "the restored device row has device_id ${restored_device_id:-missing}, expected ${device_id_a}"

log "verifying the restored RRD data"
compose_b exec -T observium test -d "/opt/observium/rrd/${device_host}" \
  || fail "the restored RRD directory for ${device_host} is missing in the container"
rrd_info="$(compose_b exec -T observium sh -c '
  f="$(find /opt/observium/rrd -name "*.rrd" -type f | head -n 1)"
  [ -n "$f" ] || { echo "no RRD file found under /opt/observium/rrd" >&2; exit 1; }
  echo "$f"
  rrdtool info "$f" | sed -n "1,5p"
')" || fail "rrdtool could not read the restored RRD file"
printf '%s\n' "$rrd_info" | grep -q 'rrd_version' \
  || fail "rrdtool info did not return an RRD header"
log "rrdtool info: $(printf '%s' "$rrd_info" | tr '\n' ' ')"

log "logging in to the restored web UI"
cookie_jar="$workdir/cookies-b.txt"
login_code="$(curl -s -o /dev/null -w '%{http_code}' -c "$cookie_jar" \
  --data-urlencode "username=${admin_user}" \
  --data-urlencode "password=${admin_password}" \
  "http://127.0.0.1:${port_b}/")" || fail "the login request failed"
[ "$login_code" = "302" ] || fail "login returned HTTP ${login_code}"
curl -s -b "$cookie_jar" "http://127.0.0.1:${port_b}/" > "$workdir/dashboard-b.html" \
  || fail "the authenticated request failed"
grep -q 'Logout' "$workdir/dashboard-b.html" \
  || fail "login did not produce an authenticated session"

log "tearing stack B down"
compose_b down --volumes --remove-orphans --timeout 20 >/dev/null \
  || fail "could not tear stack B down"

active_stack=""
log "completed in ${SECONDS}s"
log "PASS: ${image}"
