#!/usr/bin/env bash
# Boot the Compose stack against an image and verify the application works.
#
# Usage: scripts/smoke-compose.sh <image-ref> [--keep]
#
# The stack runs in a throwaway directory, so it always starts from an empty
# database and never touches ./data. It checks that the container comes up
# without restarting, the login works, the schema is complete, devices can be
# added and deleted, and that a second start of the entrypoint is idempotent
# (no duplicate-key failures). Two sidecar SNMP agents (scripts/snmpd) stand in
# for monitored hosts, so the real add_device.php/delete_device.php paths run.
#
# Environment:
#   SMOKE_HTTP_PORT        host port for the web UI (default: a free port)
#   SMOKE_ADMIN_USER       login to test (default: admin)
#   SMOKE_ADMIN_PASSWORD   password to test (default: admin)
#   SMOKE_SNMPD_IMAGE      prebuilt test SNMP agent image (default: build
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

admin_user="${SMOKE_ADMIN_USER:-admin}"
admin_password="${SMOKE_ADMIN_PASSWORD:-admin}"
port="${SMOKE_HTTP_PORT:-}"

if [ -z "$port" ]; then
  if command -v python3 >/dev/null 2>&1; then
    port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
  else
    port=18080
  fi
fi

workdir="$(mktemp -d "${TMPDIR:-/tmp}/observium-smoke.XXXXXX")"
project="observium-smoke-$$"

log() { printf '[smoke] %s\n' "$*"; }

# Small read-only SNMP agent (scripts/snmpd/) that stands in for a monitored
# host, so the smoke test can use the real add_device.php path instead of
# inserting rows behind its back.
snmpd_image="${SMOKE_SNMPD_IMAGE:-observium-smoke-snmpd:local}"
if [ -z "${SMOKE_SNMPD_IMAGE:-}" ]; then
  log "building the SNMP test host image"
  if ! docker build -q -t "$snmpd_image" "$repo_root/scripts/snmpd" >/dev/null; then
    log "FAIL: could not build the SNMP test host image"
    exit 1
  fi
fi

compose=(docker compose --project-name "$project" --project-directory "$workdir" \
  -f "$workdir/compose.yaml" -f "$workdir/compose.smoke.yaml")

cleanup() {
  "${compose[@]}" down --volumes --remove-orphans --timeout 20 >/dev/null 2>&1 || true
  if [ "$keep" = "--keep" ]; then
    log "Keeping ${workdir}"
  else
    rm -rf "$workdir" 2>/dev/null || log "Could not remove ${workdir} (root-owned files); it is temporary"
  fi
}
trap cleanup EXIT

fail() {
  printf '[smoke] FAIL: %s\n' "$*" >&2
  "${compose[@]}" ps >&2 || true
  "${compose[@]}" logs --no-log-prefix >&2 || true
  exit 1
}

mkdir -p "$workdir"
cp "$repo_root/compose.yaml" "$workdir/compose.yaml"
# The compose file bind-mounts files from docker/ (the database entrypoint in
# particular). Copy the whole directory when it exists, so the test also runs
# against compose files that mount fewer files.
if [ -d "$repo_root/docker" ]; then
  cp -R "$repo_root/docker" "$workdir/docker"
fi

# Two SNMP hosts reachable by name from the observium container. They are only
# attached to the Compose network; no ports are published.
cat > "$workdir/compose.smoke.yaml" <<EOF
services:
  smoke-host-1:
    image: ${snmpd_image}
    hostname: smoke-host-1
  smoke-host-2:
    image: ${snmpd_image}
    hostname: smoke-host-2
EOF

export OBSERVIUM_IMAGE="$image"
export OBSERVIUM_HTTP_PORT="$port"
# The image generates a random admin password when this is empty.
export OBSERVIUM_ADMIN_USER="$admin_user"
export OBSERVIUM_ADMIN_PASSWORD="$admin_password"

log "image: ${image}"
log "workdir: ${workdir}"

db_scalar() {
  "${compose[@]}" exec -T -e MYSQL_PWD=observium db \
    mariadb -uobservium --batch --skip-column-names observium -e "$1"
}

wait_http() {
  local deadline=$((SECONDS + 180)) code=""
  while [ "$SECONDS" -lt "$deadline" ]; do
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" || true)"
    [ "$code" = "200" ] && return 0
    sleep 2
  done
  fail "web UI did not return HTTP 200 within 180s (last: ${code:-no response})"
}

contains() { grep -q -- "$1" "$2"; }
not_contains() { ! grep -q -- "$1" "$2"; }

