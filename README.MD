<div align="center">

# Immich Relocator

**Your photos. Your folders. Still in Immich.**

Move photos and videos from Immich's internal storage into external libraries — and update the existing asset records instead of starting over.

[Quick start](#quick-start) · [Configuration](#configuration) · [Usage](#usage) · [Optional features](#optional-features) · [Recovery](#backups--recovery)

</div>

---

## Keep the library. Move the files.

Moving files alone leaves Immich pointing at the wrong paths. Immich Relocator moves the originals and updates their database records, retaining existing asset IDs and album associations.

| Feature | What you get |
| --- | --- |
| **One or many libraries** | Send everything to one destination, or route files to a library per user. |
| **Storage templates** | Optionally run Immich's Storage Template Migration job before relocation. |
| **Folder restructuring** | Turn a supported storage-template layout into album-first folders. |
| **Shared-library routing** | Optionally transfer assets from shared albums to a dedicated `UserShared` account. |
| **Batch limits** | Process a smaller batch with `--limit N`. |
| **Database backups** | The launcher saves a timestamped SQL dump before relocation and retains a configurable number. |
| **Checksums preserved** | Leave content hashes unchanged for mobile upload checks. Ownership changes have separate deduplication risks. |
| **Destination protection** | Skip existing paths; use `mv -n` rather than overwrite destination files. |

Use an external library as the common home for Immich and a desktop DAM such as digiKam or Lightroom. Read-only access for Immich is an option after relocation; the host process performing moves still needs write access.

> [!WARNING]
> This tool moves original files and writes directly to Immich's database. Back up **both your media and database** before running it. Filesystem moves and database updates are not one transaction, and compatibility can change after an Immich update.

## Quick start

### 1. Check the prerequisites

The documented setup targets a Linux host running Immich with Docker Compose.

- Bash 4+, Docker with Compose, and standard GNU command-line tools, including `grep -P`.
- `curl` if you enable the optional Storage Template Migration job.
- An existing external library in Immich for each destination you intend to use.
- Destination directories writable by the host user running the script and accessible to Immich at the recorded paths.
- Access to the PostgreSQL container and permission to stop/start the `immich-server` Compose service.
- A host-side symlink matching Immich's internal upload path.

The bundled [`psql`](psql) wrapper runs the PostgreSQL client inside your database container. You do not need a separate host installation of `psql` for this setup.

### 2. Download and configure

```bash
git clone https://github.com/bihius/immich-relocator.git
cd immich-relocator
cp .env.example .env
chmod 600 .env
nano .env
```

Use [`.env.example`](.env.example) as the configuration reference. It includes explanations and user blocks you can copy.

For a single-library setup, configure at least:

```bash
# Docker Compose and media paths.
COMPOSE_DIR="/home/youruser/immich"
UPLOAD_MOUNT="/mnt/immich"
SRC_DIR="/usr/src/app/upload/"

# Database values from your Immich installation.
POSTGRES_CONTAINER="immich_postgres"
PGDATABASE="immich"
PGUSER="postgres"
PGHOST="your-pg-container-ip"
PGPORT="5432"
PGPASSWORD="your-database-password"

# Existing external library: match its name exactly.
EXTERNAL_LIBRARIES_COUNT=1
SINGLE_LIB_NAME="Everyone Pictures"
SINGLE_DEST="/mnt/external-library/"

# Keep shared ownership changes disabled initially.
OWNER_SHARED="00000000-0000-0000-0000-000000000000"
BACKUP_RETENTION_COUNT=5
```

These are examples, not paths to copy blindly. `SRC_DIR` must match the prefix stored in your asset records and end in `/`. The script normalizes trailing slashes on destination paths.

> [!IMPORTANT]
> Single-library mode routes eligible assets from **all users** to the same library without changing ownership. Mixing owners in one user's external library is not officially supported by Immich. Prefer a library per user on multi-user installations.

### 3. Make the database paths reachable on the host

If Immich records paths under `/usr/src/app/upload/` but your host stores those files under `/mnt/immich`, create a symlink between them.

Start with:

```bash
./relocator.sh --dry-run
```

If it reports `Symlink … not found`, inspect the suggested command and create the symlink for your installation. Do not replace an existing directory or symlink without checking what it contains.

`SRC_DIR` must be a symlink, and its target should be your configured `UPLOAD_MOUNT`. Verify that a representative asset's recorded path resolves to the intended file on the host.

### 4. Preview, then try a small batch

```bash
# Count non-deleted assets that are not already in an external library.
./relocator.sh --dry-run

# Inspect candidate paths and routing.
./relocator.sh --dry-run --full --verbose

# After backups and review, process a small batch.
./relocator.sh --limit 2 --verbose

# Inspect the result in Immich before running the full relocation.
./relocator.sh
```

> [!CAUTION]
> `--dry-run --full` is **not side-effect-free** when `IMMICH_API_KEY` is configured: it runs a Storage Template Migration job, which can move files within Immich's internal storage. It does not relocate files into external libraries, stop the server, or create the launcher's database backup. Take your own backup before using it.

## Configuration

Both scripts source `.env` from the script directory. Treat it as trusted shell code, keep credentials private, and do not commit your populated file.

### Database and paths

| Variable | Purpose |
| --- | --- |
| `COMPOSE_DIR` | Directory containing your Immich Compose file. |
| `UPLOAD_MOUNT` | Host directory containing Immich's internal `upload` and `library` folders. |
| `SRC_DIR` | Immich's recorded upload-root prefix, exposed as a host-side symlink; include the trailing `/`. |
| `POSTGRES_CONTAINER` | PostgreSQL container name; defaults to `immich_postgres`. |
| `PGDATABASE`, `PGUSER`, `PGPASSWORD` | Database name and credentials. |
| `PGHOST`, `PGPORT` | Connection target passed to `psql` **inside** the PostgreSQL container. |
| `BACKUP_RETENTION_COUNT` | Number of timestamped SQL backups to retain; template value: `5`. |

For the default container name, this command can help find its network IP:

```bash
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' immich_postgres
```

### Library routing

| Variable | Purpose |
| --- | --- |
| `EXTERNAL_LIBRARIES_COUNT` | `1` for single-library mode; greater than `1` for per-user routing. Do not include the optional shared account. |
| `SINGLE_LIB_NAME`, `SINGLE_DEST` | Existing library name and destination for single-library mode. |
| `USER_N_LIB_NAME` | Existing personal library name for user block `N`. |
| `USER_N_DEST` | Host destination for that user. |
| `USER_N_LABEL` | Storage label appearing in that user's `library/<label>/…` path. |
| `OWNER_SHARED` | Shared-account UUID; the all-zero UUID disables ownership transfer. Required even when disabled. |
| `LIBRARY_NAME_SHARED`, `DEST_SHARED` | Shared library name and destination. Fill these in for multi-library mode, even if ownership transfer is disabled. |

For multi-library mode, add consecutive `USER_1_*`, `USER_2_*`, … blocks and set the count accordingly. Match library names exactly. Each personal library should belong to its corresponding user.

Use the configured storage label for `USER_N_LABEL`. Without a label, use the UUID present in the path, or `admin` for the first admin account when that is the directory name. Routing matches paths, not display names.

Multi-library routing expects files under `library/<label>/…`. Enable Storage Template in Immich and run its migration job, either through this tool or manually in Immich, before relocation. Files left under an unmatched `upload/…` path are skipped.

### Optional behavior

| Variable | Purpose |
| --- | --- |
| `IMMICH_API_KEY` | Empty to skip automatic Storage Template Migration. Otherwise supply a key with `job.create` and `queue.read` permissions. |
| `IMMICH_API_URL` | Immich base URL; defaults to `http://localhost:2283`. |
| `FOLDER_RESTRUCTURE` | `true` to enable the supported multi-library path transformation; defaults to `false`. |

## Usage

Use **`relocator.sh`** for normal runs. It coordinates the API job, server shutdown, backup, relocation, and restart. `core.sh` performs the database/file work but does not provide the launcher's backup and server lifecycle handling.

| Command | Behavior |
| --- | --- |
| `./relocator.sh --dry-run` | Count non-deleted, non-external assets. No external relocation, server shutdown, or API job. |
| `./relocator.sh --dry-run --full --verbose` | Optionally run Storage Template Migration, then log candidate moves. No external relocation or server shutdown. |
| `./relocator.sh` | Optionally run Storage Template Migration, check the count, stop `immich-server`, back up PostgreSQL, relocate, and attempt to restart the server on exit. |
| `./relocator.sh --limit 1000` | Apply to at most the first 1,000 queried candidates. Skipped candidates count toward the limit. |
| `./relocator.sh --verbose` | Apply with per-file logging. |
| `./core.sh --help` | Show core help after loading and validating `.env`. Use this rather than the launcher for help-only access. |

The count-only preview is not a guaranteed move count: it does not check the source-path filter, file existence, routing, destination collisions, or checksum conflicts. Full preview checks candidate paths but does not execute the database duplicate guard. `--verbose` is needed to see individual candidate moves.

Plain dry-run still creates and removes the core PID lock. Keep runs sequential: the core lock does not serialize the launcher's earlier API, shutdown, and backup steps.

### What happens during relocation

1. Query eligible assets under the configured source prefix, excluding trashed and already-external records.
2. Route each asset to the single, personal, or enabled shared library.
3. Derive its relative destination path and skip existing destinations.
4. Move the file using `mv -n`.
5. Update `originalPath`, `isExternal`, and `libraryId`; update `ownerId` only for shared-account transfers.
6. Guard against a non-deleted asset with the same target owner, library, and checksum.
7. If the update fails or changes no rows, attempt to return the file to its source.
8. Report counters; the launcher removes empty subdirectories under `UPLOAD_MOUNT/library` and attempts to restart the server on exit.

Media content and checksums are not rewritten. Without restructuring, the destination preserves the relative path beneath `SRC_DIR`, minus a leading `library/` or `upload/`. It uses the filename already on disk, not a separate rename to the asset's `originalFileName`.

Existing asset records retain their associations, but this is not a guarantee that every Immich feature remains consistent after an ownership change. Read the shared-account warnings below.

## Optional features

### Storage Template Migration

Create an Immich API key with these permissions:

```text
job.create
queue.read
```

Set `IMMICH_API_KEY` and, if needed, `IMMICH_API_URL` in `.env`.

The launcher starts the job and polls its queue before relocation. It checks HTTP responses and paused-queue status, with a polling wait limit of approximately one hour, plus request time. Leave the key empty to skip the job.

The job runs **before** the launcher's database backup. Back up independently if you need a recovery point from before template migration.

### Folder restructuring

Use this with multi-library mode and a storage-template layout matching:

```text
library/<label>/<year>/<album>/<remaining-path>
```

The transformation produces:

```text
<album>/<label>/<remaining-path>
```

For example, set this template in Immich under **Administration → Settings → Storage Template**:

```text
{{y}}/{{album-startDate-y}}-{{album-startDate-MM}} - {{{album}}}/{{make}}_{{model}}/{{filename}}
```

Then configure user storage labels, arrange the files using Storage Template Migration, and set:

```bash
FOLDER_RESTRUCTURE=true
```

Preview using `./relocator.sh --dry-run --full --verbose` before applying. The transformation is defined in `core.sh`; arbitrary source layouts will not necessarily match.

An illustrative destination layout:

```text
external-library/
├── 2023-02 - Japan/
│   ├── Joe/
│   │   └── Sony_a7-IV/
│   │       └── 20230201-081423.jpg
│   └── Andrea/
│       └── Canon_R6/
│           └── 20230201-112823.jpg
└── 2024-08 - Fishing/
    └── Joe/
        └── Sony_a7-IV/
            └── 20240801-081423.jpg
```

> [!WARNING]
> On case-insensitive destinations, including some CIFS/SMB configurations, an existing directory's casing can differ from the recorded database path. A later library scan may then create duplicate assets. Inspect actual paths and casing before rescanning. Camera make/model template fields can expose this problem.

### Pseudo `UserShared`

This optional workaround lets partners see selected shared media through Partner Sharing without sharing every personal asset.

Create a dedicated Immich account and external library. Enable Partner Sharing from that account to the intended partners. In multi-library mode, set:

```bash
OWNER_SHARED="uuid-of-the-shared-account"
LIBRARY_NAME_SHARED="Shared User Pictures"
DEST_SHARED="/mnt/external-library-shared/"
```

Do not include this account in `EXTERNAL_LIBRARIES_COUNT`. Use the expected storage-template layout; automatic migration and folder restructuring can help prepare and organize it.

| Asset belongs to… | Destination | Ownership |
| --- | --- | --- |
| At least one non-deleted album with a non-owner participant | Shared library, when enabled | Changed to `OWNER_SHARED` |
| No such album | Personal library selected by storage label | Unchanged |

For example, photos from Joe and Andrea in a shared “Japan” album can move into the shared account's library. Their private albums route to their personal libraries. Existing album membership is retained; the asset owner changes, not the album owner.

**Read these limits before enabling ownership transfer:**

- **Any shared album qualifies.** Routing does not check whether the participant is your partner or someone else.
- **Album membership controls classification.** Review assets outside albums; they route as personal. The existing setup guidance recommends placing all media into appropriate shared or private albums.
- **Mobile duplicates can return.** Deduplication is owner-specific. Ownership transfer can cause media still on the original users' devices to upload again. After verifying independent backups, remove those already-uploaded files from the devices before transferring ownership, or leave this feature disabled. Do not delete server assets as a substitute.
- **Stacks can become inconsistent.** Asset ownership changes, but the stack container retains its original owner. The script warns about affected stacked assets; it does not skip them. Unstack first or avoid ownership transfer for those libraries.
- **Faces stay with the original owner.** This tool does not transfer person records or regenerate faces for the shared account.

Leave `OWNER_SHARED` at `00000000-0000-0000-0000-000000000000` to disable this feature.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| `another instance is running` | Wait for the active core run to finish. Stale PID locks are handled automatically; do not remove an active run's `.lock`. |
| `immich-server is not running` | Check your stack in `COMPOSE_DIR`; start it with `docker compose up -d` if appropriate. |
| `Failed to query database` | Verify the container name, database credentials, host, and port in `.env`. `PGHOST` is used from inside the database container. |
| `Library '…' not found` | Match the existing library's name exactly, including case. |
| `Symlink … not found` | Check `SRC_DIR`, `UPLOAD_MOUNT`, and the suggested host-side symlink. |
| `RENAME_SED does not match` | Compare your actual source paths, storage labels, and template against the expected restructuring layout. |
| `Skipped (no label match)` | Review storage labels and whether files are still under `upload/` rather than `library/<label>/`. |
| `Skipped (dest exists)` | Inspect the existing destination. The script neither merges nor renames colliding files. |
| `Skipped (DB constraint)` | The update changed no rows and the file was restored; a matching checksum is one possible cause. |
| `Database backup appears truncated or empty` | The launcher checks for a nonempty dump and its completion marker. Investigate the dump failure before retrying; this is not a restore test. |
| Restoration warnings or nonzero `Failed` count | Inspect both source and destination paths against the database before another run. |

A run can report failed files without returning a nonzero exit status. Always read the summary and warnings. Server restart is attempted, not guaranteed; verify Immich is running afterward.

## Scheduled runs

Only schedule after a successful manual run and review of the resulting paths. Use absolute paths and ensure the cron user has Docker access and the required tools in `PATH`.

Example: daily at 03:00, with output retained:

```cron
0 3 * * * /home/youruser/immich-relocator/relocator.sh >> /home/youruser/immich-relocator/cron.log 2>&1
```

Avoid overlapping launcher runs. Allow time for template migration and backups. If `UserShared` is enabled, resolve the mobile re-upload risk before the scheduled ownership transfer.

## Backups & recovery

The launcher writes plain SQL dumps to:

```text
db-backups/immich_backup_YYYYMMDD_HHMMSS.sql
```

It retains `BACKUP_RETENTION_COUNT` backups and removes older matching files. Copy important recovery points elsewhere. These dumps contain private database contents; restrict access to the backup directory.

**A database restore does not move media files back.** Before restoring:

1. Stop `immich-server` from your configured Compose directory.
2. Preserve the current database and filesystem state for investigation.
3. Identify the correct backup and reconcile file locations with the paths that backup records.
4. Restore using a procedure appropriate to your Immich/PostgreSQL version.
5. Check restore errors and file accessibility before restarting Immich.

The basic commands from the existing recovery procedure are shown below. Replace every value with your actual configuration. Replaying a plain SQL dump into a populated database can conflict with existing objects; this is **not** a complete clean-restore procedure.

```bash
cd /path/to/your/immich/folder
docker compose stop immich-server

# Only after preparing the restore target and reconciling media paths:
docker exec -i immich_postgres psql -U postgres immich \
  < /path/to/immich-relocator/db-backups/immich_backup_YYYYMMDD_HHMMSS.sql

# Only after verifying that restoration succeeded:
docker compose up -d immich-server
```

Per-file rollback only covers updates the script detects as failed or skipped. It does not undo earlier successful relocations, template migration, or a process interruption.

## Boundaries & disclaimer

- Trashed and already-external assets are excluded.
- This tool does not re-encode media or move thumbnails, face data, or search embeddings.
- It does not merge duplicates or deduplicate across different external libraries.
- It does not provide a transaction spanning PostgreSQL and the filesystem.
- Direct schema access and API behavior can change between Immich releases. Recheck compatibility and start with a small batch after updates.

Use on backed-up data, inspect the result, and keep a tested recovery path.
