#!/usr/bin/env bash
set -euo pipefail

OBSERVIUM_HOME="${OBSERVIUM_HOME:-/opt/observium}"
CONFIG_FILE="${OBSERVIUM_HOME}/config.php"

OBSERVIUM_DB_HOST="${OBSERVIUM_DB_HOST:-db}"
OBSERVIUM_DB_NAME="${OBSERVIUM_DB_NAME:-observium}"
OBSERVIUM_DB_USER="${OBSERVIUM_DB_USER:-observium}"
OBSERVIUM_DB_PASSWORD="${OBSERVIUM_DB_PASSWORD:-observium}"
OBSERVIUM_DB_EXTENSION="${OBSERVIUM_DB_EXTENSION:-mysqli}"
OBSERVIUM_BASE_URL="${OBSERVIUM_BASE_URL:-}"
OBSERVIUM_ENABLE_FASTCACHE="${OBSERVIUM_ENABLE_FASTCACHE:-true}"
OBSERVIUM_CACHE_DRIVER="${OBSERVIUM_CACHE_DRIVER:-apcu}"
OBSERVIUM_PHP_MEMORY_LIMIT="${OBSERVIUM_PHP_MEMORY_LIMIT:-512M}"
OBSERVIUM_APCU_SHM_SIZE="${OBSERVIUM_APCU_SHM_SIZE:-128M}"
OBSERVIUM_ENABLE_RAMDISK="${OBSERVIUM_ENABLE_RAMDISK:-false}"
OBSERVIUM_RAMDISK_PATH="${OBSERVIUM_RAMDISK_PATH:-/dev/shm/observium-rrd}"
OBSERVIUM_RAMDISK_SYNC_INTERVAL="${OBSERVIUM_RAMDISK_SYNC_INTERVAL:-300}"
OBSERVIUM_ENABLE_CRON="${OBSERVIUM_ENABLE_CRON:-true}"
OBSERVIUM_INIT_DB_SCHEMA="${OBSERVIUM_INIT_DB_SCHEMA:-false}"
OBSERVIUM_CREATE_ADMIN="${OBSERVIUM_CREATE_ADMIN:-false}"
OBSERVIUM_ADMIN_USER="${OBSERVIUM_ADMIN_USER:-}"
OBSERVIUM_ADMIN_PASSWORD="${OBSERVIUM_ADMIN_PASSWORD:-}"
OBSERVIUM_ADMIN_LEVEL="${OBSERVIUM_ADMIN_LEVEL:-10}"
OBSERVIUM_CREATE_DEFAULT_DASHBOARD="${OBSERVIUM_CREATE_DEFAULT_DASHBOARD:-true}"
OBSERVIUM_DASHBOARD_USER="${OBSERVIUM_DASHBOARD_USER:-${OBSERVIUM_ADMIN_USER:-}}"
OBSERVIUM_RRD_DIR="${OBSERVIUM_HOME}/rrd"

log() {
  printf '[entrypoint] %s\n' "$*"
}

