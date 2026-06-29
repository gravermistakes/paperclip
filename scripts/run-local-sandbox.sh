#!/usr/bin/env bash
#
# run-local-sandbox.sh — boot Paperclip in a root-only sandbox (no Docker daemon).
#
# WHY THIS EXISTS
# ---------------
# Paperclip's default `pnpm dev:server` starts an *embedded* PostgreSQL. That
# embedded Postgres refuses to initialise when the current process is root
# ("The files belonging to this database system will be owned by user
# 'postgres'. This user must also own the server process."). Many CI/cloud
# sandboxes run as root and have no Docker daemon, so neither the embedded path
# nor `docker-compose.quickstart.yml` works out of the box.
#
# THE WORKAROUND (verified working)
# ---------------------------------
# Run *only* PostgreSQL as a non-root user (uid 1000), using the Postgres
# binaries pnpm already downloaded, then point Paperclip at it via DATABASE_URL.
# Paperclip itself can stay root; only Postgres is picky.
#
# Usage:  bash scripts/run-local-sandbox.sh
# Stop:   bash scripts/run-local-sandbox.sh stop
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
PGPORT="${PGPORT:-54330}"
PGDATA="${PGDATA:-/home/user/pcpg/data}"
PGUSER_DB="pc"
NONROOT_USER="${NONROOT_USER:-ubuntu}"
DBNAME="paperclip"

# Locate the embedded-postgres binaries pnpm installed (version-agnostic).
PGBIN="$(dirname "$(find "$REPO/node_modules" -path '*@embedded-postgres*/native/bin/initdb' 2>/dev/null | head -1)")"
if [ -z "${PGBIN:-}" ] || [ ! -x "$PGBIN/initdb" ]; then
  echo "ERROR: embedded-postgres binaries not found. Run 'pnpm install' first." >&2
  exit 1
fi

stop() {
  sudo -u "$NONROOT_USER" "$PGBIN/pg_ctl" -D "$PGDATA" stop 2>/dev/null || true
  echo "stopped postgres"
}
if [ "${1:-}" = "stop" ]; then stop; exit 0; fi

# 1. Postgres data dir, owned by the non-root user.
if [ ! -d "$PGDATA" ]; then
  sudo mkdir -p "$PGDATA"
  sudo chown -R "$NONROOT_USER":"$NONROOT_USER" "$(dirname "$PGDATA")"
  sudo -u "$NONROOT_USER" "$PGBIN/initdb" -D "$PGDATA" -U "$PGUSER_DB" --auth=trust >/dev/null
  echo "initdb complete"
fi

# 2. Start Postgres as the non-root user (idempotent).
if ! pg_isready -h 127.0.0.1 -p "$PGPORT" -U "$PGUSER_DB" >/dev/null 2>&1; then
  sudo -u "$NONROOT_USER" "$PGBIN/pg_ctl" -D "$PGDATA" \
    -o "-p $PGPORT -h 127.0.0.1" -l "$(dirname "$PGDATA")/pg.log" start >/dev/null
  for _ in $(seq 1 15); do
    pg_isready -h 127.0.0.1 -p "$PGPORT" -U "$PGUSER_DB" >/dev/null 2>&1 && break
    sleep 1
  done
  echo "postgres up on 127.0.0.1:$PGPORT"
fi

export DATABASE_URL="postgres://${PGUSER_DB}@127.0.0.1:${PGPORT}/${DBNAME}"

# 3. Ensure the database exists.
psql "postgres://${PGUSER_DB}@127.0.0.1:${PGPORT}/postgres" -tAc \
  "SELECT 1 FROM pg_database WHERE datname='${DBNAME}'" 2>/dev/null | grep -q 1 \
  || psql "postgres://${PGUSER_DB}@127.0.0.1:${PGPORT}/postgres" -c "CREATE DATABASE ${DBNAME}" >/dev/null

# 4. Migrate.
( cd "$REPO" && pnpm db:migrate )

# 5. Boot the server.
export BETTER_AUTH_SECRET="${BETTER_AUTH_SECRET:-$(node -e "console.log(require('crypto').randomBytes(32).toString('hex'))")}"
export HOST="${HOST:-127.0.0.1}"
export PAPERCLIP_HOME="${PAPERCLIP_HOME:-$REPO/.pcdata}"
export PAPERCLIP_DEPLOYMENT_MODE="${PAPERCLIP_DEPLOYMENT_MODE:-authenticated}"
mkdir -p "$PAPERCLIP_HOME"

echo "Booting Paperclip → http://${HOST}:3100  (health: /api/health)"
cd "$REPO" && exec pnpm dev:server
