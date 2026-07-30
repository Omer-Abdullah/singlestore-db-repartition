# SingleStore 8.9 Compatibility Notes

Things learned the hard way while automating against SingleStore **8.9.34**
on RHEL 8. Worth checking against current SingleStore docs before relying on
these for a different version — some of these are version-specific quirks,
not general SingleStore behavior.

## SQL / syntax

- `DATETIME` precision only supports `0` or `6` — not `3`.
- `YEARWEEK()` is unsupported. Use `(YEAR(col) * 100 + WEEK(col, 3))` instead.
- CTEs are unsupported inside views. Use `MAX() + INNER JOIN` deduplication
  patterns instead.
- `GROUP_CONCAT` with `ORDER BY` combined with `DISTINCT` is unsupported —
  push the deduplication into a subquery layer first.
- No `WITH PARTITIONS` option exists in `REPLICATE DATABASE`.
- `TRUNCATE` is not a grantable privilege on its own — it's covered by the
  `DROP` privilege.

## information_schema / mv_ views

- `MV_TABLES_INFO` does not exist — use
  `information_schema.COLUMNAR_SEGMENTS` instead.
- `mv_sysinfo` does not exist — the correct views are `mv_sysinfo_mem`,
  `mv_sysinfo_cpu`, `mv_sysinfo_disk` (verify column names against your
  version).
- `MV_ACTIVITIES_CUMULATIVE` can discard historical statistics at unspecified
  times, without a node restart. Don't rely on it alone for before/after
  performance comparisons — snapshot separately if you need durable
  comparisons.
- `information_schema.SCHEMATA` has no `CREATE_TIME` column in 8.9.
  Approximate database creation time with `MIN(CREATE_TIME)` from
  `information_schema.TABLES` instead.
- Mixing `information_schema` views with user-table queries in a single
  statement triggers `ERROR 1749` (a distributed query restriction). Split
  into separate queries.
- `MV_PLANCACHE` only reflects in-memory plans — on-disk plans are not
  surfaced there.

## Cluster / node operations

- `DETACH LEAF FORCE` does not exist — use `REMOVE LEAF ... FORCE`.
- `REMOVE NODE` does not exist — use the role-specific command
  (`REMOVE LEAF`, `REMOVE AGGREGATOR`).
- `DETACH LEAF` requires the leaf to be in `online` state. For offline or
  stuck nodes, use `memsqlctl stop-node` / `memsqlctl delete-node` locally on
  the target host instead of SQL commands.
- A directly-killed `memsqld` process gets respawned by the watchdog
  (`memsqld_safe`) — always use `memsqlctl stop-node` first for a clean
  shutdown.

## Output parsing gotchas

- `SHOW CREATE PIPELINE` with `--skip-column-names` still includes the
  pipeline name as the first column — strip it with
  `awk '{$1=""; sub(/^ /,""); print}'`. The output also contains literal
  `\n` sequences that need converting to real newlines before restore
  (`sed 's/\\n/\n/g'`).
- `SHOW CREATE VIEW` output line-wraps at roughly 100 characters, which can
  split backtick-quoted identifiers, keywords, or numeric literals across
  lines. This breaks naive automated restores — extract and repair view DDL
  as a separate step before any automated schema migration.

## Privileges

- `ER_NONEXISTING_GRANT` on a `REVOKE` usually means the privilege was
  granted globally (`ON *.*`) rather than at the database level. Privilege
  scripts need to be scope-aware.

## Shell scripting notes (RHEL 8, not SingleStore-specific but related)

- Use `printf` instead of `echo` to avoid `-n` being printed literally in
  some shells.
- Prefer `set -uo pipefail` as a baseline; avoid blanket `set -e` in scripts
  where an individual query failure shouldn't abort the whole run.
- Under `sh`, heredoc SQL blocks can trigger `EOF` parsing errors — prefer
  inline `--execute="..."` strings for one-off queries.

---

Contributions/corrections welcome as we hit more of these — please include
the exact error message and the SingleStore version when adding a new entry.