log "starting the stack from an empty database"
if ! "${compose[@]}" up -d --wait --wait-timeout 300; then
  # `--wait` aborts as soon as a container exits, even when the restart policy
  # brings it back. Report the restart, which is the actual failure.
  container="$("${compose[@]}" ps -a -q observium | sed -n '1p')"
  restarts=0
  if [ -n "$container" ]; then
    restarts="$(docker inspect -f '{{.RestartCount}}' "$container" 2>/dev/null || true)"
    restarts="$(printf '%s' "$restarts" | tr -d '[:space:]')"
    [ -n "$restarts" ] || restarts=0
  fi
  if [ "$restarts" != "0" ]; then
    fail "the observium container restarted ${restarts} time(s) during startup"
  fi
  fail "docker compose up did not reach a healthy state"
fi

# Read the port Docker actually published instead of assuming the compose file
# honoured OBSERVIUM_HTTP_PORT (older compose files hardcode 8080).
published="$("${compose[@]}" port observium 80)"
port="$(printf '%s\n' "$published" | sed -n '1s/.*://p')"
[ -n "$port" ] || fail "could not determine the published web port"
log "web UI: http://127.0.0.1:${port}"

restarts="$(docker inspect -f '{{.RestartCount}}' "$("${compose[@]}" ps -q observium)")"
[ "$restarts" = "0" ] || fail "the observium container restarted ${restarts} time(s) during startup"

wait_http

"${compose[@]}" logs --no-log-prefix observium > "$workdir/boot.log" 2>&1
contains 'Starting php-fpm' "$workdir/boot.log" || fail "php-fpm did not start"
contains 'Created default dashboard' "$workdir/boot.log" || fail "the default dashboard was not created"
contains 'Seeded classic dashboard widgets' "$workdir/boot.log" || fail "the dashboard widgets were not seeded"
if contains 'ERROR' "$workdir/boot.log"; then
  fail "the entrypoint reported an error during startup (see log above)"
fi

log "checking the database schema"
[ "$(db_scalar 'SELECT @@lower_case_table_names;')" = "1" ] \
  || fail "the database was not created with lower_case_table_names=1"

auto_increment="$(db_scalar "SELECT EXTRA FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA='observium' AND LOWER(TABLE_NAME)='devices' AND LOWER(COLUMN_NAME)='device_id';")"
case "$auto_increment" in
  *auto_increment*) ;;
  *) fail "devices.device_id is not AUTO_INCREMENT (truncated schema import)" ;;
esac

[ "$(db_scalar "SELECT COUNT(*) FROM users WHERE username='${admin_user}';")" = "1" ] \
  || fail "the admin user was not created exactly once"

dashboards="$(db_scalar 'SELECT COUNT(*) FROM dashboards;')"
widgets="$(db_scalar 'SELECT COUNT(*) FROM dash_widgets;')"
[ "$dashboards" = "1" ] || fail "expected 1 dashboard, found ${dashboards}"
[ "$widgets" -ge 6 ] || fail "expected at least 6 dashboard widgets, found ${widgets}"

log "checking that an unauthenticated request is not logged in"
anonymous_jar="$workdir/cookies-anonymous.txt"
curl -s -c "$anonymous_jar" "http://127.0.0.1:${port}/" > "$workdir/anonymous.html"
not_contains 'Logout' "$workdir/anonymous.html" \
  || fail "an unauthenticated request rendered an authenticated session"

log "checking the login"
cookie_jar="$workdir/cookies.txt"
login_code="$(curl -s -o /dev/null -w '%{http_code}' -c "$cookie_jar" \
  --data-urlencode "username=${admin_user}" \
  --data-urlencode "password=${admin_password}" \
  "http://127.0.0.1:${port}/")"
[ "$login_code" = "302" ] || fail "login returned HTTP ${login_code}"
curl -s -b "$cookie_jar" "http://127.0.0.1:${port}/" > "$workdir/dashboard.html"
contains 'Logout' "$workdir/dashboard.html" || fail "login did not produce an authenticated session"

log "checking that a wrong password is rejected"
wrong_jar="$workdir/cookies-wrong.txt"
wrong_code="$(curl -s -o /dev/null -w '%{http_code}' -c "$wrong_jar" \
  --data-urlencode "username=${admin_user}" \
  --data-urlencode "password=${admin_password}-wrong" \
  "http://127.0.0.1:${port}/")"
curl -s -b "$wrong_jar" "http://127.0.0.1:${port}/" > "$workdir/wrong-password.html"
not_contains 'Logout' "$workdir/wrong-password.html" \
  || fail "a wrong password (HTTP ${wrong_code}) produced an authenticated session"
log "wrong password returned HTTP ${wrong_code} and no session"