prepare_config() {
  if [[ ! -f "${CONFIG_FILE}" ]]; then
    cp "${OBSERVIUM_HOME}/config.php.default" "${CONFIG_FILE}"
    log "Created config.php from config.php.default"
  fi

  sed -i '/BEGIN Docker Managed Settings/,/END Docker Managed Settings/d' "${CONFIG_FILE}"

  cat >> "${CONFIG_FILE}" <<EOCFG

// BEGIN Docker Managed Settings
\$config['db_extension'] = '${OBSERVIUM_DB_EXTENSION}';
\$config['db_host']      = '${OBSERVIUM_DB_HOST}';
\$config['db_user']      = '${OBSERVIUM_DB_USER}';
\$config['db_pass']      = '${OBSERVIUM_DB_PASSWORD}';
\$config['db_name']      = '${OBSERVIUM_DB_NAME}';
\$config['install_dir']  = '${OBSERVIUM_HOME}';
\$config['rrd_dir']      = '${OBSERVIUM_RRD_DIR}';
\$config['log_dir']      = '${OBSERVIUM_HOME}/logs';
// Avoid empty host in generated URLs when running behind containerized web servers.
// Observium builds absolute URLs from this value (login redirect, graph images),
// and nginx in this container only ever sees plain HTTP, so a TLS-terminating
// reverse proxy is detected through the header it forwards.
\$__obs_https = (!empty(\$_SERVER['HTTPS']) && \$_SERVER['HTTPS'] !== 'off')
  || ((\$_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https');
\$__obs_scheme = \$__obs_https ? 'https' : 'http';
\$__obs_host = \$_SERVER['HTTP_HOST'] ?? (\$_SERVER['SERVER_NAME'] ?? 'localhost');
\$config['base_url'] = \$__obs_scheme . '://' . \$__obs_host;
EOCFG

  if [[ "${OBSERVIUM_ENABLE_FASTCACHE}" == "true" ]]; then
    cat >> "${CONFIG_FILE}" <<EOCFG
\$config['cache']['enable'] = TRUE;
\$config['cache']['driver'] = '${OBSERVIUM_CACHE_DRIVER}';
EOCFG
  fi

  if [[ -n "${OBSERVIUM_BASE_URL}" ]]; then
    cat >> "${CONFIG_FILE}" <<EOCFG
\$config['web_url']      = '${OBSERVIUM_BASE_URL}';
EOCFG
  fi

  cat >> "${CONFIG_FILE}" <<'EOCFG'
// END Docker Managed Settings
EOCFG

  chown -R www-data:www-data "${OBSERVIUM_HOME}/logs" "${OBSERVIUM_HOME}/rrd"
}

configure_php_runtime() {
  mkdir -p /tmp/php-opcache
  chmod 1777 /tmp/php-opcache

  cat > /usr/local/etc/php/conf.d/99-observium-tuning.ini <<EOCFG
memory_limit=${OBSERVIUM_PHP_MEMORY_LIMIT}
opcache.enable=1
opcache.enable_cli=1
opcache.file_cache=/tmp/php-opcache
apc.enable_cli=1
apc.shm_size=${OBSERVIUM_APCU_SHM_SIZE}
EOCFG

  # One conf.d directory serves FPM and CLI, so no second copy is needed.
}

setup_rrd_ramdisk() {
  if [[ "${OBSERVIUM_ENABLE_RAMDISK}" != "true" ]]; then
    return
  fi

  if [[ "${OBSERVIUM_RAMDISK_PATH}" == "${OBSERVIUM_HOME}/rrd" ]]; then
    log "OBSERVIUM_RAMDISK_PATH points to the persistent RRD path; disabling RAM disk mode"
    return
  fi

  OBSERVIUM_RRD_DIR="${OBSERVIUM_RAMDISK_PATH}"
  mkdir -p "${OBSERVIUM_RAMDISK_PATH}" "${OBSERVIUM_HOME}/rrd"
  chown -R www-data:www-data "${OBSERVIUM_RAMDISK_PATH}" "${OBSERVIUM_HOME}/rrd"

  # Warm the RAM disk from persistent storage.
  if [[ -n "$(ls -A "${OBSERVIUM_HOME}/rrd" 2>/dev/null)" ]]; then
    rsync -a --delete "${OBSERVIUM_HOME}/rrd"/ "${OBSERVIUM_RAMDISK_PATH}/"
  fi

  log "RRD RAM disk enabled at ${OBSERVIUM_RAMDISK_PATH}; persistent copy remains at ${OBSERVIUM_HOME}/rrd"
}

start_rrd_ramdisk_sync() {
  if [[ "${OBSERVIUM_ENABLE_RAMDISK}" != "true" ]]; then
    return
  fi

  (
    while true; do
      sleep "${OBSERVIUM_RAMDISK_SYNC_INTERVAL}"
      rsync -a --delete "${OBSERVIUM_RAMDISK_PATH}/" "${OBSERVIUM_HOME}/rrd/" || true
    done
  ) &

  log "Started RAM disk sync loop every ${OBSERVIUM_RAMDISK_SYNC_INTERVAL}s"
}

init_db_schema() {
  if [[ "${OBSERVIUM_INIT_DB_SCHEMA}" != "true" ]]; then
    return
  fi

  log "Running discovery.php -u (database schema init/update)"

  local status=0
  (cd "${OBSERVIUM_HOME}" && ./discovery.php -u) || status=$?

  if [[ "${status}" -ne 0 ]]; then
    # A failed schema update is usually recoverable: the update scripts are
    # idempotent and the next run continues where the previous one stopped.
    log "discovery.php -u exited with status ${status}; retrying once"
    status=0
    (cd "${OBSERVIUM_HOME}" && ./discovery.php -u) || status=$?
    if [[ "${status}" -ne 0 ]]; then
      log "ERROR: database schema update failed with status ${status}"
    fi
  fi
}

# Observium installs its initial schema by piping update/db_schema_mysql.sql
# into the mysql client, which stops at the first failing statement. On MariaDB
# with lower_case_table_names=2 the ALTERs on mixed case table names (bgpPeers,
# entPhysical, hrDevice, ...) leave those tables unreachable and the import
# stops before devices.device_id is switched to AUTO_INCREMENT. Devices then
# share the primary key value 0 and every device after the first one fails
# with "Duplicate entry '0' for key 'PRIMARY'".
#
# Runs on every start, not only when the schema is (re)installed, so a
# database that was imported with a broken schema is repaired as well.
verify_db_schema() {
  local lower_case_table_names
  lower_case_table_names="$(mysql_exec "SELECT @@lower_case_table_names;" || true)"
  if [[ "${lower_case_table_names}" == "2" ]]; then
    log "WARNING: database uses lower_case_table_names=2, which breaks the Observium schema import."
    log "         Recreate the database (docker compose down && rm -rf ./data/db && docker compose up -d);"
    log "         a new data directory is created with lower_case_table_names=1."
  fi

  # A truncated schema import leaves the table with a stale data dictionary
  # entry, so compare the column names case insensitively and check every
  # matching entry instead of a single one.
  local state column_type
  IFS=$'\t' read -r state column_type <<< "$(mysql_exec "SELECT CASE WHEN COUNT(*) = 0 THEN 'absent' WHEN SUM(EXTRA LIKE '%auto_increment%') = COUNT(*) THEN 'ok' ELSE 'missing' END, MAX(COLUMN_TYPE) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = '${OBSERVIUM_DB_NAME}' AND LOWER(TABLE_NAME) = 'devices' AND LOWER(COLUMN_NAME) = 'device_id';" || true)"

  case "${state}" in
    "")
      # Database not reachable, nothing to check.
      return
      ;;
    absent)
      # No schema installed (yet), nothing to check or repair.
      return
      ;;
    ok)
      ;;
    *)
      repair_devices_auto_increment "${column_type}"
      ;;
  esac

  report_unreachable_tables
}

