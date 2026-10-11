#!/usr/bin/env bash
#
# Immich Relocator
#
# Relocates files from Immich's upload dir into one or more external library
# folders and updates the corresponding asset records. Original sha1 content
# checksum is preserved so the iPhone/Android client's bulk-upload-check
# still matches — do NOT rewrite checksum to sha1-path or you'll trigger
# full re-upload.
#
# Supports any number of individual users (configured in .env) and an
# optional shared library (enabled by setting OWNER_SHARED to a real UUID).
#
# Options:
#   --dry-run     Count-only: prints total files to relocate, no side effects
#   --full        With --dry-run: runs Storage Template Migration job (if enabled) + detailed per-file report
#   --limit       E.g. --limit 1000 would relocate only the first 1000 pic/videos. Useful for large library relocations
#   --verbose     Log every file processed (not just the summary)
#   --help        Show this help and exit
#
# Please check https://github.com/bihius/immich-relocator for more info and configuration options
#
# IMPORTANT: All config is loaded from .env file. Please modify the .env.example template and rename it as .env
#
# Requires: psql in PATH (either system psql or a docker-exec wrapper)

set -euo pipefail

# --- Load config ---
source "$(dirname "$0")/.env"

# --- Validate required config (fail fast) ---------------------------------
: "${SRC_DIR:?ERROR: SRC_DIR not set in .env}"
: "${UPLOAD_MOUNT:?ERROR: UPLOAD_MOUNT not set in .env}"
: "${INDIVIDUAL_USERS_COUNT:?ERROR: INDIVIDUAL_USERS_COUNT not set in .env}"
: "${DEST_SHARED:?ERROR: DEST_SHARED not set in .env}"
: "${LIBRARY_NAME_SHARED:?ERROR: LIBRARY_NAME_SHARED not set in .env}"
: "${OWNER_SHARED:?ERROR: OWNER_SHARED not set in .env}"
: "${PGDATABASE:?ERROR: PGDATABASE not set in .env}"
: "${PGUSER:?ERROR: PGUSER not set in .env}"
: "${PGHOST:?ERROR: PGHOST not set in .env}"
: "${PGPORT:?ERROR: PGPORT not set in .env}"
: "${PGPASSWORD:?ERROR: PGPASSWORD not set in .env}"

LOCK_FILE="$(dirname "$0")/.lock"

# --- Load individual users from .env --------------------------------------
USERS_LABELS=()
USERS_DESTS=()
USERS_LIB_NAMES=()
USERS_LIB_IDS=()

for i in $(seq 1 "$INDIVIDUAL_USERS_COUNT"); do
  var="USER_${i}_LABEL"
  : "${!var:?ERROR: $var not set in .env}"
  USERS_LABELS+=("${!var}")

  var="USER_${i}_DEST"
  : "${!var:?ERROR: $var not set in .env}"
  USERS_DESTS+=("${!var}")

  var="USER_${i}_LIB_NAME"
  : "${!var:?ERROR: $var not set in .env}"
  USERS_LIB_NAMES+=("${!var}")
done

# Normalize destination paths (ensure trailing slash) ----------------------
for i in "${!USERS_DESTS[@]}"; do
  USERS_DESTS[$i]="${USERS_DESTS[$i]%/}/"
done
DEST_SHARED="${DEST_SHARED%/}/"

# --- Auto-generate RENAME_SED from user labels -----------------------------
RENAME_SED=""
for label in "${USERS_LABELS[@]}"; do
  rule="s|^library/${label}/[0-9]+/([^/]+)/|\1/${label}/|"
  if [[ -n "$RENAME_SED" ]]; then
    RENAME_SED="${RENAME_SED}; ${rule}"
  else
    RENAME_SED="${rule}"
  fi
done

# --- Parse args -------------------------------------------------------------

