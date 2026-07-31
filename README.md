# SingleStore DB Repartitioning

A single operational script (`db_repartition.sh`) that changes the partition
count of one or more SingleStore databases while preserving all data,
schema, routines, triggers, and pipelines.

Built for a project reducing partition counts across ~120 over-provisioned
production databases on **SingleStore 8.9.34 / RHEL 8.1**.

## Why this exists

SingleStore doesn't support changing a database's partition count in place —
the database has to be dropped and recreated. This script automates that
safely, with validation gates so a failed run never leaves you with zero
working copies of the data.

## What it does

1. Captures current state (size, partition count, table/view/routine/pipeline
   counts, active queries) and shows it to the operator before anything happens
2. Dumps schema (+ data, depending on mode) and pipeline DDL separately
   (`SHOW CREATE PIPELINE` isn't captured by `mysqldump`)
3. Stops pipelines to freeze row counts before any copy
4. Drops and recreates the database with the new partition count
5. Restores schema/data/pipelines
6. **Validates** — compares table/view/routine/pipeline counts and per-table
   row counts between source and destination before the source is considered
   safe to drop, and again after the final restore
7. Restarts pipelines

## Operation modes

| Mode | Use case | Flow |
|---|---|---|
| **1 — Single database** | One database, picked interactively | Three sub-paths depending on naming (see below) |
| **2 — Multi-DB, `_vew` only** | Batch of view-only databases, same target partition count | Full dump → drop → recreate → restore, per DB, one upfront confirmation |
| **3 — Multi-DB, non-`_vew`** | Batch of regular databases, same target partition count | Intermediate-DB path (see below), pre-flight validation for the whole batch upfront |

### Single-DB sub-paths (Mode 1)

- **`_vew` databases** (naming convention for view-only DBs, target name ==
  source name): full dump → drop → recreate → restore. Low risk since these
  are expected to hold only views.
- **Plain DB → `<db>_tbl`**: direct clone to a new database name. Source is
  left untouched — this is a side-by-side copy, not an in-place repartition.
- **Plain DB, target name == source name**: goes through an intermediate
  database (`<db>_interm`) as a safety net — data is copied there, validated,
  *then* the source is dropped and rebuilt, then data is copied back and
  validated again. This is the path used for the bulk of the migration.

### Batch mode notes (Modes 2 & 3)

- Mode 3 runs full pre-flight validation (naming, existence, leftover
  `_interm` conflicts) across the **entire batch** before touching any
  database, so one bad database name in a list of 20 doesn't cause a partial run.
- In batch mode, `_interm` databases are **not** auto-dropped — the script
  prints a manual cleanup list (`DROP DATABASE` statements) at the end so an
  operator can spot-check the rebuilt databases first.
- Each database in a batch still gets one manual confirmation gate — the
  `DROP DATABASE` on the source — tagged with its position (`[3/12]`, etc.).
  Everything else in batch mode runs unattended (logged as `AUTO`).

## Prerequisites

- `memsql` CLI and `mysqldump` on the host running the script
- A readable credentials source for the SingleStore user (see
  [Configuration](#configuration))
- Enough free space in the dump directory for a schema (or full, for `_vew`)
  dump of the largest database being repartitioned
- For databases with views: extract and repair view DDL **first** —
  `SHOW CREATE VIEW` output line-wraps in SingleStore 8.9 and can corrupt
  automated restores if not handled separately (see
  [`docs/COMPATIBILITY_NOTES.md`](docs/COMPATIBILITY_NOTES.md))

## Configuration

The script reads connection settings from environment variables, So make sure to set the environment variables.
By default, if env vars are not set, expect execution failuer:

| Variable | Default | Purpose |
|---|---|---|
| `SS_HOST` | - | Master Aggregator host |
| `SS_PORT` | - | Port |
| `SS_USER` | - | SQL user |
| `SS_PASSWORD` | - | SQL user password |
| `DUMP_DIR` |- | Where dumps/logs are written |
| `PARALLEL_JOBS` | `8` | Concurrent `INSERT ... SELECT` copy jobs |


## Usage

```bash
export SS_HOST=10.x.x.x        # your Master Aggregator
export DUMP_DIR=/dump/dir
export PARALLEL_JOBS=4         # tune it based on the available resources / tables size
./db_repartition.sh
```

The script is fully interactive — it prompts for mode, database name(s), and
target partition count, and shows a summary table before any destructive step.

## Safety model summary

| Stage | Destructive? | Confirmation required? |
|---|---|---|
| Metrics collection / summary | No | No |
| Schema/full dump | No (read-only against source) | Yes in single-DB mode, AUTO in batch |
| Create intermediate/target DB | No | AUTO |
| Data copy into intermediate/target | No (source untouched) | AUTO |
| Validation | No | N/A — blocks progress on failure |
| **`DROP DATABASE` (source)** | **Yes** | **Always — every mode** |
| Recreate + restore | No (source already gone; interm/dump is the backup) | AUTO |
| Final validation | No | N/A — blocks pipeline restart on failure |
| Drop intermediate DB | Yes | Yes (single-DB); manual, deferred (batch) |

## Known limitations / gotchas

- No `WITH PARTITIONS` option exists in `REPLICATE DATABASE` in SingleStore
  8.9 — this script does not touch DR replication.
- `MV_ACTIVITIES_CUMULATIVE`-based stats can be reset by SingleStore at
  unspecified times — don't rely on it alone for before/after performance
  comparisons across a repartition.
- Partition count is capped at 104 in this script (adjust the check if your
  cluster's leaf count allows more).
- See [`docs/COMPATIBILITY_NOTES.md`](docs/COMPATIBILITY_NOTES.md) for the
  full list of SingleStore 8.9 syntax/behavior quirks this script works
  around.

## Security notes

- Replace any hardcoded internal IPs, hostnames, or credential file paths
  with environment variables.
- Dumps and logs are written outside this repo by default
  (`DUMP_DIR`/`LOG_FILE`); `.gitignore` also excludes common dump/log
  patterns as a second layer of protection.

## License

See [LICENSE](LICENSE) — currently marked internal-use-only. Swap for
MIT/Apache 2.0 if you want to open this up.
