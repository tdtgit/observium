#!/bin/sh
# Prepare the MariaDB server mode before the stock image entrypoint initialises
# the data directory.
#
# Observium's schema uses mixed case table names (bgpPeers, entPhysical, ...).
# With lower_case_table_names=2 an ALTER TABLE on such a table leaves it
# unreachable by name and the schema import stops before devices.device_id
# receives AUTO_INCREMENT, which breaks adding more than one device.
#
# The mode may only change while the data directory is created: a data
# directory keeps the table names it was initialised with, so an existing
# database has to keep the mode it was created with. Therefore:
#
#   * new data directory  -> lower_case_table_names=1 (names are stored lower
#     case, every lookup finds them again)
#   * existing directory  -> keep the mode it was created with
#   * OBSERVIUM_DB_LOWER_CASE_TABLE_NAMES (0, 1 or 2) takes precedence
#
# The files this script manages:
#
#   ${marker} is written into the data directory (so it is removed together
#   with the data directory and survives a container recreation). It records
#   the mode the data directory was created with and is only written when a
#   data directory is created, never changed afterwards.
#
#   ${config} exists only inside this container. It is generated from the
#   mode above and recreated on every start, so it is removed again when the
#   data directory has to keep its own mode. It is never a user file: this
#   script is its only writer, and no other configuration file is touched.
#
# Nothing here touches the stored data; removing the data directory is the
# only way to change the mode of an existing database.

set -e

datadir=/var/lib/mysql
marker="${datadir}/.observium-lower-case-table-names"
config=/etc/mysql/conf.d/zz-observium.cnf

warn() {
  echo "[db-entrypoint] WARNING: $*" >&2
}

filesystem_is_case_insensitive() {
  probe_upper="${datadir}/.ObserviumCaseProbe"
  probe_lower="${datadir}/.observiumcaseprobe"
  touch "${probe_upper}" 2>/dev/null || return 1
  if [ -f "${probe_lower}" ]; then
    rm -f "${probe_upper}" 2>/dev/null || true
    return 0
  fi
  rm -f "${probe_upper}" 2>/dev/null || true
  return 1
}

recorded=""
if [ -f "${marker}" ]; then
  recorded="$(cat "${marker}" 2>/dev/null || true)"
fi

forced=""
case "${OBSERVIUM_DB_LOWER_CASE_TABLE_NAMES:-}" in
  "")
    ;;
  0|1|2)
    forced="${OBSERVIUM_DB_LOWER_CASE_TABLE_NAMES}"
    ;;
  *)
    warn "ignoring OBSERVIUM_DB_LOWER_CASE_TABLE_NAMES='${OBSERVIUM_DB_LOWER_CASE_TABLE_NAMES}' (expected 0, 1 or 2)"
    ;;
esac

if [ "${forced}" = "0" ] && filesystem_is_case_insensitive; then
  warn "lower_case_table_names=0 is not possible on a case-insensitive filesystem; ignoring OBSERVIUM_DB_LOWER_CASE_TABLE_NAMES"
  forced=""
fi

if [ "${recorded}" = "0" ] && filesystem_is_case_insensitive; then
  warn "ignoring a recorded lower_case_table_names=0, which is not possible on a case-insensitive filesystem"
  recorded=""
fi

fresh=no
if [ ! -d "${datadir}/mysql" ]; then
  fresh=yes
fi

if [ -n "${forced}" ]; then
  mode="${forced}"
  if [ -n "${recorded}" ] && [ "${recorded}" != "${forced}" ]; then
    warn "this data directory was created with lower_case_table_names=${recorded}; the stored table names keep that mode, so lookups may break"
  fi
elif [ -n "${recorded}" ]; then
  mode="${recorded}"
elif [ "${fresh}" = "yes" ]; then
  mode=1
else
  mode=""
fi

if [ -n "${mode}" ]; then
  if [ "${fresh}" = "yes" ]; then
    printf '%s\n' "${mode}" > "${marker}" ||
      warn "could not record the mode in ${marker}; a recreated container will not know it"
  fi
  printf '[mysqld]\nlower_case_table_names=%s\n' "${mode}" > "${config}" ||
    warn "could not write ${config}; the server keeps its default lower_case_table_names and the schema import may fail"
  echo "[db-entrypoint] data directory uses lower_case_table_names=${mode}"
else
  if ! rm -f "${config}" 2>/dev/null; then
    warn "could not remove ${config}; a stale lower_case_table_names setting may be applied to this data directory"
  fi
  echo "[db-entrypoint] existing data directory, keeping the server default for lower_case_table_names"
fi

exec "$@"