DRY_RUN=false
VERBOSE=false
FULL=false
LIMIT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --full)    FULL=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --limit) LIMIT="${2:?ERROR: --limit requires a number}"; shift 2 ;;
    --help)
      sed -n '2,15p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 1 ;;
  esac
done

# --- Helpers ----------------------------------------------------------------

log() { printf '[%s] %s\n' "$(date '+%Y-%m%d %H:%M:%S')" "$*"; }
vlog() { if [[ "$VERBOSE" == true ]]; then log "$@"; fi; }

# --- Preflight --------------------------------------------------------------

while true; do
  if ( set -C; echo $$ > "$LOCK_FILE" ) 2>/dev/null; then
    break
  fi
  lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
  if [[ -z "$lock_pid" ]] || ! kill -0 "$lock_pid" 2>/dev/null; then
    rm -f "$LOCK_FILE"
    continue
  fi
  echo "ERROR: another instance is running (PID $lock_pid)" >&2
  exit 1
done
trap 'rm -f "$LOCK_FILE"' EXIT

export LC_ALL=C
export PGDATABASE PGUSER PGHOST PGPORT PGPASSWORD

# --- Verify symlink exists ------------------------------------------------
SYMLINK_PATH="${SRC_DIR%/}"
if [[ ! -L "$SYMLINK_PATH" ]]; then
  echo "ERROR: Symlink $SYMLINK_PATH not found. Create it: sudo ln -s $UPLOAD_MOUNT $SYMLINK_PATH" >&2
  exit 1
fi

# --- Determine if shared library is enabled --------------------------------
if [[ "$OWNER_SHARED" == "00000000-0000-0000-0000-000000000000" ]]; then
  ENABLE_SHARED=false
else
  ENABLE_SHARED=true
fi

# --- Count-only dry-run (no relocation job, no library resolution needed) --
if [[ "$DRY_RUN" == true && "$FULL" != true ]]; then
  if ! COUNT=$(psql -At <<'EOF'
SELECT COUNT(*) FROM asset
WHERE "deletedAt" IS NULL
  AND "libraryId" IS NULL;
EOF
  ); then
    echo "ERROR: Failed to query database. Check PGHOST, PGUSER, PGPASSWORD in .env." >&2
    exit 1
  fi
  log "Files to relocate: $COUNT"
  exit 0
fi


# --- Resolve library UUIDs -------------------------------------------------
if [[ "$ENABLE_SHARED" == true ]]; then
  if ! LIB_ID_SHARED=$(psql -At -v lib_name="$LIBRARY_NAME_SHARED" <<'EOF'
SELECT id FROM library WHERE name = :'lib_name' AND "deletedAt" IS NULL;
EOF
  ); then
    echo "ERROR: Failed to query database. Check PGHOST, PGUSER, PGPASSWORD in .env." >&2
    exit 1
  fi
  if [[ -z "$LIB_ID_SHARED" ]]; then
    echo "ERROR: Library '$LIBRARY_NAME_SHARED' not found. Create it in Immich first." >&2
    exit 1
  fi
fi

for i in "${!USERS_LIB_NAMES[@]}"; do
  if ! lib_id=$(psql -At -v lib_name="${USERS_LIB_NAMES[$i]}" <<'EOF'
SELECT id FROM library WHERE name = :'lib_name' AND "deletedAt" IS NULL;
EOF
  ); then
    echo "ERROR: Failed to query database. Check PGHOST, PGUSER, PGPASSWORD in .env." >&2
    exit 1
  fi
  if [[ -z "$lib_id" ]]; then
    echo "ERROR: Library '${USERS_LIB_NAMES[$i]}' not found. Create it in Immich first." >&2
    exit 1
  fi
  USERS_LIB_IDS+=("$lib_id")
done


# --- Warn if RENAME_SED won't match -----------------------------------------
if ! echo "library/${USERS_LABELS[0]}/2026/test/file.jpg" | sed -E "$RENAME_SED" | grep -qv "library/"; then
  log "WARN: RENAME_SED does not match current storage labels — folder restructuring will be skipped."