repair_devices_auto_increment() {
  local column_type="${1:-int(11)}"
  if [[ -z "${column_type}" ]]; then
    column_type="int(11)"
  fi

  log "devices.device_id has no AUTO_INCREMENT (truncated schema import); repairing"
  if mysql_exec "ALTER TABLE \`devices\` MODIFY \`device_id\` ${column_type} NOT NULL AUTO_INCREMENT;"; then
    log "Repaired devices.device_id AUTO_INCREMENT"
  else
    log "ERROR: could not repair devices.device_id AUTO_INCREMENT; the database schema is incomplete."
    log "       Recreate the database (docker compose down && rm -rf ./data/db && docker compose up -d) and add your devices again."
  fi
}

report_unreachable_tables() {
  # The tables with mixed case names are the ones MariaDB resolves
  # inconsistently with lower_case_table_names=2, and the broken ones are not
  # even listed in information_schema anymore. Take the names from the schema
  # file Observium ships and probe them.
  local schema_file="${OBSERVIUM_HOME}/update/db_schema_mysql.sql"

  if [[ ! -f "${schema_file}" ]]; then
    return
  fi

  local candidates
  candidates="$(grep -oE 'CREATE TABLE `[A-Za-z0-9_-]+`' "${schema_file}" | sed -E 's/^CREATE TABLE `([^`]*)`$/\1/' | grep -E '[A-Z]' | sort -u || true)"

  if [[ -z "${candidates}" ]]; then
    return
  fi

  local script="" table lower
  while IFS= read -r table; do
    [[ -z "${table}" ]] && continue
    script+="SELECT 1 FROM \`${table}\` LIMIT 0;"$'\n'
  done <<< "${candidates}"

  local broken
  broken="$(printf '%s' "${script}" | mysql_exec_stdin 2>&1 | grep -oE "Table '[^']+' doesn't exist" | sed -E "s/^Table '.*\.([^']+)' doesn't exist$/\1/" | sort -u || true)"

  if [[ -z "${broken}" ]]; then
    return
  fi

  log "ERROR: some tables are not reachable by name (broken schema import):"
  while IFS= read -r table; do
    [[ -z "${table}" ]] && continue
    lower="$(printf '%s' "${table}" | tr '[:upper:]' '[:lower:]')"
    if printf '%s\n' "${broken}" | grep -qix "${lower}"; then
      log "       ${table}"
    fi
  done <<< "${candidates}"
  log "       Recreate the database (docker compose down && rm -rf ./data/db && docker compose up -d)."
}