# add_device.php is the real path: SNMP reachability, OS detection, insert. It
# needs a live SNMP agent, which the two smoke-host sidecars provide. `-p`
# skips the ICMP check (the container may not answer ping).
log "adding and deleting smoke devices"
smoke_hosts="smoke-host-1 smoke-host-2"
smoke_hosts_sql="'smoke-host-1','smoke-host-2'"
device_ids=""
for host in $smoke_hosts; do
  ready=0
  for ((i = 0; i < 30; i++)); do
    if "${compose[@]}" exec -T observium snmpget -v2c -c public -t 1 -r 0 \
      "$host" 1.3.6.1.2.1.1.2.0 >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" = "1" ] || fail "the SNMP test host ${host} did not answer"

  if ! "${compose[@]}" exec -T observium php add_device.php -p "$host" public v2c \
    > "$workdir/device.log" 2>&1; then
    cat "$workdir/device.log" >&2
    fail "add_device.php failed for ${host}"
  fi

  device_id="$(db_scalar "SELECT device_id FROM devices WHERE hostname='${host}';")"
  case "$device_id" in
    ''|*[!0-9]*) cat "$workdir/device.log" >&2; fail "add_device.php did not add ${host}" ;;
  esac
  [ "$device_id" -gt 0 ] || fail "the smoke device ${host} got device_id ${device_id}"

  # The poller is what creates rrd/<hostname>/ and the RRD files inside it, so
  # run it once per device against the live SNMP agent: the real graphing path,
  # not a database-only check.
  log "polling ${host}"
  if ! "${compose[@]}" exec -T observium php poller.php -h "${host}" \
    > "$workdir/poller-${host}.log" 2>&1; then
    cat "$workdir/poller-${host}.log" >&2
    fail "poller.php failed for ${host}"
  fi

  rrd_dir="/opt/observium/rrd/${host}"
  "${compose[@]}" exec -T observium test -d "$rrd_dir" \
    || fail "the RRD directory ${rrd_dir} was not created for ${host}"
  "${compose[@]}" exec -T observium sh -c "ls ${rrd_dir}/*.rrd" >/dev/null 2>&1 \
    || fail "the poller did not create any RRD file in ${rrd_dir}"

  device_ids="${device_ids} ${device_id}"
done

distinct_ids="$(printf '%s\n' $device_ids | sort -u | wc -l | tr -d ' ')"
[ "$distinct_ids" = "2" ] || fail "the smoke devices did not get distinct device_ids:${device_ids}"

[ "$(db_scalar "SELECT COUNT(*) FROM devices WHERE hostname IN (${smoke_hosts_sql});")" = "2" ] \
  || fail "the smoke devices were not stored"

for host in $smoke_hosts; do
  "${compose[@]}" exec -T observium php delete_device.php "$host" rrd >/dev/null \
    || fail "could not delete the smoke device ${host}"
done

[ "$(db_scalar "SELECT COUNT(*) FROM devices WHERE hostname IN (${smoke_hosts_sql});")" = "0" ] \
  || fail "the smoke devices were not deleted"

log "restarting the container to check idempotency"
boot_lines="$(wc -l < "$workdir/boot.log" | tr -d ' ')"
"${compose[@]}" restart observium >/dev/null || fail "docker compose restart failed"
wait_http

"${compose[@]}" logs --no-log-prefix observium | sed -n "$((boot_lines + 1)),\$p" > "$workdir/restart.log"
contains 'Starting php-fpm' "$workdir/restart.log" || fail "php-fpm did not start on the second run"
contains "Admin user '${admin_user}' already exists" "$workdir/restart.log" \
  || fail "the second run created the admin user again"
not_contains 'Created initial admin user' "$workdir/restart.log" \
  || fail "the second run created the admin user again"
not_contains 'Seeded classic dashboard widgets' "$workdir/restart.log" \
  || fail "the second run seeded the dashboard widgets again"
if contains 'ERROR' "$workdir/restart.log"; then
  fail "the entrypoint reported an error on the second run (see log above)"
fi

[ "$(db_scalar 'SELECT COUNT(*) FROM dashboards;')" = "$dashboards" ] \
  || fail "the number of dashboards changed on the second run"
[ "$(db_scalar 'SELECT COUNT(*) FROM dash_widgets;')" = "$widgets" ] \
  || fail "the number of dashboard widgets changed on the second run"
[ "$(db_scalar "SELECT COUNT(*) FROM devices WHERE hostname IN (${smoke_hosts_sql});")" = "0" ] \
  || fail "the restarted entrypoint recreated the deleted smoke devices"

log "PASS: ${image}"
