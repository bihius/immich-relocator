#!/usr/bin/env bash
#
# Immich external-library migration helper.
#
# Moves files from Immich's upload dir into an external library folder and
# updates the corresponding asset records. Original sha1 content checksum is
# preserved so the iPhone/Android client's bulk-upload-check still matches —
# do NOT rewrite checksum to sha1-path or you'll trigger full re-upload.
#
# Options:
#   --dry-run     Show what would be moved/updated without changing anything
#   --verbose     Log every file processed (not just the summary)
#   --help        Show this help and exit
#
# All other config remains via the variables below (or environment).

set -euo pipefail

# --- Configuration (override via environment if desired) --------------------

SRC_DIR="${SRC_DIR:-/opt/immich/upload/upload/}"   # default for Proxmox-helper-scripts installs
DEST_DIR="${DEST_DIR:-/mnt/external_library/}"
LIBRARY_NAME="${LIBRARY_NAME:-External Library}"   # name of your external library in Immich
PGDATABASE="${PGDATABASE:-immich}"
PGUSER="${PGUSER:-immich}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGPASSWORD="${PGPASSWORD:-password}"

LOCK_FILE="${LOCK_FILE:-/tmp/immich-migrate-to-external-library.lock}"

# --- Parse args -------------------------------------------------------------

DRY_RUN=false
VERBOSE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --help)
      sed -n '2,15p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --- Helpers ----------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
vlog() { if [[ "$VERBOSE" == true ]]; then log "$@"; fi; }

# --- Preflight --------------------------------------------------------------

# Acquire lock atomically using noclobber (set -C). Stale locks (PID gone) are
# removed and retried. Two concurrent starts hitting the retry simultaneously
# will race — one wins the second noclobber attempt, the other exits cleanly.
while true; do
  if ( set -C; echo $$ > "$LOCK_FILE" ) 2>/dev/null; then
    break
  fi
  lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [[ -z "$lock_pid" ]] || ! kill -0 "$lock_pid" 2>/dev/null; then
    rm -f "$LOCK_FILE"   # stale lock — retry
    continue
  fi
  echo "ERROR: another instance is running (PID $lock_pid)" >&2
  exit 1
done
trap 'rm -f "$LOCK_FILE"' EXIT

export LC_ALL=C
export PGDATABASE PGUSER PGHOST PGPORT PGPASSWORD

# Resolve external library UUID. psql -v + stdin is used throughout (-c does
# NOT interpolate -v variables in psql 16+; only -f / stdin does).
LIBRARY_ID=$(psql -At -v lib_name="$LIBRARY_NAME" <<'EOF'
SELECT id FROM library WHERE name = :'lib_name' AND "deletedAt" IS NULL;
EOF
)
if [[ -z "$LIBRARY_ID" ]]; then
  echo "ERROR: Library '$LIBRARY_NAME' not found. Create it in Immich first." >&2
  exit 1
fi

log "=== Immich external-library migration ==="
log "Mode:        $([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY)"
log "Source:      $SRC_DIR"
log "Destination: $DEST_DIR"
log "Library:     $LIBRARY_NAME ($LIBRARY_ID)"

[[ "$DRY_RUN" == false ]] && mkdir -p "$DEST_DIR"

# --- Counters ---------------------------------------------------------------

TOTAL=0
MOVED=0
SKIPPED_NOT_IN_DB=0
SKIPPED_DEST_EXISTS=0
SKIPPED_CONSTRAINT=0
FAILED=0

# --- Main loop --------------------------------------------------------------