# Generate a password for the initial administrator account. Alphanumeric only,
# so it survives copy and paste out of `docker compose logs` and the terminal.
# openssl comes in with ca-certificates; /dev/urandom is the fallback.
generate_admin_password() {
  local password=""

  if command -v openssl >/dev/null 2>&1; then
    password="$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | cut -c1-24)"
  fi

  if [[ -z "${password}" ]]; then
    # cut consumes the whole stream, so no process in this pipeline is killed by
    # SIGPIPE, which `set -o pipefail` would turn into a failure.
    password="$(dd if=/dev/urandom bs=512 count=1 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-24)"
  fi

  printf '%s' "${password}"
}

print_generated_admin_password() {
  local user="$1" password="$2"

  printf '\n'
  printf '===============================================================================\n'
  printf ' OBSERVIUM INITIAL ADMINISTRATOR CREDENTIALS\n'
  printf '\n'
  printf '   username: %s\n' "${user}"
  printf '   password: %s\n' "${password}"
  printf '\n'
  printf ' A random password was generated because OBSERVIUM_ADMIN_PASSWORD was empty.\n'
  printf ' It is printed exactly once, in this container log, and is not stored in a\n'
  printf ' file anywhere. Change it after the first login (Preferences -> Change\n'
  printf ' Password) or remove the user. Treat the container log as a secret.\n'
  printf '===============================================================================\n'
  printf '\n'
}

