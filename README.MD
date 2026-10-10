# Immich Relocator

## Overview
This script relocates files from the Immich `upload` directory to a defined external library folder and updates their corresponding entries in the PostgreSQL database.

## Features
- Relocates non-hidden files from the upload directory into a permanent external library
- Updates PostgreSQL records to reflect the new file paths and marks assets as external library items
- Sets `isExternal`, `deviceId`, and `libraryId` fields to prevent Immich from re-importing files
- Prevents duplicate relocations (`mv -n`)
- Fully configurable via environment variables at the top of the script
- Preserves original asset's file name
- `--dry-run` mode shows exactly what would change before any relocate/UPDATE
- File-level locking prevents concurrent runs from corrupting state
- NOT EXISTS guard against the `(ownerId, libraryId, checksum)` UNIQUE
  constraint — content-duplicates already in the external library are
  skipped cleanly instead of aborting and leaving a half-relocated state
- Restores the relocated file to source if the DB UPDATE skips it (no leaked files)
- Per-file progress + final summary counters

## Requirements
- Bash shell
- `psql` (PostgreSQL client) — version 14+ recommended
- Access to Immich's PostgreSQL database

## Configuration

All configuration is via environment variables (or by editing the defaults at the top of the script):

```
SRC_DIR=/opt/immich/upload/upload/   # default for Proxmox-helper-scripts installs
DEST_DIR=/mnt/external_library/
LIBRARY_NAME="External Library"      # name of your external library in Immich
PGDATABASE=immich
PGUSER=immich
PGHOST=localhost
PGPORT=5432
PGPASSWORD=password
LOCK_FILE=/tmp/immich-migrate-to-external-library.lock
```

For better security, use a `~/.pgpass` file instead of `PGPASSWORD`.

## Usage

```bash
chmod +x core.sh

./core.sh --dry-run --verbose   # preview what would happen
./core.sh                       # apply changes
./core.sh --verbose             # apply + log every file (not just summary)
./core.sh --help                # show usage
```

The script will:
1. Find all non-hidden files under `SRC_DIR`
2. For each file, look up the asset record by `originalPath`
3. Relocate the file to `DEST_DIR/<originalFileName>` (preserving the asset's name)
4. UPDATE the asset's `originalPath`, `isExternal`, `deviceId`, `libraryId` in one atomic CTE
5. If the UPDATE is skipped by the NOT EXISTS guard (content duplicate), restore the file to `SRC_DIR` so the source is unchanged

## Important caveats

- **Create your external library in Immich first** and set `LIBRARY_NAME` to match its name exactly.
- **Duplicate filenames across different folders** in `SRC_DIR` will collide at `DEST_DIR/<originalFileName>`. The script's `[[ -e ... ]]` check + `mv -n` prevents overwrite — these files will be skipped (counter `SKIPPED_DEST_EXISTS`). Re-run after resolving manually.
- **Don't rewrite `checksum` to sha1-path** (the format Immich's library scan creates). The mobile bulk-upload-check matches by content sha1 only — switching to sha1-path will trigger the iOS/Android client to re-upload its entire library. Keep `checksumAlgorithm = 'sha1'` (which this script does, by leaving the field unchanged).
- Use version control / database backups before running on production data. `pg_dump immich` is your friend.
- The script preserves the asset's `originalFileName` as the destination — if you want subdirectory organization (e.g., year/month folders), edit the `new_path` line in the script.

## What the script does NOT do

- It does not relocate files in trashed assets (`deletedAt IS NOT NULL`).
- It does not relocate already-external assets (`libraryId IS NOT NULL`).
- It does not change checksums (correctly — see caveat above).
- It does not handle the case of a duplicate already in the external library (gracefully skips with the NOT EXISTS guard).