while IFS= read -r -d '' file; do
  TOTAL=$((TOTAL + 1))

  # Look up the asset by its current path in the DB.
  # AND "libraryId" IS NULL ensures already-external assets are caught here
  # (before the file is moved) rather than triggering a move-then-restore cycle.
  orig_name=$(psql -At -v orig_path="$file" <<'EOF'
SELECT "originalFileName"
FROM asset
WHERE "originalPath" = :'orig_path'
  AND "deletedAt" IS NULL
  AND "libraryId" IS NULL
LIMIT 1;
EOF
)

  if [[ -z "$orig_name" ]]; then
    vlog "skip (not in DB / soft-deleted / already external): $file"
    SKIPPED_NOT_IN_DB=$((SKIPPED_NOT_IN_DB + 1))
    continue
  fi

  new_path="${DEST_DIR}${orig_name}"

  if [[ -e "$new_path" ]]; then
    vlog "skip (destination exists): $orig_name"
    SKIPPED_DEST_EXISTS=$((SKIPPED_DEST_EXISTS + 1))
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    vlog "would move: $file -> $new_path"
    MOVED=$((MOVED + 1))
    continue
  fi

  # Move the file. mv -n skips the move if the destination already exists but
  # exits 0 on both macOS and Linux — check that the source is gone to confirm
  # the move actually happened (catches the [[ -e ]] / mv race).
  mv -n -- "$file" "$new_path"
  if [[ -e "$file" ]]; then
    log "FAIL move (destination appeared mid-flight): $file -> $new_path"
    FAILED=$((FAILED + 1))
    continue
  fi

  # UPDATE asset record. The NOT EXISTS guard protects against the
  # (ownerId, libraryId, checksum) UNIQUE constraint WHERE libraryId IS NOT
  # NULL — without it, a content-duplicate already in the external library
  # would cause the UPDATE to abort and roll back, leaving a moved file with
  # an unchanged DB record (drift). With the guard, we skip cleanly.
  # Capture psql exit code explicitly — if psql fails, restore the file
  # before exiting so set -e doesn't leave a moved file with a stale DB path.
  if ! rows=$(psql -At \
    -v ON_ERROR_STOP=1 \
    -v orig_path="$file" \
    -v new_path="$new_path" \
    -v lib_id="$LIBRARY_ID" \
    <<'EOF'
WITH updated AS (
  UPDATE asset a SET
    "originalPath" = :'new_path',
    "isExternal"   = TRUE,
    "deviceId"     = 'Library Import',
    "libraryId"    = :'lib_id'::uuid
  WHERE a."originalPath" = :'orig_path'
    AND a."deletedAt" IS NULL
    AND a."libraryId" IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM asset s
      WHERE s."ownerId"   = a."ownerId"
        AND s."libraryId" = :'lib_id'::uuid
        AND s.checksum    = a.checksum
        AND s."deletedAt" IS NULL
    )
  RETURNING 1
)
SELECT COUNT(*) FROM updated;
EOF
  ); then
    log "FAIL DB (restoring): $orig_name"
    mv -- "$new_path" "$file" 2>/dev/null || log "WARN: could not restore $file after DB failure"
    FAILED=$((FAILED + 1))
    continue
  fi

  if [[ "$rows" == "1" ]]; then
    vlog "moved:    $file -> $new_path"
    MOVED=$((MOVED + 1))
  else
    # UPDATE returned 0 rows — the NOT EXISTS guard fired (checksum duplicate).
    # Move the file back to its source so we don't leak it.
    log "skip (constraint conflict, restoring): $orig_name"
    if mv -- "$new_path" "$file"; then
      SKIPPED_CONSTRAINT=$((SKIPPED_CONSTRAINT + 1))
    else
      log "WARN: could not restore $file — file stranded at $new_path"
      FAILED=$((FAILED + 1))
    fi
  fi

  # Progress every 500 files (silent during --verbose since vlog is per-file)
  if (( TOTAL % 500 == 0 )) && [[ "$VERBOSE" != true ]]; then
    log "progress: $TOTAL processed (moved=$MOVED)"
  fi
done < <(find "$SRC_DIR" -type f ! -name '.*' -print0)

# --- Summary ----------------------------------------------------------------

log ""
log "=== Summary ==="
log "Total files seen:         $TOTAL"
if [[ "$DRY_RUN" == true ]]; then
  log "Would move (dry-run):     $MOVED"
else
  log "Moved + DB updated:       $MOVED"
fi
log "Skipped (not in DB):      $SKIPPED_NOT_IN_DB"
log "Skipped (dest exists):    $SKIPPED_DEST_EXISTS"
log "Skipped (DB constraint):  $SKIPPED_CONSTRAINT"
log "Failed:                   $FAILED"

if [[ "$DRY_RUN" == true ]]; then
  log ""
  log "DRY-RUN: no changes made. Run without --dry-run to apply."
fi