create_admin_user() {
  if [[ "${OBSERVIUM_CREATE_ADMIN}" != "true" ]]; then
    return
  fi

  if [[ -z "${OBSERVIUM_ADMIN_USER}" ]]; then
    log "Skipping admin user creation because OBSERVIUM_ADMIN_USER is empty"
    return
  fi

  # Never recreate or reset an existing user: a restart must not print a new
  # password for an account the operator may already have changed.
  local existing_user_id
  existing_user_id="$(mysql_exec "SELECT user_id FROM users WHERE username='$(sql_escape "${OBSERVIUM_ADMIN_USER}")' LIMIT 1;" || true)"
  if [[ -n "${existing_user_id}" ]]; then
    log "Admin user '${OBSERVIUM_ADMIN_USER}' already exists; skipping creation"
    return
  fi

  local generated_password=""
  if [[ -z "${OBSERVIUM_ADMIN_PASSWORD}" ]]; then
    OBSERVIUM_ADMIN_PASSWORD="$(generate_admin_password)"
    if [[ -z "${OBSERVIUM_ADMIN_PASSWORD}" ]]; then
      log "ERROR: could not generate an admin password; set OBSERVIUM_ADMIN_PASSWORD explicitly"
      return
    fi
    generated_password="true"
  fi

  local new_user_id password_hash user_escaped pass_escaped level_value
  new_user_id="$(next_numeric_id users user_id)"
  password_hash="$(php -r 'echo password_hash($argv[1], PASSWORD_BCRYPT);' "${OBSERVIUM_ADMIN_PASSWORD}")"
  user_escaped="$(sql_escape "${OBSERVIUM_ADMIN_USER}")"
  pass_escaped="$(sql_escape "${password_hash}")"
  level_value="${OBSERVIUM_ADMIN_LEVEL}"
  if ! [[ "${level_value}" =~ ^[0-9]+$ ]]; then
    level_value="10"
  fi

  mysql_exec "INSERT INTO users (user_id, username, password, realname, email, descr, level, can_modify_passwd, user_options, type) VALUES (${new_user_id}, '${user_escaped}', '${pass_escaped}', '${user_escaped}', '', '', ${level_value}, 1, NULL, 'mysql');"
  log "Created initial admin user '${OBSERVIUM_ADMIN_USER}' (user_id=${new_user_id})"

  if [[ -n "${generated_password}" ]]; then
    print_generated_admin_password "${OBSERVIUM_ADMIN_USER}" "${OBSERVIUM_ADMIN_PASSWORD}"
  fi
}

start_cron_if_enabled() {
  if [[ "${OBSERVIUM_ENABLE_CRON}" == "true" ]]; then
    log "Starting cron"
    cron
  else
    log "Cron disabled by OBSERVIUM_ENABLE_CRON=${OBSERVIUM_ENABLE_CRON}"
  fi
}

sql_escape() {
  printf "%s" "$1" | sed "s/'/''/g"
}

mysql_exec() {
  mariadb \
    --host="${OBSERVIUM_DB_HOST}" \
    --user="${OBSERVIUM_DB_USER}" \
    --password="${OBSERVIUM_DB_PASSWORD}" \
    --database="${OBSERVIUM_DB_NAME}" \
    --batch --raw --skip-column-names \
    -e "$1"
}

mysql_exec_stdin() {
  mariadb \
    --host="${OBSERVIUM_DB_HOST}" \
    --user="${OBSERVIUM_DB_USER}" \
    --password="${OBSERVIUM_DB_PASSWORD}" \
    --database="${OBSERVIUM_DB_NAME}" \
    --batch --raw --force
}

next_numeric_id() {
  local table="$1"
  local column="$2"
  # Start at 1: inserting an explicit 0 into an AUTO_INCREMENT column makes
  # the server assign the next generated value instead, which breaks the
  # following inserts with a duplicate key error.
  mysql_exec "SELECT COALESCE(MAX(${column}), 0) + 1 FROM ${table};"
}

