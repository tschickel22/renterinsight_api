#!/usr/bin/env bash
#
# db_dump.sh — Dump or restore the local Platform DMS PostgreSQL database.
#
# Usage:
#   ./db_dump.sh              Dump ri_dms_dev to a timestamped file in ./db/dumps/
#   ./db_dump.sh dump         Same as above
#   ./db_dump.sh restore FILE Restore from a dump file
#
# Connection defaults (override via environment or .env):
#   DATABASE_URL  — full postgres:// URI (preferred)
#   PGHOST        — localhost
#   PGPORT        — 5432
#   PGUSER        — postgres
#   PGPASSWORD    — postgres
#   PGDATABASE    — ri_dms_dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUMP_DIR="${SCRIPT_DIR}/db/dumps"

# ── Load .env if present ──────────────────────────────────────────────
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
  set +a
fi

# ── Parse DATABASE_URL into PG* vars ─────────────────────────────────
if [[ -n "${DATABASE_URL:-}" ]]; then
  # Strip the scheme
  _conn="${DATABASE_URL#postgres://}"
  _conn="${_conn#postgresql://}"

  _userpass="${_conn%%@*}"
  _hostdbrest="${_conn#*@}"

  PGUSER="${PGUSER:-${_userpass%%:*}}"
  PGPASSWORD="${PGPASSWORD:-${_userpass#*:}}"

  _hostport="${_hostdbrest%%/*}"
  PGHOST="${PGHOST:-${_hostport%%:*}}"
  PGPORT="${PGPORT:-${_hostport##*:}}"

  _dbname="${_hostdbrest#*/}"
  _dbname="${_dbname%%\?*}"  # strip query params
  PGDATABASE="${PGDATABASE:-${_dbname}}"
fi

# ── Defaults ──────────────────────────────────────────────────────────
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-postgres}"
export PGDATABASE="${PGDATABASE:-ri_dms_dev}"

# ── Commands ──────────────────────────────────────────────────────────

do_dump() {
  mkdir -p "${DUMP_DIR}"
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local outfile="${DUMP_DIR}/${PGDATABASE}_${timestamp}.dump"

  echo "Dumping ${PGDATABASE} on ${PGHOST}:${PGPORT} ..."
  pg_dump \
    --host="${PGHOST}" \
    --port="${PGPORT}" \
    --username="${PGUSER}" \
    --format=custom \
    --compress=6 \
    --no-owner \
    --no-privileges \
    --verbose \
    "${PGDATABASE}" \
    > "${outfile}"

  local size
  size="$(du -h "${outfile}" | cut -f1)"
  echo ""
  echo "Done — ${outfile} (${size})"
  echo ""
  echo "To restore on another machine:"
  echo "  ./db_dump.sh restore ${outfile}"
}

do_restore() {
  local infile="${1:-}"
  if [[ -z "${infile}" ]]; then
    echo "Usage: $0 restore <dump-file>" >&2
    exit 1
  fi
  if [[ ! -f "${infile}" ]]; then
    echo "File not found: ${infile}" >&2
    exit 1
  fi

  echo "This will DROP and recreate ${PGDATABASE} on ${PGHOST}:${PGPORT}."
  read -rp "Continue? [y/N] " confirm
  if [[ "${confirm}" != [yY] ]]; then
    echo "Aborted."
    exit 0
  fi

  echo "Dropping ${PGDATABASE} (if exists) ..."
  dropdb --host="${PGHOST}" --port="${PGPORT}" --username="${PGUSER}" \
    --if-exists "${PGDATABASE}"

  echo "Creating ${PGDATABASE} ..."
  createdb --host="${PGHOST}" --port="${PGPORT}" --username="${PGUSER}" \
    "${PGDATABASE}"

  echo "Restoring from ${infile} ..."
  pg_restore \
    --host="${PGHOST}" \
    --port="${PGPORT}" \
    --username="${PGUSER}" \
    --dbname="${PGDATABASE}" \
    --no-owner \
    --no-privileges \
    --verbose \
    "${infile}"

  echo ""
  echo "Restore complete. Run 'bin/rails db:migrate' to apply any pending migrations."
}

# ── Main ──────────────────────────────────────────────────────────────

case "${1:-dump}" in
  dump)
    do_dump
    ;;
  restore)
    do_restore "${2:-}"
    ;;
  *)
    echo "Usage: $0 [dump | restore <file>]" >&2
    exit 1
    ;;
esac
