#!/bin/bash
# =============================================================================
# db_repartition.sh — SingleStore Database Repartitioning Script
# Red Hat Linux 8.1
#
# Tools used:
#   memsql     — all DB connections, SQL execution, and dump restore
#   mysqldump  — export only (called directly from this script)
#
# =============================================================================

# ── Script version ────────────────────────────────────────────────────────────
# Semantic versioning: MAJOR.MINOR.PATCH
#   MAJOR — breaking change to CLI/behavior that requires operator action
#   MINOR — new backwards-compatible feature (e.g. new flag)
#   PATCH — bug fix, no interface change
VERSION="1.1.0"

set -euo pipefail

# ── Colour codes for terminal output ─────────────────────────────────────────
RED='\033[0;31m'
YELLOW=$'\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
BOLD='\033[1m'
BOLD1=$'\033[1m'
NC='\033[0m'

# ── Runtime config — override via environment variables if needed ──────────────
SS_HOST="${SINGLESTORE_HOST:?set SS_HOST}"
SS_PORT="${SINGLESTORE_PORT:?set SS_PORT}"
SS_USER="${SINGLESTORE_USER:?set SS_USER}"
SS_PASSWORD=
DUMP_DIR="${DUMP_DIR:-/default/dump/directory}"
PARALLEL_JOBS="${PARALLEL_JOBS:-8}"   # concurrent INSERT SELECT jobs; tune to CPU/IO headroom
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$HOME/ss_logs/name_${TIMESTAMP}.log"


# ── Prefixes every message with a timestamp ───────────────────────────────────
log() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

# ── Log line + script location whenever the shell aborts unexpectedly ────────
# Fires on any unhandled non-zero exit (set -e), broken pipe, or unset variable.
# error_exit already logs cleanly; this catches everything else.
trap 'rc=$?; log "${RED}FATAL: script aborted at line ${BASH_LINENO[0]} (exit ${rc}). See ${LOG_FILE}.${NC}"' ERR

# ── Prints a clearly visible section header ───────────────────────────────────
banner() {
    echo -e "\n${BLUE}${BOLD}=== $* ===${NC}\n"
}

# ── Logs an error and exits immediately ───────────────────────────────────────
error_exit() {
    log "${RED}ERROR: $*${NC}"
    exit 1
}

# ── Validate that a flag's value exists and isn't another flag ────────────────
require_value() {
    local flag="$1" value="${2:-}"
    if [[ -z "${value}" ]]; then
        error_exit "Option '${flag}' requires a value, but none was given."
    fi
    if [[ "${value}" == -* ]]; then
        error_exit "Option '${flag}' requires a value, but got '${value}' (which looks like another flag)."
    fi
}

# ── CLI flag parsing — enables non-interactive/scripted runs ──────────────────
AUTO_YES=false
CLI_MODE=""
CLI_DB=""
CLI_TARGET=""
CLI_DB_LIST=""
CLI_PARTITIONS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)
            AUTO_YES=true
            shift
            ;;
        --mode)
            require_value "$1" "${2:-}"
            CLI_MODE="$2"
            shift 2
            ;;
        --db)
            require_value "$1" "${2:-}"
            CLI_DB="$2"
            shift 2
            ;;
        --target)
            require_value "$1" "${2:-}"
            CLI_TARGET="$2"
            shift 2
            ;;
        --db-list)
            require_value "$1" "${2:-}"
            CLI_DB_LIST="$2"
            shift 2
            ;;
        --partitions)
            require_value "$1" "${2:-}"
            CLI_PARTITIONS="$2"
            shift 2
            ;;
	--version|-V)
            echo "db_repartition.sh version ${VERSION}"
            exit 0
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "  --mode {1|2|3}         Operation mode (same as the interactive menu)"
            echo "  --db NAME              Source database (mode 1)"
            echo "  --target NAME          Target database name (mode 1)"
            echo "  --db-list a,b,c        Comma-separated database list (modes 2/3)"
            echo "  --partitions N         Target partition count"
	    echo "  --version, -V          Print script version and exit"
            echo "  --yes                  Auto-confirm every destructive prompt"
            echo "  --help, -h             Show this message"
            exit 0
            ;;
        *)
            error_exit "Unknown option: '$1'. Run with --help for usage."
            ;;
    esac
done

# ── Validate CLI values (only those actually provided) ────────────────────────
if [[ -n "${CLI_MODE}" ]]; then
    [[ ! "${CLI_MODE}" =~ ^[123]$ ]] \
        && error_exit "--mode must be 1, 2, or 3 (got '${CLI_MODE}')."
fi

if [[ -n "${CLI_PARTITIONS}" ]]; then
    [[ ! "${CLI_PARTITIONS}" =~ ^[1-9][0-9]*$ ]] \
        && error_exit "--partitions must be a positive integer (got '${CLI_PARTITIONS}')."
    [[ "${CLI_PARTITIONS}" -gt 104 ]] \
        && error_exit "--partitions too high (max allowed: 104, got '${CLI_PARTITIONS}')."
fi

if [[ -n "${CLI_DB}" && -n "${CLI_DB_LIST}" ]]; then
    error_exit "--db and --db-list are mutually exclusive. Use --db for mode 1, --db-list for modes 2/3."
fi

# ── Asks a yes/no question; exits on anything other than 'y' ─────────────────
# Default answer is 'N' — the user must explicitly type 'y' to continue.
confirm_or_exit() {
    local prompt="$1"
    local answer
	 if [[ "${AUTO_YES}" == true ]]; then
        log "${YELLOW}AUTO-CONFIRM (--yes):${NC} ${prompt}"
        return 0
    fi
    echo
    read -rp "  ${YELLOW}${prompt}${NC} ${BOLD1}(y/N): " answer
    answer="${answer:-N}"
    echo
    if [[ "${answer,,}" != "y" ]]; then
        log "Operation cancelled by user."
        exit 0
    fi
}

# ── Run SQL via memsql, return result with no headers ─────────────────────────
sql() {
    memsql -h"${SS_HOST}" -P"${SS_PORT}" -u"${SS_USER}" -p"${SS_PASSWORD}" \
        --batch --skip-column-names -e "$1" 2>>"${LOG_FILE}"
}

# ── Run SQL against a specific database via memsql ───────────────────────────
sql_db() {
    local db="$1"; shift
    memsql -h"${SS_HOST}" -P"${SS_PORT}" -u"${SS_USER}" -p"${SS_PASSWORD}" \
        --batch --skip-column-names "${db}" -e "$1" 2>>"${LOG_FILE}"
}

# ── Take a mysqldump — full (schema + data) or schema-only ───────────────────
# Both modes include routines and triggers.
# Pipelines are not captured by mysqldump and are handled separately below.
take_dump() {
    local db="$1" mode="$2" dump_file="$3"
    local extra_opts=()
    [[ "${mode}" == "schema" ]] && extra_opts+=(--no-data)

    log "Running mysqldump (mode=${mode}): '${db}' → ${dump_file}"
    mysqldump \
        -h"${SS_HOST}" -P"${SS_PORT}" \
        -u"${SS_USER}" -p"${SS_PASSWORD}" \
        --routines \
        --triggers \
        "${extra_opts[@]}" \
        "${db}" > "${dump_file}" 2>>"${LOG_FILE}" \
        || error_exit "mysqldump failed (mode=${mode}, db=${db}). Aborting — source database is intact."

    log "Dump complete: ${dump_file} ($(du -sh "${dump_file}" | cut -f1))."
}