fi

# --- Startup log ------------------------------------------------------------
log "=== Immich Relocator ==="
log "Mode:        $([[ "$DRY_RUN" == true ]] && echo DRY-RUN || echo APPLY)"
log "Source:      $SRC_DIR"
if [[ "$ENABLE_SHARED" == true ]]; then
  log "Shared:      $DEST_SHARED ($LIB_ID_SHARED)"
else
  log "Shared:      DISABLED (null UUID)"
fi
for i in "${!USERS_LABELS[@]}"; do
  log "$(printf '%-12s' "${USERS_LABELS[$i]}:") ${USERS_DESTS[$i]} (${USERS_LIB_IDS[$i]})"
done

# --- Create destination dirs ------------------------------------------------
if [[ "$DRY_RUN" == false ]]; then
  if [[ "$ENABLE_SHARED" == true ]]; then
    mkdir -p "$DEST_SHARED"
  fi
  for dest in "${USERS_DESTS[@]}"; do
    mkdir -p "$dest"
  done
fi

# --- Counters ---------------------------------------------------------------

TOTAL=0
MOVED=0
SKIPPED_NOT_ON_DISK=0
SKIPPED_DEST_EXISTS=0
SKIPPED_CONSTRAINT=0
SKIPPED_NO_MATCH=0
FAILED=0

# --- Bulk query: get files + routing flag (one psql call) --------------------
# Returns pipe-separated: originalPath | routing (shared|personal)

if ! FILES_TO_RELOCATE=$(psql -At -v src_prefix="$SRC_DIR" <<'EOF'
SELECT a."originalPath",
  CASE
    WHEN EXISTS (
      SELECT 1 FROM album_asset aa
      JOIN album_user au ON au."albumId" = aa."albumId"
      JOIN album al ON al.id = aa."albumId"
      WHERE aa."assetId" = a.id
        AND au.role != 'owner'
        AND al."deletedAt" IS NULL
    ) THEN 'shared'
    ELSE 'personal'
  END
FROM asset a
WHERE a."deletedAt" IS NULL
  AND a."libraryId" IS NULL
  AND a."originalPath" LIKE :'src_prefix' || 'library/%';
EOF
); then
  echo "ERROR: Failed to query assets from database. Check PGHOST, PGUSER, PGPASSWORD in .env." >&2
  exit 1
fi

# --- Warn if no files match expected path pattern ---------------------------
if [[ -n "$FILES_TO_RELOCATE" ]] && \
   ! echo "$FILES_TO_RELOCATE" | grep -q "library/${USERS_LABELS[0]}/\|library/${USERS_LABELS[1]}/"; then
  log "WARN: No files match expected path pattern. Check your storage template and storage labels."
fi

# --- Limit the Relocation to a set amount if limit flag is used -------------
if [[ "$LIMIT" -gt 0 ]]; then
  FILES_TO_RELOCATE=$(echo "$FILES_TO_RELOCATE" | head -n "$LIMIT")
  log "LIMIT: processing only first $LIMIT files."
fi

