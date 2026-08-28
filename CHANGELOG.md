# Changelog

All notable changes to `db_repartition.sh` are documented here.

## [1.1.0] - 2026-08-28

### Added
- Non-interactive CLI flags for scripted and scheduled runs:
  `--mode`, `--db`, `--target`, `--db-list`, `--partitions`, `--yes`.
- `--help` / `-h` — usage summary.
- `--version` / `-V` — print script version.
- `require_value()` helper — rejects flags given without a value, or with
  another flag as their value (e.g. `--db --target`), instead of silently
  accepting the flag name as a database name.
- Post-parse validation of CLI values: `--mode` must be 1/2/3,
  `--partitions` must be a positive integer within the 104 cap, and
  `--db` / `--db-list` are rejected as mutually exclusive.
- Unknown flags now fail immediately rather than being ignored.
- Script version is logged in the opening banner of every run.

### Changed
- All six interactive prompts now accept a CLI-supplied value and skip the
  prompt when one is given. With no flags, behavior is unchanged.
- `confirm_or_exit()` honors `--yes`, logging each auto-approved gate so
  bypassed confirmations remain visible in the run log.
- Password prompt errors out instead of hanging when `--yes` is set and no
  credential source is configured.

## [1.0.0] - 2026-06-10

### Added
- Initial version: three operation modes (single database, `_vew` batch,
  non-`_vew` batch via intermediate database).
- Pipeline DDL dump/restore, parallel table copy, and pre/post-migration
  validation of object and row counts.