create_default_dashboard() {
  if [[ "${OBSERVIUM_CREATE_DEFAULT_DASHBOARD}" != "true" ]]; then
    return
  fi

  if [[ -z "${OBSERVIUM_DASHBOARD_USER}" ]]; then
    log "Skipping default dashboard creation because OBSERVIUM_DASHBOARD_USER is empty"
    return
  fi

  local user_escaped user_id dash_id widget_count
  user_escaped="$(sql_escape "${OBSERVIUM_DASHBOARD_USER}")"
  user_id="$(mysql_exec "SELECT user_id FROM users WHERE username='${user_escaped}' LIMIT 1;" || true)"

  if [[ -z "${user_id}" ]]; then
    log "Skipping default dashboard creation because user '${OBSERVIUM_DASHBOARD_USER}' was not found"
    return
  fi

  dash_id="$(mysql_exec "SELECT dash_id FROM dashboards WHERE user_id=${user_id} ORDER BY dash_id ASC LIMIT 1;" || true)"
  if [[ -z "${dash_id}" ]]; then
    dash_id="$(next_numeric_id dashboards dash_id)"
    mysql_exec "INSERT INTO dashboards (dash_id, user_id, dash_name, descr, dash_order, created_by, updated_by, slug, is_public) VALUES (${dash_id}, ${user_id}, 'Default Dashboard', 'Autogenerated default dashboard', 0, ${user_id}, ${user_id}, NULL, 0);" || {
      log "Failed to create default dashboard for user '${OBSERVIUM_DASHBOARD_USER}'"
      return
    }
    log "Created default dashboard ${dash_id} for user '${OBSERVIUM_DASHBOARD_USER}'"
  fi

  widget_count="$(mysql_exec "SELECT COUNT(*) FROM dash_widgets WHERE dash_id=${dash_id};" || true)"
  if [[ "${widget_count:-0}" == "0" ]]; then
    local next_widget_id
    next_widget_id="$(next_numeric_id dash_widgets widget_id)"
    # Seed a classic Observium-style default layout (map + alerts + summary/log widgets).
    mysql_exec "INSERT INTO dash_widgets (widget_id, dash_id, widget_type, widget_config, x, y, width, height) VALUES (${next_widget_id}, ${dash_id}, 'welcome', '{}', 6, 0, 12, 3);"
    next_widget_id=$((next_widget_id + 1))
    mysql_exec "INSERT INTO dash_widgets (widget_id, dash_id, widget_type, widget_config, x, y, width, height) VALUES (${next_widget_id}, ${dash_id}, 'map', '{}', 0, 3, 6, 7);"
    next_widget_id=$((next_widget_id + 1))
    mysql_exec "INSERT INTO dash_widgets (widget_id, dash_id, widget_type, widget_config, x, y, width, height) VALUES (${next_widget_id}, ${dash_id}, 'status_summary', '{}', 6, 3, 6, 7);"
    next_widget_id=$((next_widget_id + 1))
    mysql_exec "INSERT INTO dash_widgets (widget_id, dash_id, widget_type, widget_config, x, y, width, height) VALUES (${next_widget_id}, ${dash_id}, 'alert_boxes', '{}', 0, 10, 12, 3);"
    next_widget_id=$((next_widget_id + 1))
    mysql_exec "INSERT INTO dash_widgets (widget_id, dash_id, widget_type, widget_config, x, y, width, height) VALUES (${next_widget_id}, ${dash_id}, 'eventlog', '{}', 0, 13, 6, 9);"
    next_widget_id=$((next_widget_id + 1))
    mysql_exec "INSERT INTO dash_widgets (widget_id, dash_id, widget_type, widget_config, x, y, width, height) VALUES (${next_widget_id}, ${dash_id}, 'alertlog', '{}', 6, 13, 6, 9);"
    log "Seeded classic dashboard widgets for dashboard ${dash_id}"
  fi

  local pref_id
  pref_id="$(mysql_exec "SELECT pref_id FROM users_prefs WHERE user_id=${user_id} AND pref='dashboard_default' LIMIT 1;" || true)"
  if [[ -n "${pref_id}" ]]; then
    mysql_exec "UPDATE users_prefs SET value='${dash_id}' WHERE pref_id=${pref_id};"
  else
    pref_id="$(next_numeric_id users_prefs pref_id)"
    mysql_exec "INSERT INTO users_prefs (pref_id, user_id, pref, value) VALUES (${pref_id}, ${user_id}, 'dashboard_default', '${dash_id}');"
  fi
}

start_php_fpm() {
  log "Starting php-fpm"
  php-fpm -D
}

is_nginx_foreground() {
  [[ "${1:-}" == "nginx" && "${2:-}" == "-g" && "${3:-}" == "daemon off;" ]]
}

if is_nginx_foreground "$@"; then
  configure_php_runtime
  setup_rrd_ramdisk
  prepare_config
  init_db_schema
  verify_db_schema
  create_admin_user
  create_default_dashboard
  start_php_fpm
  start_cron_if_enabled
  start_rrd_ramdisk_sync
fi

exec "$@"