# --- Main loop --------------------------------------------------------------
while IFS='|' read -r file routing; do
  [[ -z "$file" ]] && continue
  TOTAL=$((TOTAL + 1))

  orig_name="${file##*/}"

  if [[ ! -e "$file" ]]; then
    vlog "skip (not on disk): $file"
    SKIPPED_NOT_ON_DISK=$((SKIPPED_NOT_ON_DISK + 1))
    continue
  fi

  # Determine destination, library ID, and ownership
  if [[ "$routing" == "shared" ]] && [[ "$ENABLE_SHARED" == true ]]; then
    dest="$DEST_SHARED"
    lib_id="$LIB_ID_SHARED"
    owner_id="$OWNER_SHARED"
    set_owner="true"
  else
    # Match path against each user's storage label
    dest=""
    lib_id=""
    for i in "${!USERS_LABELS[@]}"; do
      if [[ "$file" == *"/library/${USERS_LABELS[$i]}/"* ]]; then
        dest="${USERS_DESTS[$i]}"
        lib_id="${USERS_LIB_IDS[$i]}"
        break
      fi
    done
    if [[ -z "$dest" ]]; then
      log "WARN: No user label matched: $file — skipping."
      SKIPPED_NO_MATCH=$((SKIPPED_NO_MATCH + 1))
      continue
    fi
    owner_id="00000000-0000-0000-0000-000000000000"
    set_owner="false"
  fi

  rel_path="${file#"$SRC_DIR"}"
  rel_path="${rel_path//$'\r'/}"
  new_path="${dest}$(echo "$rel_path" | sed -E "$RENAME_SED")"

  if [[ -e "$new_path" ]]; then
    vlog "skip (destination exists): $orig_name"
    SKIPPED_DEST_EXISTS=$((SKIPPED_DEST_EXISTS + 1))
    continue
  fi

  if [[ "$DRY_RUN" == true ]]; then
    vlog "would move [$routing]: $file -> $new_path"
    MOVED=$((MOVED + 1))
    continue
  fi

  mkdir -p "$(dirname "$new_path")"
  mv -n -- "$file" "$new_path"
  if [[ -e "$file" ]]; then
    log "FAIL move (destination appeared mid-flight): $file -> $new_path"
    FAILED=$((FAILED + 1))
    continue
  fi

  if ! rows=$(psql -At \
    -v ON_ERROR_STOP=1 \
    -v orig_path="$file" \
    -v new_path="$new_path" \
    -v lib_id="$lib_id" \
    -v owner_id="$owner_id" \
    -v set_owner="$set_owner" \
    <<'EOF'
WITH updated AS (
  UPDATE asset a SET
    "originalPath" = :'new_path',
    "isExternal"   = TRUE,
    "libraryId"    = :'lib_id'::uuid,
    "ownerId"      = CASE WHEN :'set_owner' = 'true' THEN :'owner_id'::uuid ELSE a."ownerId" END
  WHERE a."originalPath" = :'orig_path'
    AND a."deletedAt" IS NULL
    AND a."libraryId" IS NULL
    AND NOT EXISTS (
      SELECT 1 FROM asset s
      WHERE s."ownerId"   = CASE WHEN :'set_owner' = 'true' THEN :'owner_id'::uuid ELSE a."ownerId" END
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
    vlog "moved [$routing]: $file -> $new_path"
    MOVED=$((MOVED + 1))
  else
    log "skip (constraint conflict, restoring): $orig_name"
    if mv -- "$new_path" "$file"; then
      SKIPPED_CONSTRAINT=$((SKIPPED_CONSTRAINT + 1))
    else
      log "WARN: could not restore $file — file stranded at $new_path"
      FAILED=$((FAILED + 1))
    fi
  fi

  if (( TOTAL % 500 == 0 )) && [[ "$VERBOSE" != true ]]; then
    log "progress: $TOTAL processed (moved=$MOVED)"
  fi
done <<< "$FILES_TO_RELOCATE"

# --- Summary ----------------------------------------------------------------

log ""
log "=== Summary ==="
log "Total files seen:         $TOTAL"
if [[ "$DRY_RUN" == true ]]; then
  log "Would move (dry-run):     $MOVED"
else
  log "Moved + DB updated:       $MOVED"
fi
log "Skipped (not on disk):    $SKIPPED_NOT_ON_DISK"
log "Skipped (dest exists):    $SKIPPED_DEST_EXISTS"
log "Skipped (DB constraint):  $SKIPPED_CONSTRAINT"
log "Skipped (no label match): $SKIPPED_NO_MATCH"
log "Failed:                   $FAILED"

if [[ "$DRY_RUN" == true ]]; then
  log ""
  log "DRY-RUN: no changes made. Run without --dry-run and --full to apply."
fi
