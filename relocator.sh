#!/bin/bash
set -euo pipefail

# --- Locate .env (resolves to the directory containing this script) ------------
CORE_SCRIPT_DIR="${CORE_SCRIPT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
source "$CORE_SCRIPT_DIR/.env"

: "${COMPOSE_DIR:?ERROR: COMPOSE_DIR not set in .env}"
: "${UPLOAD_MOUNT:?ERROR: UPLOAD_MOUNT not set in .env}"
: "${BACKUP_RETENTION_COUNT:?ERROR: BACKUP_RETENTION_COUNT not set in .env}"
# IMMICH_API_KEY is optional — leave empty to skip storage template migration

# --- Ensure psql wrapper is in PATH ---------------------------------------------
export PATH="$CORE_SCRIPT_DIR:$PATH"

# --- Detect flags ---------------------------------------------------------------
IS_DRY_RUN=false
IS_FULL=false
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && IS_DRY_RUN=true
  [[ "$arg" == "--full" ]] && IS_FULL=true
done

# --- Helper: run storage template migration job ---------------------------------
run_storage_template_job() {
  curl -s -X PUT http://localhost:2283/api/jobs/storageTemplateMigration \
    -H "x-api-key: $IMMICH_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"command": "start", "force": true}'

  while true; do
    status=$(curl -s http://localhost:2283/api/queues/storageTemplateMigration \
      -H "x-api-key: $IMMICH_API_KEY")
    active=$(echo "$status" | grep -o '"active":[0-9]*' | cut -d: -f2)
    waiting=$(echo "$status" | grep -o '"waiting":[0-9]*' | cut -d: -f2)
    if [[ "$active" == "0" && "$waiting" == "0" ]]; then
      break
    fi
    sleep 10
  done
}

# --- DRY-RUN (count only) -------------------------------------------------------
if [[ "$IS_DRY_RUN" == true && "$IS_FULL" != true ]]; then
  cd "$CORE_SCRIPT_DIR"
  ./core.sh --dry-run
  echo ""
  echo "NOTE: Use the --dry-run --full flag for more detailed results. Mind that using --full may also execute a Storage Template Migration job, if you configured your .env file to allow it."
  echo "A Storage Template Migration job may take time, depending on the amount of media you have."
  echo "Even when using --dry-run --full, your actual files will still not be relocated to the external libraries."
  exit 0
fi

# --- Verify immich-server is running (needed for API calls) ---------------------
cd "$COMPOSE_DIR"
if ! docker compose ps immich-server --status running --quiet 2>/dev/null | grep -q .; then
  echo "ERROR: immich-server is not running." >&2
  echo "       Please make sure your Immich stack is fully up before running this script." >&2
  echo "       Start it with: cd $COMPOSE_DIR && docker compose up -d" >&2
  exit 1
fi

# --- DRY-RUN --full -------------------------------------------------------------
if [[ "$IS_DRY_RUN" == true && "$IS_FULL" == true ]]; then
  if [[ -n "$IMMICH_API_KEY" ]]; then
    run_storage_template_job
  fi
  cd "$CORE_SCRIPT_DIR"
  ./core.sh --dry-run --full
  exit 0
fi

# --- Verify immich-server is running (needed for API calls) ---------------------
cd "$COMPOSE_DIR"
if ! docker compose ps immich-server --status running --quiet 2>/dev/null | grep -q .; then
  echo "ERROR: immich-server is not running." >&2
  echo "       Please make sure your Immich stack is fully up before running this script." >&2
  echo "       Start it with: cd $COMPOSE_DIR && docker compose up -d" >&2
  exit 1
fi

# --- FULL RUN -------------------------------------------------------------------
if [[ -n "$IMMICH_API_KEY" ]]; then
  run_storage_template_job
fi

# --- Shut down immich-server container  -----------------------------------------
cd "$COMPOSE_DIR"
docker compose stop immich-server
trap 'echo "[relocator] Restarting immich-server after failure/exit..." >&2; cd "$COMPOSE_DIR" && docker compose up -d immich-server 2>/dev/null || true' EXIT


# --- Create db backup -----------------------------------------------------------
mkdir -p "$CORE_SCRIPT_DIR/db-backups"
BACKUP_FILE="$CORE_SCRIPT_DIR/db-backups/immich_backup_$(date +%Y%m%d_%H%M).sql"
docker exec immich_postgres pg_dump -U postgres immich > "$BACKUP_FILE"

# --- Verify backup integrity ----------------------------------------------------
if [[ ! -s "$BACKUP_FILE" ]] || ! grep -q "PostgreSQL database dump complete" "$BACKUP_FILE"; then
  echo "ERROR: Database backup appears truncated or empty. Aborting." >&2
  echo "       File: $BACKUP_FILE" >&2
  rm -f "$BACKUP_FILE"
  cd "$COMPOSE_DIR"
  docker compose up -d immich-server
  exit 1
fi

# --- Prune old backups  ---------------------------------------------------------
ls -1t "$CORE_SCRIPT_DIR/db-backups"/immich_backup_*.sql 2>/dev/null | tail -n +"$((BACKUP_RETENTION_COUNT + 1))" | xargs -r rm -f || true

# --- Launch the core script  ----------------------------------------------------
cd "$CORE_SCRIPT_DIR"
./core.sh "$@"

# --- Delete empty directories located in Immich's internal library folder  ------
find "$UPLOAD_MOUNT/library" -mindepth 1 -type d -empty -delete 2>/dev/null || true