# ── Restore a dump file into a target database via memsql ────────────────────
restore_dump() {
    local target_db="$1" dump_file="$2"
    log "Restoring '${dump_file}' → '${target_db}'..."
    memsql -h"${SS_HOST}" -P"${SS_PORT}" -u"${SS_USER}" -p"${SS_PASSWORD}" \
        "${target_db}" < "${dump_file}" 2>>"${LOG_FILE}" \
        || error_exit "Restore to '${target_db}' failed. Dump preserved at ${dump_file}."
    log "Restore complete."
}

# ── Dump pipeline DDL (not captured by mysqldump) ─────────────────────────────
# Fetches each pipeline's CREATE statement via SHOW CREATE PIPELINE and writes
# them to a separate .sql file for restore after the database is recreated.
dump_pipelines() {
    local src_db="$1" pipeline_file="$2"
    log "Dumping pipeline DDL: '${src_db}' → ${pipeline_file}"
    > "${pipeline_file}"

    local pipelines
    pipelines=$(sql "SELECT PIPELINE_NAME FROM information_schema.PIPELINES
                     WHERE DATABASE_NAME='${src_db}';" 2>/dev/null || true)

    local count=0
    while IFS= read -r pipeline; do
        [[ -z "${pipeline}" ]] && continue
        echo "-- Pipeline: ${pipeline}" >> "${pipeline_file}"
        sql_db "${src_db}" "SHOW CREATE PIPELINE \`${pipeline}\`;" 2>>"${LOG_FILE}" \
            | awk '{$1=""; sub(/^ /,""); print}' \
			| sed 's/\\n/\n/g' >> "${pipeline_file}"   # strip pipeline name column, write CREATE statement only
        echo ";" >> "${pipeline_file}"
        (( count++ )) || true
    done <<< "${pipelines}"

    log "${count} pipeline(s) dumped."
}

# ── Restore pipeline DDL into a target database via memsql ───────────────────
# Skipped silently if the pipeline file is empty (database had no pipelines).
restore_pipelines() {
    local target_db="$1" pipeline_file="$2"
    if [[ -s "${pipeline_file}" ]]; then
        log "Restoring pipelines → '${target_db}'..."
        memsql -h"${SS_HOST}" -P"${SS_PORT}" -u"${SS_USER}" -p"${SS_PASSWORD}" \
            "${target_db}" < "${pipeline_file}" 2>>"${LOG_FILE}" \
            || log "${YELLOW}WARNING: Some pipeline definitions failed to restore. Review ${pipeline_file}.${NC}"
        log "Pipeline restore complete."
    else
        log "No pipelines to restore."
    fi
}

# ── Stop all pipelines in a database (best-effort, never fatal) ──────────────
# Called before dropping a source DB or before copying its rows, so no new
# data lands mid-migration and counts stay stable.
stop_pipelines() {
    local db="$1"
    local pipelines
    pipelines=$(sql "SELECT PIPELINE_NAME FROM information_schema.PIPELINES
                     WHERE DATABASE_NAME='${db}';" 2>/dev/null || true)
    [[ -z "${pipelines}" ]] && { log "No pipelines to stop in '${db}'."; return 0; }

    while IFS= read -r p; do
        [[ -z "${p}" ]] && continue
        log "  Stopping pipeline: ${db}.${p}"
        sql_db "${db}" "STOP PIPELINE \`${p}\`;" \
            || log "${YELLOW}WARNING: failed to stop pipeline '${p}' in '${db}'.${NC}"
    done <<< "${pipelines}"
}

# ── Start all pipelines in a database (best-effort, never fatal) ─────────────
# Called after the final restore on a live target DB. Landing-zone DBs
# (e.g. _interm) and clone targets stay stopped to avoid double-ingestion.
start_pipelines() {
    local db="$1"
    local pipelines
    pipelines=$(sql "SELECT PIPELINE_NAME FROM information_schema.PIPELINES
                     WHERE DATABASE_NAME='${db}';" 2>/dev/null || true)
    [[ -z "${pipelines}" ]] && { log "No pipelines to start in '${db}'."; return 0; }

    while IFS= read -r p; do
        [[ -z "${p}" ]] && continue
        log "  Starting pipeline: ${db}.${p}"
        sql_db "${db}" "START PIPELINE \`${p}\`;" \
            || log "${YELLOW}WARNING: failed to start pipeline '${p}' in '${db}'.${NC}"
    done <<< "${pipelines}"
}

# ── Copy all tables from src_db → dst_db in parallel (bounded job pool) ──────
# Runs up to PARALLEL_JOBS INSERT SELECT statements concurrently.
# PARALLEL_JOBS=1 is safe and reproduces the previous sequential behaviour.
parallel_copy_tables() {
    local src_db="$1" dst_db="$2" tables="$3"
    local pids=() failed=false tbl

    while IFS= read -r tbl; do
        [[ -z "${tbl}" ]] && continue
        log "  Queuing: ${tbl}"
        (
            sql "INSERT INTO \`${dst_db}\`.\`${tbl}\` SELECT * FROM \`${src_db}\`.\`${tbl}\`;" \
                || { log "${RED}ERROR: Copy failed for '${tbl}'${NC}"; exit 1; }
            log "  Done: ${tbl}"
        ) &
        pids+=($!)

        if [[ ${#pids[@]} -ge ${PARALLEL_JOBS} ]]; then
            for pid in "${pids[@]}"; do wait "$pid" || failed=true; done
            pids=()
        fi
    done <<< "${tables}"

    for pid in "${pids[@]}"; do wait "$pid" || failed=true; done
    if [[ "${failed}" == true ]]; then
        error_exit "One or more table copies failed. Target db may be partial — do NOT drop source."
    fi
}

# ── Validate object counts and row counts between source and destination ───────
# Prints a per-object and per-table summary; returns non-zero on any mismatch.
validate_migration() {
    local src_db="$1" dst_db="$2"
    banner "Validation: ${src_db} → ${dst_db}"

    # Collect object counts from both databases
    local s_tables d_tables s_views d_views s_rout d_rout s_pipe d_pipe
    s_tables=$(sql "SELECT COUNT(*) FROM information_schema.TABLES    WHERE TABLE_SCHEMA='${src_db}'   AND TABLE_TYPE='BASE TABLE';")
    d_tables=$(sql "SELECT COUNT(*) FROM information_schema.TABLES    WHERE TABLE_SCHEMA='${dst_db}'   AND TABLE_TYPE='BASE TABLE';")
    s_views=$( sql "SELECT COUNT(*) FROM information_schema.VIEWS     WHERE TABLE_SCHEMA='${src_db}';")
    d_views=$( sql "SELECT COUNT(*) FROM information_schema.VIEWS     WHERE TABLE_SCHEMA='${dst_db}';")
    s_rout=$(  sql "SELECT COUNT(*) FROM information_schema.ROUTINES  WHERE ROUTINE_SCHEMA='${src_db}';")
    d_rout=$(  sql "SELECT COUNT(*) FROM information_schema.ROUTINES  WHERE ROUTINE_SCHEMA='${dst_db}';")
    s_pipe=$(  sql "SELECT COUNT(*) FROM information_schema.PIPELINES WHERE DATABASE_NAME='${src_db}';" 2>/dev/null || echo "0")
    d_pipe=$(  sql "SELECT COUNT(*) FROM information_schema.PIPELINES WHERE DATABASE_NAME='${dst_db}';" 2>/dev/null || echo "0")

    # Print object-level summary
    printf "\n  %-12s %10s %10s %s\n" "Object"   "Before" "After" "Status"
    printf "  %-12s %10s %10s\n"      "--------" "------" "-----"

    _cmp() {
        local label="$1" s="$2" d="$3"
        local status="${GREEN}OK${NC}"
        [[ "$s" != "$d" ]] && status="${RED}MISMATCH${NC}"
        printf "  %-12s %10s %10s " "${label}" "${s}" "${d}"
        echo -e "${status}"
    }
    _cmp "Tables"    "${s_tables}" "${d_tables}"
    _cmp "Views"     "${s_views}"  "${d_views}"
    _cmp "Routines"  "${s_rout}"   "${d_rout}"
    _cmp "Pipelines" "${s_pipe}"   "${d_pipe}"

    # Print per-table row count comparison
    printf "\n  %-40s %12s %12s %s\n" "Table" "Src rows" "Dst rows" "Status"
    printf "  %-40s %12s %12s\n"      "-----" "--------" "--------"

    local all_ok=true
    local tables
    tables=$(sql "SELECT TABLE_NAME FROM information_schema.TABLES
                  WHERE TABLE_SCHEMA='${src_db}' AND TABLE_TYPE='BASE TABLE'
                  ORDER BY TABLE_NAME;")

    while IFS= read -r tbl; do
        [[ -z "${tbl}" ]] && continue
        local src_cnt dst_cnt
        src_cnt=$(sql "SELECT COUNT(*) FROM \`${src_db}\`.\`${tbl}\`;")
        dst_cnt=$(sql "SELECT COUNT(*) FROM \`${dst_db}\`.\`${tbl}\`;")
        local status="${GREEN}OK${NC}"
        if [[ "${src_cnt}" != "${dst_cnt}" ]]; then
            status="${RED}MISMATCH${NC}"
            all_ok=false
        fi
        printf "  %-40s %12s %12s " "${tbl}" "${src_cnt}" "${dst_cnt}"
        echo -e "${status}"
    done <<< "${tables}"

    echo
    if [[ "${all_ok}" == true ]]; then
        log "${GREEN}Validation PASSED.${NC}"
    else
        log "${RED}Validation FAILED — row count mismatches detected.${NC}"
        return 1
    fi
}

# ── Repartition a single _vew database (full dump → drop → recreate → restore)
# Shared by single-DB mode (Step 6) and multi-DB batch mode.
#   interactive=yes → prompt before each destructive step (single-DB behavior)
#   interactive=no  → run unattended (multi-DB batch, already confirmed up-front)
repartition_vew() {
    local db="$1" parts="$2" interactive="${3:-yes}"
    local full_dump="${DUMP_DIR}/${db}_full_${TIMESTAMP}.sql"
    local pipeline_dump="${DUMP_DIR}/${db}_pipelines_${TIMESTAMP}.sql"

    banner "Repartitioning '${db}' → ${parts} partitions"

    # Full dump (schema + data) and pipeline DDL
    [[ "${interactive}" == "yes" ]] && confirm_or_exit "Take full mysqldump of '${db}'?"
    take_dump "${db}" "full" "${full_dump}"
    dump_pipelines "${db}" "${pipeline_dump}"

    # Stop pipelines, then drop
    log "Stopping pipelines on '${db}' before drop..."
    stop_pipelines "${db}"

    [[ "${interactive}" == "yes" ]] && confirm_or_exit "DROP DATABASE '${db}'? (dump is preserved at ${full_dump})"
    log "Dropping '${db}'..."
    sql "DROP DATABASE \`${db}\`;" \
        || error_exit "Drop failed for '${db}'. Dump preserved at ${full_dump}."
    log "Database '${db}' dropped."

    # Recreate with new partition count
    [[ "${interactive}" == "yes" ]] && confirm_or_exit "CREATE DATABASE '${db}' PARTITIONS = ${parts}?"
    log "Creating '${db}' PARTITIONS = ${parts}..."
    sql "CREATE DATABASE \`${db}\` PARTITIONS = ${parts};" \
        || error_exit "Create failed for '${db}'. Dump preserved at ${full_dump}."
    log "Database '${db}' created."

    # Restore + start pipelines
    [[ "${interactive}" == "yes" ]] && confirm_or_exit "Restore dump into '${db}'?"
    restore_dump      "${db}" "${full_dump}"
    restore_pipelines "${db}" "${pipeline_dump}"
    log "Starting pipelines on '${db}'..."
    start_pipelines   "${db}"

    log "${GREEN}'${db}' rebuilt with ${parts} partitions.${NC}"
}

# =============================================================================
# STEP 1 — Prompt for the source database name and verify it exists
# =============================================================================
banner "SingleStore Database Repartitioning Script v${VERSION}"

# Prompt for password only if not already set in the environment
if [[ -z "${SS_PASSWORD:-}" ]]; then
    read -rsp "SingleStore password for '${SS_USER}@${SS_HOST}': " SS_PASSWORD
    echo
fi

# Fail early if the credentials or host are wrong
memsql -h"${SS_HOST}" -P"${SS_PORT}" -u"${SS_USER}" -p"${SS_PASSWORD}" \
    -e "SELECT 1;" &>/dev/null \
    || error_exit "Cannot connect to SingleStore at ${SS_HOST}:${SS_PORT}."

# =============================================================================
# OPERATION MODE — single database, multi-DB _vew batch, or multi-DB non-_vew batch
# =============================================================================
if [[ -n "${CLI_MODE}" ]]; then
    OP_MODE="${CLI_MODE}"
    log "Operation mode ${OP_MODE} supplied via --mode (skipping prompt)."
else
    banner "Operation Mode"
    echo "  1) Single database (any type: _vew, _tbl, plain)"
    echo "  2) Multiple databases (_vew only — same partition count for all)"
    echo "  3) Multiple databases (non-_vew — same partition count for all)"
    echo
    read -rp "Choice [1/2/3]: " OP_MODE
fi

[[ "${OP_MODE}" != "1" && "${OP_MODE}" != "2" && "${OP_MODE}" != "3" ]] \
    && error_exit "Invalid choice — enter 1, 2, or 3."

# =============================================================================
# MULTI-DB MODE — batch repartition of _vew databases, one shared partition count
# =============================================================================
if [[ "${OP_MODE}" == "2" ]]; then
    banner "Multi-DB Mode — _vew databases only"

    if [[ -n "${CLI_DB_LIST}" ]]; then
        DB_LIST_RAW="${CLI_DB_LIST}"
        log "Database list supplied via --db-list (skipping prompt)."
    else
        read -rp "Enter database names (space- or comma-separated): " DB_LIST_RAW
    fi
    [[ -z "${DB_LIST_RAW}" ]] && error_exit "Database list cannot be empty."

    # Split on commas and whitespace
    IFS=$', \t' read -ra DB_ARRAY <<< "${DB_LIST_RAW}"

    # Drop any empty entries (e.g. from doubled separators)
    BATCH_DBS=()
    for db in "${DB_ARRAY[@]}"; do
        [[ -n "${db}" ]] && BATCH_DBS+=("${db}")
    done
    [[ ${#BATCH_DBS[@]} -eq 0 ]] && error_exit "No valid database names provided."

    # Validate: each DB must end in _vew and must exist
    log "Validating ${#BATCH_DBS[@]} database name(s)..."
    for db in "${BATCH_DBS[@]}"; do
        [[ "${db}" != *_vew ]] && error_exit "'${db}' does not end in '_vew'. Multi-DB mode requires _vew databases only."
        exists=$(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db}';")
        [[ "${exists}" -eq 0 ]] && error_exit "Database '${db}' does not exist."
    done

    # Per-DB summary so the operator can sanity-check the batch
    banner "Databases to repartition"
    printf "  %-40s %12s %12s %8s %10s %8s\n" "Database" "Size (GB)" "Partitions" "Tables" "Pipelines" "Running"
    printf "  %-40s %12s %12s %8s %10s %8s\n" "--------" "---------" "----------" "------" "---------" "-------"
    for db in "${BATCH_DBS[@]}"; do
        b_size=$(sql "SELECT COALESCE(trunc(sum(compressed_size)/1024/1024/1024,2),0) FROM information_schema.columnar_segments WHERE database_name='${db}' GROUP BY database_name;" 2>/dev/null)
        b_size="${b_size:-0}"
        b_parts=$(sql "SELECT COALESCE(num_partitions, 'default') FROM information_schema.distributed_databases WHERE database_name='${db}';")
        b_tables=$(sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db}' AND TABLE_TYPE='BASE TABLE';")
        b_pipes=$(sql "SELECT COUNT(*) FROM information_schema.PIPELINES WHERE DATABASE_NAME='${db}';" 2>/dev/null || echo "0")
        b_run=$(sql "SELECT COUNT(*) FROM information_schema.MV_PROCESSLIST WHERE DB='${db}' AND COMMAND != 'Sleep';")
        if [[ "${b_tables}" -gt 0 ]]; then
            printf "  %-40s %12s %12s %8s %10s %8s ${YELLOW}(has tables)${NC}\n" "${db}" "${b_size}" "${b_parts}" "${b_tables}" "${b_pipes}" "${b_run}"
        else
            printf "  %-40s %12s %12s %8s %10s %8s\n" "${db}" "${b_size}" "${b_parts}" "${b_tables}" "${b_pipes}" "${b_run}"
        fi
    done
    echo

    # Partition count (applied to all DBs in the batch)
        if [[ -n "${CLI_PARTITIONS}" ]]; then
        REQ_PARTITIONS="${CLI_PARTITIONS}"
        log "Partition count ${REQ_PARTITIONS} supplied via --partitions (skipping prompt)."
    else
        read -rp "Required number of partitions (applied to all): " REQ_PARTITIONS
    fi
    [[ -z "${REQ_PARTITIONS}" ]]                 && error_exit "Partition count cannot be empty."
    [[ ! "${REQ_PARTITIONS}" =~ ^[1-9][0-9]*$ ]] && error_exit "Partition count must be a positive integer."
    [[ "${REQ_PARTITIONS}" -gt 104 ]]            && error_exit "Partition count too high (max allowed: 104)."

    mkdir -p "${DUMP_DIR}"

    # Single confirmation for the whole batch — no per-step prompts after this
    echo
    echo -e "${BOLD}About to repartition ${#BATCH_DBS[@]} _vew database(s) to ${REQ_PARTITIONS} partitions each.${NC}"
    echo -e "${BOLD}Each DB: full-dumped → dropped → recreated → restored. No further prompts.${NC}"
    echo -e "${BOLD}On any failure the script aborts immediately; the failing DB's dump is preserved.${NC}"
    confirm_or_exit "Proceed with batch repartitioning of ${#BATCH_DBS[@]} database(s)?"

    # Execute serially — running multiple _vew rebuilds in parallel would compete
    # for the same memsql connections and disk IO, and would muddy recovery.
    for db in "${BATCH_DBS[@]}"; do
        repartition_vew "${db}" "${REQ_PARTITIONS}" "no"
    done

    banner "Batch Complete"
    log "${GREEN}${#BATCH_DBS[@]} database(s) repartitioned to ${REQ_PARTITIONS} partitions:${NC}"
    for db in "${BATCH_DBS[@]}"; do
        log "  - ${db}  (dump: ${DUMP_DIR}/${db}_full_${TIMESTAMP}.sql)"
    done
    log "Log: ${LOG_FILE}"
    echo -e "${GREEN}${BOLD}All done.${NC}\n"
    exit 0
fi

# =============================================================================
# MODE 3 — Multi-DB batch repartition of non-_vew databases via intermediate DB
# [CHANGE: 2026-06-10] New mode added. Mirrors the single-DB intermediate path
# (steps 7a–7j) but runs serially across a list of databases. Key behaviours:
#   - All pre-flight checks run upfront before any database is touched
#   - _interm is NOT dropped automatically — left for manual cleanup
#   - DROP source (7e) prompts once per database with position indicator [N/total]
#   - On any failure the script aborts; remaining databases are untouched
# =============================================================================
if [[ "${OP_MODE}" == "3" ]]; then
    banner "Multi-DB Mode — non-_vew databases (intermediate path)"

    if [[ -n "${CLI_DB_LIST}" ]]; then
        DB_LIST_RAW="${CLI_DB_LIST}"
        log "Database list supplied via --db-list (skipping prompt)."
    else
        read -rp "Enter database names (space- or comma-separated): " DB_LIST_RAW
    fi
    [[ -z "${DB_LIST_RAW}" ]] && error_exit "Database list cannot be empty."

    # Split on commas and whitespace; drop empty entries from doubled separators
    IFS=$', \t' read -ra DB_ARRAY <<< "${DB_LIST_RAW}"
    BATCH_DBS=()
    for db in "${DB_ARRAY[@]}"; do
        [[ -n "${db}" ]] && BATCH_DBS+=("${db}")
    done
    [[ ${#BATCH_DBS[@]} -eq 0 ]] && error_exit "No valid database names provided."

    # ── Pre-flight validation — all checks run upfront, nothing touched yet ──
    # Collect all errors before aborting so the operator can fix everything
    # in one pass rather than discovering problems one at a time.
    log "Pre-flight validation for ${#BATCH_DBS[@]} database(s)..."
    PREFLIGHT_ERRORS=()

    for db in "${BATCH_DBS[@]}"; do
        # Must not end in _vew — those belong to Mode 2
        if [[ "${db}" == *_vew ]]; then
            PREFLIGHT_ERRORS+=("'${db}' ends in '_vew' — use Mode 2 for _vew databases.")
            continue
        fi

        # Must not end in _tbl — those are clone targets, not sources
        if [[ "${db}" == *_tbl ]]; then
            PREFLIGHT_ERRORS+=("'${db}' ends in '_tbl' — clone targets cannot be repartitioned via this mode.")
            continue
        fi

        # Must not end in _interm — those are intermediate databases
        if [[ "${db}" == *_interm ]]; then
            PREFLIGHT_ERRORS+=("'${db}' ends in '_interm' — intermediate databases cannot be repartitioned.")
            continue
        fi

        # Must exist
        exists=$(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db}';")
        if [[ "${exists}" -eq 0 ]]; then
            PREFLIGHT_ERRORS+=("'${db}' does not exist.")
            continue
        fi

        # _interm orphan check — a leftover from a previous run would abort mid-batch
        interm_check=$(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db}_interm';")
        if [[ "${interm_check}" -gt 0 ]]; then
            PREFLIGHT_ERRORS+=("'${db}_interm' already exists — drop it manually before re-running.")
        fi
    done

    # Abort with full error list if any pre-flight check failed
    if [[ ${#PREFLIGHT_ERRORS[@]} -gt 0 ]]; then
        log "${RED}Pre-flight validation FAILED — fix the following before re-running:${NC}"
        for err in "${PREFLIGHT_ERRORS[@]}"; do
            log "  ${RED}✖${NC} ${err}"
        done
        exit 1
    fi
    log "${GREEN}Pre-flight validation passed — all ${#BATCH_DBS[@]} database(s) OK.${NC}"

    # ── Pre-flight summary table ───────────────────────────────────────────────
    banner "Databases to repartition"
    printf "  %-40s %12s %12s %8s %10s %8s\n" "Database" "Size (GB)" "Partitions" "Tables" "Pipelines" "Running"
    printf "  %-40s %12s %12s %8s %10s %8s\n" "--------" "---------" "----------" "------" "---------" "-------"
    for db in "${BATCH_DBS[@]}"; do
        b_size=$(sql "SELECT COALESCE(trunc(sum(compressed_size)/1024/1024/1024,2),0) FROM information_schema.columnar_segments WHERE database_name='${db}' GROUP BY database_name;" 2>/dev/null || echo "0")
        b_size="${b_size:-0}"
        b_parts=$(sql "SELECT COALESCE(num_partitions, 'default') FROM information_schema.distributed_databases WHERE database_name='${db}';")
        b_tables=$(sql "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db}' AND TABLE_TYPE='BASE TABLE';")
        b_pipes=$(sql "SELECT COUNT(*) FROM information_schema.PIPELINES WHERE DATABASE_NAME='${db}';" 2>/dev/null || echo "0")
        b_run=$(sql "SELECT COUNT(*) FROM information_schema.MV_PROCESSLIST WHERE DB='${db}' AND COMMAND != 'Sleep';")
        printf "  %-40s %12s %12s %8s %10s %8s\n" "${db}" "${b_size}" "${b_parts}" "${b_tables}" "${b_pipes}" "${b_run}"
    done
    echo

    # ── Partition count (one value applied to all databases in batch) ─────────
        if [[ -n "${CLI_PARTITIONS}" ]]; then
        REQ_PARTITIONS="${CLI_PARTITIONS}"
        log "Partition count ${REQ_PARTITIONS} supplied via --partitions (skipping prompt)."
    else
        read -rp "Required number of partitions (applied to all): " REQ_PARTITIONS
    fi
    [[ -z "${REQ_PARTITIONS}" ]]                 && error_exit "Partition count cannot be empty."
    [[ ! "${REQ_PARTITIONS}" =~ ^[1-9][0-9]*$ ]] && error_exit "Partition count must be a positive integer."
    [[ "${REQ_PARTITIONS}" -gt 104 ]]            && error_exit "Partition count too high (max allowed: 104)."

    mkdir -p "${DUMP_DIR}"

    # ── Single upfront confirmation before any work begins ────────────────────
    echo
    echo -e "${BOLD}About to repartition ${#BATCH_DBS[@]} non-_vew database(s) to ${REQ_PARTITIONS} partitions each.${NC}"
    echo -e "${BOLD}Each DB: _interm created → schema dumped → schema restored → data copied → validated → source DROPPED → rebuilt → data copied back → validated.${NC}"
    echo -e "${BOLD}_interm databases will NOT be dropped automatically — manual cleanup required after each run.${NC}"
    echo -e "${BOLD}On any failure the script aborts immediately; the failing DB's _interm is preserved.${NC}"
    echo -e "${YELLOW}You will be prompted once per database before the irreversible DROP of the source.${NC}"
    confirm_or_exit "Proceed with batch repartitioning of ${#BATCH_DBS[@]} database(s)?"

    # ── Serial execution — one database fully completes before the next begins ─
    # Running in parallel would compete for leaf CPU, memory, and inter-node
    # bandwidth, and would make recovery after a failure far harder to reason about.
    TOTAL=${#BATCH_DBS[@]}
    BATCH_IDX=0
    INTERM_CLEANUP=()   # accumulate _interm names for the final cleanup reminder

    for db in "${BATCH_DBS[@]}"; do
        (( BATCH_IDX++ )) || true
        INTERM_DB="${db}_interm"
        SCHEMA_DUMP="${DUMP_DIR}/${db}_schema_${TIMESTAMP}.sql"
        PIPELINE_DUMP="${DUMP_DIR}/${db}_pipelines_${TIMESTAMP}.sql"

        banner "[${BATCH_IDX}/${TOTAL}] Repartitioning '${db}' → ${REQ_PARTITIONS} partitions"

        # ── 7a Create intermediate database ──────────────────────────────────
        # AUTO — non-destructive; _interm can be dropped and run restarted.
        log "AUTO: Creating intermediate database '${INTERM_DB}' PARTITIONS = ${REQ_PARTITIONS} (no confirmation required for this step)..."
        sql "CREATE DATABASE \`${INTERM_DB}\` PARTITIONS = ${REQ_PARTITIONS};" \
            || error_exit "[${BATCH_IDX}/${TOTAL}] Failed to create '${INTERM_DB}'. Aborting batch."
        log "Intermediate database '${INTERM_DB}' created."

        # ── 7b Schema-only dump from source ──────────────────────────────────
        # AUTO — read-only against source; no destructive effect.
        log "AUTO: Taking schema-only mysqldump of '${db}' (no confirmation required for this step)..."
        take_dump "${db}" "schema" "${SCHEMA_DUMP}"
        dump_pipelines "${db}" "${PIPELINE_DUMP}"

        # ── 7c Restore schema into _interm ────────────────────────────────────
        # AUTO — source untouched; _interm can be dropped and rebuilt if needed.
        # Pipelines restored into _interm stay STOPPED — landing zone only.
        log "AUTO: Restoring schema into '${INTERM_DB}' (no confirmation required for this step)..."
        restore_dump      "${INTERM_DB}" "${SCHEMA_DUMP}"
        restore_pipelines "${INTERM_DB}" "${PIPELINE_DUMP}"

        # ── 7d Stop source pipelines, then bulk-copy source → _interm ─────────
        # Pipelines must be stopped BEFORE the copy so no rows land after the
        # SELECT * runs and are silently missed by _interm.
        log "Stopping pipelines on '${db}' to freeze row counts before copy..."
        stop_pipelines "${db}"

        TABLES=$(sql "SELECT TABLE_NAME FROM information_schema.TABLES
                      WHERE TABLE_SCHEMA='${db}' AND TABLE_TYPE='BASE TABLE'
                      ORDER BY TABLE_NAME;")

        # AUTO — source fully intact; _interm can be dropped and recopied.
        log "AUTO: Copying all table data from '${db}' → '${INTERM_DB}' (PARALLEL_JOBS=${PARALLEL_JOBS}) (no confirmation required for this step)..."
        log "Copying data '${db}' → '${INTERM_DB}' (parallel=${PARALLEL_JOBS})..."
        parallel_copy_tables "${db}" "${INTERM_DB}" "${TABLES}"
        log "Data copy to '${INTERM_DB}' complete."

        # ── 7d.1 Validate source → _interm ────────────────────────────────────
        # Runs BEFORE the DROP so source is still fully intact if this fails.
        validate_migration "${db}" "${INTERM_DB}" \
            || error_exit "[${BATCH_IDX}/${TOTAL}] Validation FAILED — source '${db}' is still intact and has NOT been dropped. Investigate '${INTERM_DB}' before proceeding. Source pipelines remain STOPPED and must be restarted manually. Remaining databases in batch untouched."

        # ── 7e DROP source — the one manual gate per database ─────────────────
        # Prompt includes batch position so operator knows where they are.
        confirm_or_exit "[${BATCH_IDX}/${TOTAL}] DROP DATABASE '${db}'? (data is preserved in '${INTERM_DB}')"
        log "Dropping '${db}'..."
        sql "DROP DATABASE \`${db}\`;" \
            || error_exit "[${BATCH_IDX}/${TOTAL}] Drop failed. Data preserved in '${INTERM_DB}'. Aborting batch."
        log "Database '${db}' dropped."

        # ── 7f Recreate main database with new partition count ────────────────
        # AUTO — operator already confirmed DROP at 7e; _interm is the safety net.
        log "AUTO: Creating '${db}' PARTITIONS = ${REQ_PARTITIONS} (no confirmation required for this step)..."
        log "Creating '${db}' PARTITIONS = ${REQ_PARTITIONS}..."
        sql "CREATE DATABASE \`${db}\` PARTITIONS = ${REQ_PARTITIONS};" \
            || error_exit "[${BATCH_IDX}/${TOTAL}] Create failed. Data preserved in '${INTERM_DB}'. Aborting batch."
        log "Database '${db}' created."

        # ── 7f.1 Restore schema into new main ─────────────────────────────────
        # AUTO — _interm untouched and remains the safety net.
        # Pipelines restored but NOT started yet — start only after 7h passes.
        log "AUTO: Restoring schema into '${db}' (no confirmation required for this step)..."
        restore_dump      "${db}" "${SCHEMA_DUMP}"
        restore_pipelines "${db}" "${PIPELINE_DUMP}"

        # ── 7g Bulk-copy _interm → new main ───────────────────────────────────
        # AUTO — _interm intact throughout; 7h validation catches any failures
        # before _interm would ever be dropped (which it isn't in batch mode anyway).
        log "AUTO: Copying all table data from '${INTERM_DB}' → '${db}' (PARALLEL_JOBS=${PARALLEL_JOBS}) (no confirmation required for this step)..."
        log "Copying data '${INTERM_DB}' → '${db}' (parallel=${PARALLEL_JOBS})..."
        parallel_copy_tables "${INTERM_DB}" "${db}" "${TABLES}"
        log "Data copy to '${db}' complete."

        # ── 7h Validate _interm → new main ────────────────────────────────────
        # Fatal if counts don't match — _interm is the only complete copy of data.
        validate_migration "${INTERM_DB}" "${db}" \
            || error_exit "[${BATCH_IDX}/${TOTAL}] Validation FAILED. '${INTERM_DB}' preserved as the only complete copy of source data. Investigate before dropping it manually. Aborting batch — remaining databases untouched."

        # ── 7i Start pipelines on rebuilt main ────────────────────────────────
        log "Starting pipelines on '${db}'..."
        start_pipelines "${db}"

        # ── 7j _interm intentionally NOT dropped ──────────────────────────────
        # [CHANGE: 2026-06-10] In batch mode _interm is never auto-dropped.
        # The operator must drop it manually after verifying the rebuilt DB.
        # All _interm names are collected and printed in the batch summary below.
        INTERM_CLEANUP+=("${INTERM_DB}")
        log "${YELLOW}NOTE: '${INTERM_DB}' has been left alive — drop it manually when ready.${NC}"

        log "${GREEN}[${BATCH_IDX}/${TOTAL}] '${db}' rebuilt with ${REQ_PARTITIONS} partitions.${NC}"
    done

    # ── Batch complete summary ─────────────────────────────────────────────────
    banner "Batch Complete"
    log "${GREEN}${TOTAL} database(s) repartitioned to ${REQ_PARTITIONS} partitions:${NC}"
    for db in "${BATCH_DBS[@]}"; do
        log "  ${GREEN}✔${NC} ${db}  (schema dump: ${DUMP_DIR}/${db}_schema_${TIMESTAMP}.sql)"
    done
    echo
    log "${YELLOW}The following _interm databases were left alive and require manual cleanup:${NC}"
    for interm in "${INTERM_CLEANUP[@]}"; do
        log "  ${YELLOW}→${NC} DROP DATABASE \`${interm}\`;"
    done
    log "Log: ${LOG_FILE}"
    echo -e "${GREEN}${BOLD}All done.${NC}\n"
    exit 0
fi

# =============================================================================
# SINGLE-DB MODE — original flow below (any DB type: _vew / _tbl / plain)
# =============================================================================

banner "Step 1 — Source Database"
if [[ -n "${CLI_DB}" ]]; then
    DB_NAME="${CLI_DB}"
    log "Source database '${DB_NAME}' supplied via --db (skipping prompt)."
else
    read -rp "Enter the database name: " DB_NAME
fi
[[ -z "${DB_NAME}" ]] && error_exit "Database name cannot be empty."

DB_EXISTS=$(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${DB_NAME}';")
[[ "${DB_EXISTS}" -eq 0 ]] && error_exit "Database '${DB_NAME}' does not exist."

# =============================================================================
# STEP 2 — Collect current database metrics for review before any changes
# =============================================================================
banner "Step 2 — Database Validation"

# Partition count is a database-level attribute in SingleStore; read from information_schema
NUM_PARTITIONS=$(sql "
SELECT COALESCE(num_partitions, 'default')
FROM information_schema.distributed_databases
WHERE database_name='${DB_NAME}';
")

DB_SIZE=$(sql "
    select trunc(sum(compressed_size)/1024/1024/1024,2) as DB_Size_GB
from information_schema.columnar_segments where database_name='${DB_NAME}'
group by database_name;")

NUM_TABLES=$(sql    "SELECT COUNT(*) FROM information_schema.TABLES    WHERE TABLE_SCHEMA='${DB_NAME}'   AND TABLE_TYPE='BASE TABLE';")
NUM_VIEWS=$(sql     "SELECT COUNT(*) FROM information_schema.VIEWS     WHERE TABLE_SCHEMA='${DB_NAME}';")
NUM_ROUTINES=$(sql  "SELECT COUNT(*) FROM information_schema.ROUTINES  WHERE ROUTINE_SCHEMA='${DB_NAME}';")
NUM_PIPELINES=$(sql "SELECT COUNT(*) FROM information_schema.PIPELINES WHERE DATABASE_NAME='${DB_NAME}';" 2>/dev/null || echo "0")
NUM_RUNNING=$(sql   "SELECT COUNT(*) FROM information_schema.MV_PROCESSLIST WHERE DB='${DB_NAME}' AND COMMAND != 'Sleep';")

printf "\n"
printf "  %-25s %s\n" "Database:"        "${DB_NAME}"
printf "  %-25s %s\n" "Size:"            "${DB_SIZE}"
printf "  %-25s %s\n" "Partitions:"      "${NUM_PARTITIONS}"
printf "  %-25s %s\n" "Tables:"          "${NUM_TABLES}"
printf "  %-25s %s\n" "Views:"           "${NUM_VIEWS}"
printf "  %-25s %s\n" "Routines:"        "${NUM_ROUTINES}"
printf "  %-25s %s\n" "Pipelines:"       "${NUM_PIPELINES}"
printf "  %-25s %s\n" "Running queries:" "${NUM_RUNNING}"
printf "\n"

# Warn the user if active queries are open — they may be interrupted by the migration
[[ "${NUM_RUNNING}" -gt 0 ]] && \
    log "${YELLOW}WARNING: ${NUM_RUNNING} active query/queries running against '${DB_NAME}'.${NC}"

# =============================================================================
# STEP 3 — Confirm intent to proceed with context-appropriate warnings
# =============================================================================
banner "Step 3 — Proceed?"

# Detect the %_vew pattern — these databases are expected to hold only views;
# finding tables inside one is unusual and warrants a stronger warning.
IS_VEW=false
[[ "${DB_NAME}" == *_vew ]] && IS_VEW=true

if [[ "${IS_VEW}" == true && "${NUM_TABLES}" -gt 0 ]]; then
    # _vew database with tables — unexpected, strongly discourage proceeding
    echo -e "${RED}${BOLD}WARNING:${NC} '${DB_NAME}' matches pattern '%_vew' and contains ${NUM_TABLES} table(s)."
    echo -e "${YELLOW}This looks like a view-only database with tables present. Proceeding is NOT recommended.${NC}"
    confirm_or_exit "Proceed anyway?"
elif [[ "${IS_VEW}" == true ]]; then
    # _vew database with no tables — unusual but less risky, still confirm
    confirm_or_exit "Proceed?"
else
    # Standard database — confirm before making any changes
    confirm_or_exit "Proceed?"
fi

# =============================================================================
# STEP 5 — Collect the target partition count and new database name
# =============================================================================
banner "Step 5 — Repartition Parameters"


if [[ -n "${CLI_PARTITIONS}" ]]; then
    REQ_PARTITIONS="${CLI_PARTITIONS}"
    log "Partition count ${REQ_PARTITIONS} supplied via --partitions (skipping prompt)."
else
    read -rp "Required number of partitions: " REQ_PARTITIONS
fi
[[ -z "${REQ_PARTITIONS}" ]]                  && error_exit "Partition count cannot be empty."
[[ ! "${REQ_PARTITIONS}" =~ ^[1-9][0-9]*$ ]] && error_exit "Partition count must be a positive integer."
[[ "${REQ_PARTITIONS}" -gt 104 ]] && error_exit "Partition count too high (max allowed: 104)."

if [[ -n "${CLI_TARGET}" ]]; then
    NEW_DB_NAME="${CLI_TARGET}"
    log "Target database '${NEW_DB_NAME}' supplied via --target (skipping prompt)."
else
    read -rp "Required database name: " NEW_DB_NAME
fi
[[ -z "${NEW_DB_NAME}" ]] && error_exit "New database name cannot be empty."

# Create dump directory and define output file paths for this run
mkdir -p "${DUMP_DIR}"
SCHEMA_DUMP="${DUMP_DIR}/${DB_NAME}_schema_${TIMESTAMP}.sql"
FULL_DUMP="${DUMP_DIR}/${DB_NAME}_full_${TIMESTAMP}.sql"
PIPELINE_DUMP="${DUMP_DIR}/${DB_NAME}_pipelines_${TIMESTAMP}.sql"

# =============================================================================
# STEP 6 — _vew path: full dump → drop → recreate with new partitions → restore
# Chosen when the target name matches the source and the source is a _vew database.
# A full dump is safe here because the database is expected to have only views.
# =============================================================================
if [[ "${NEW_DB_NAME}" == "${DB_NAME}" && "${IS_VEW}" == true ]]; then

    # Single-DB _vew path delegates to the shared helper with interactive=yes
    # so all four destructive steps still prompt for confirmation.
    repartition_vew "${DB_NAME}" "${REQ_PARTITIONS}" "yes"

    log "${GREEN}Step 6 complete.${NC}"

# =============================================================================
# STEP 7 — Non-_vew path: direct copy live data to target database.
# no Interm database required.
# Start: New Block added 3-May ==> for direct source to target_tbl.
# =============================================================================
elif [[ "${NEW_DB_NAME}" == "${DB_NAME}_tbl" && "${IS_VEW}" == false ]]; then

    banner "Step 7 — Direct DB Clone to _tbl Target"

    # ── Safety check ─────────────────────────────────────────────
    TARGET_EXISTS=$(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${NEW_DB_NAME}';")
    [[ "${TARGET_EXISTS}" -gt 0 ]] && error_exit "Target database '${NEW_DB_NAME}' already exists."

    # ── Create target database directly ──────────────────────────
    confirm_or_exit "CREATE target database '${NEW_DB_NAME}' PARTITIONS = ${REQ_PARTITIONS}?"
    log "Creating '${NEW_DB_NAME}'..."
    sql "CREATE DATABASE \`${NEW_DB_NAME}\` PARTITIONS = ${REQ_PARTITIONS};" \
        || error_exit "Failed to create target database."
    log "Target database created."

    # ── Dump schema + pipelines from source ──────────────────────
    confirm_or_exit "Take schema dump from '${DB_NAME}'?"
    take_dump "${DB_NAME}" "schema" "${SCHEMA_DUMP}"
    dump_pipelines "${DB_NAME}" "${PIPELINE_DUMP}"

    # ── Restore into target directly ─────────────────────────────
    # Pipelines on target stay STOPPED — source is still authoritative and we
    # must not double-ingest. They start only if/when the operator cuts over.
    confirm_or_exit "Restore schema into '${NEW_DB_NAME}'?"
    restore_dump "${NEW_DB_NAME}" "${SCHEMA_DUMP}"
    restore_pipelines "${NEW_DB_NAME}" "${PIPELINE_DUMP}"

    # ── Stop source pipelines so row counts are stable during the copy ──
    log "Stopping pipelines on '${DB_NAME}' to freeze row counts before copy..."
    stop_pipelines "${DB_NAME}"

    # ── Copy data source → target (parallel) ─────────────────────
    TABLES=$(sql "SELECT TABLE_NAME FROM information_schema.TABLES
                  WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_TYPE='BASE TABLE'
                  ORDER BY TABLE_NAME;")

    confirm_or_exit "Copy all data from '${DB_NAME}' → '${NEW_DB_NAME}'? (PARALLEL_JOBS=${PARALLEL_JOBS})"
    log "Copying data '${DB_NAME}' → '${NEW_DB_NAME}' (parallel=${PARALLEL_JOBS})..."
    parallel_copy_tables "${DB_NAME}" "${NEW_DB_NAME}" "${TABLES}"
    log "Data copy complete."

    # ── Validate migration — failure is fatal and blocks pipeline restart ──
    validate_migration "${DB_NAME}" "${NEW_DB_NAME}" \
        || error_exit "Validation FAILED. Source pipelines remain STOPPED — restart manually only after investigation."

    # ── Restart pipelines on source (target stays stopped) ───────
    log "Restarting pipelines on '${DB_NAME}'..."
    start_pipelines "${DB_NAME}"

    log "${GREEN}Direct _tbl migration completed successfully.${NC}"

# =============================================================================
#End: New Block added 3-May ==> for direct source to target_tbl.
# =============================================================================

# =============================================================================
# STEP 7 — Non-_vew path: copy live data through an intermediate database.
# An intermediate database (_interm) acts as a safe landing zone so the source
# can be dropped and recreated with the new partition count without data loss.
# =============================================================================
elif [[ "${NEW_DB_NAME}" == "${DB_NAME}" && "${IS_VEW}" == false ]]; then

    INTERM_DB="${NEW_DB_NAME}_interm"
    banner "Step 7 — Intermediate DB Migration (not _vew)"

    # Abort if a leftover intermediate database from a previous run exists
    INTERM_EXISTS=$(sql "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${INTERM_DB}';")
    [[ "${INTERM_EXISTS}" -gt 0 ]] \
        && error_exit "'${INTERM_DB}' already exists. Drop it first and re-run."

    # ── 7a Create intermediate database ──────────────────────────────────────
    # [CHANGE: 2026-06-10] Prompt removed — this step is non-destructive.
    # _interm is a scratch landing zone; if anything goes wrong before the
    # DROP of source, the operator drops _interm and reruns. No confirmation
    # required. AUTO log line replaces the prompt for auditability.
    log "AUTO: Creating intermediate database '${INTERM_DB}' PARTITIONS = ${REQ_PARTITIONS} (no confirmation required for this step)..."
    sql "CREATE DATABASE \`${INTERM_DB}\` PARTITIONS = ${REQ_PARTITIONS};" \
        || error_exit "Failed to create intermediate database."
    log "Intermediate database '${INTERM_DB}' created."

    # ── 7b Schema-only dump (no row data, includes routines/triggers) ─────────
    # [CHANGE: 2026-06-10] Prompt removed — taking a schema dump is read-only
    # against the source and has no destructive effect. Runs automatically.
    log "AUTO: Taking schema-only mysqldump of '${DB_NAME}' (no confirmation required for this step)..."
    take_dump "${DB_NAME}" "schema" "${SCHEMA_DUMP}"
    dump_pipelines "${DB_NAME}" "${PIPELINE_DUMP}"

    # ── 7c Restore schema and pipelines into the intermediate database ─────────
    # Pipelines in _interm stay STOPPED — _interm is a landing zone, not a live
    # target. They are started only on the rebuilt main DB after validation.
    # [CHANGE: 2026-06-10] Prompt removed — restoring into _interm is safe;
    # source is untouched and _interm can be dropped and rebuilt if needed.
    log "AUTO: Restoring schema into '${INTERM_DB}' (no confirmation required for this step)..."
    restore_dump      "${INTERM_DB}" "${SCHEMA_DUMP}"
    restore_pipelines "${INTERM_DB}" "${PIPELINE_DUMP}"

    # ── 7d Stop source pipelines, then bulk-copy source → _interm ────────────
    # Pipelines must be stopped BEFORE the copy: any rows they ingest after the
    # SELECT * runs would never make it into _interm and would be silently lost.
    log "Stopping pipelines on '${DB_NAME}' to freeze row counts before copy..."
    stop_pipelines "${DB_NAME}"

    TABLES=$(sql "SELECT TABLE_NAME FROM information_schema.TABLES
                  WHERE TABLE_SCHEMA='${DB_NAME}' AND TABLE_TYPE='BASE TABLE'
                  ORDER BY TABLE_NAME;")

    # [CHANGE: 2026-06-10] Prompt removed — copying rows into _interm does not
    # touch the source; it can be dropped and recopied if anything goes wrong.
    # Source is still fully intact until the DROP at step 7e.
    log "AUTO: Copying all table data from '${DB_NAME}' → '${INTERM_DB}' (PARALLEL_JOBS=${PARALLEL_JOBS}) (no confirmation required for this step)..."
    log "Copying data '${DB_NAME}' → '${INTERM_DB}' (parallel=${PARALLEL_JOBS})..."
    parallel_copy_tables "${DB_NAME}" "${INTERM_DB}" "${TABLES}"
    log "Data copy to '${INTERM_DB}' complete."

    # ── 7d.1 [CHANGE: 2026-06-10] Validate source → _interm copy ─────────────
    # REASON: The original script had an asymmetry — the _interm → target leg
    # was validated, but the source → _interm leg was not. A silent partial copy
    # (disk full, lock contention, network hiccup) would only have been caught
    # AFTER the source was already dropped, leaving _interm as the sole copy of
    # incomplete data. This validation runs BEFORE the DROP at step 7e, so the
    # source is still fully intact and recoverable if any mismatch is found.
    # NOTE: validate_migration() compares table/view/routine/pipeline counts and
    # per-table row counts between the two databases.
    validate_migration "${DB_NAME}" "${INTERM_DB}" \
        || error_exit "Validation FAILED — source '${DB_NAME}' is still intact and has NOT been dropped. Investigate '${INTERM_DB}' before proceeding. Source pipelines remain STOPPED and must be restarted manually."
    # ── END CHANGE: 2026-06-10 ────────────────────────────────────────────────

    # ── 7e Drop source database (data is now safely in _interm) ──────────────
    confirm_or_exit "DROP DATABASE '${DB_NAME}'? (data is preserved in '${INTERM_DB}')"
    log "Dropping '${DB_NAME}'..."
    sql "DROP DATABASE \`${DB_NAME}\`;" \
        || error_exit "Drop failed. Data preserved in '${INTERM_DB}'."
    log "Database '${DB_NAME}' dropped."

    # ── 7f Recreate main database with new partition count ────────────────────
    # [CHANGE: 2026-06-10] Prompt removed — operator already confirmed the DROP
    # at 7e (the point of no return). CREATE is the immediate next recovery step;
    # prompting here adds no safety since _interm holds all data and is intact.
    log "AUTO: Creating '${NEW_DB_NAME}' PARTITIONS = ${REQ_PARTITIONS} (no confirmation required for this step)..."
    log "Creating '${NEW_DB_NAME}' PARTITIONS = ${REQ_PARTITIONS}..."
    sql "CREATE DATABASE \`${NEW_DB_NAME}\` PARTITIONS = ${REQ_PARTITIONS};" \
        || error_exit "Create failed. Data preserved in '${INTERM_DB}'."
    log "Database '${NEW_DB_NAME}' created."

    # ── 7f.1 Restore schema and pipelines into the new main database ──────────
    # Pipelines are restored here but NOT started yet — they will start only
    # after the data copy from _interm completes and validation passes.
    # [CHANGE: 2026-06-10] Prompt removed — restoring schema into the freshly
    # created main DB is safe; _interm is untouched and remains the safety net.
    log "AUTO: Restoring schema into '${NEW_DB_NAME}' (no confirmation required for this step)..."
    restore_dump      "${NEW_DB_NAME}" "${SCHEMA_DUMP}"
    restore_pipelines "${NEW_DB_NAME}" "${PIPELINE_DUMP}"

    # ── 7g Bulk-copy all data: _interm → main (parallel) ─────────────────────
    # [CHANGE: 2026-06-10] Prompt removed — _interm remains fully intact as the
    # safety net throughout this copy. If anything fails, 7h validation catches
    # it and aborts before _interm is dropped at 7j.
    log "AUTO: Copying all table data from '${INTERM_DB}' → '${NEW_DB_NAME}' (PARALLEL_JOBS=${PARALLEL_JOBS}) (no confirmation required for this step)..."
    log "Copying data '${INTERM_DB}' → '${NEW_DB_NAME}' (parallel=${PARALLEL_JOBS})..."
    parallel_copy_tables "${INTERM_DB}" "${NEW_DB_NAME}" "${TABLES}"
    log "Data copy to '${NEW_DB_NAME}' complete."

    # ── 7h Validate — failure here is fatal and blocks the drop in 7j ─────────
    # If counts don't match, '${INTERM_DB}' is the only complete copy of the
    # original data. Abort hard so the operator cannot accidentally confirm the
    # drop on the next prompt and lose the safety net.
    validate_migration "${INTERM_DB}" "${NEW_DB_NAME}" \
        || error_exit "Validation FAILED. '${INTERM_DB}' preserved as the only complete copy of source data. Investigate before dropping it manually."

    # ── 7i Start pipelines on new main now that data + validation are good ────
    log "Starting pipelines on '${NEW_DB_NAME}'..."
    start_pipelines "${NEW_DB_NAME}"

    # ── 7j Drop intermediate — only after validation passes ───────────────────
    confirm_or_exit "DROP intermediate database '${INTERM_DB}'?"
    log "Dropping '${INTERM_DB}'..."
    sql "DROP DATABASE \`${INTERM_DB}\`;" \
        || log "${YELLOW}WARNING: Could not drop '${INTERM_DB}'. Clean up manually.${NC}"
    log "Intermediate database '${INTERM_DB}' dropped."

    log "${GREEN}Step 7 complete. '${NEW_DB_NAME}' rebuilt with ${REQ_PARTITIONS} partitions.${NC}"

else
    # The script only supports in-place repartitioning (same source and target name)
    error_exit " Only '${DB_NAME}' or '${DB_NAME}_tbl are Allowed."
fi

# =============================================================================
# Done — print artifact paths for the operator's reference
# =============================================================================
banner "Complete"
log "Log:          ${LOG_FILE}"
log "Schema dump:  ${SCHEMA_DUMP:-N/A}"
log "Full dump:    ${FULL_DUMP:-N/A}"
log "Pipelines:    ${PIPELINE_DUMP}"
echo -e "${GREEN}${BOLD}All done.${NC}\n"
