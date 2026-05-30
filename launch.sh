#!/bin/bash
################################################################################
# launch.sh - Automated VASP iteration orchestrator (squeue/sacct monitoring)
#
# Centralized usage:
#   - Keep automation scripts in one AutoSlurm folder.
#   - Keep each calculation in a separate work directory.
#   - Store canonical inputs in <workdir>/input.
#   - Write chain logs to <workdir>/logs and mirror to <autoslurm>/logs.
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTINUE_FROM=1
MAX_ITER=20
JOB_PREFIX="VASP-calc"
SUCCESS_STRING=""
MONITOR_INTERVAL=1800
STOPCAR_TIME=77400
LABORT_TIME=82800
WORK_DIR="$(pwd)"
INPUT_DIR=""
LOG_DIR=""
MIRROR_LOG_DIR="${SCRIPT_DIR}/logs"
SUBMIT_SCRIPT="${SCRIPT_DIR}/submit.sh"
NODES_OVERRIDE=""
VASP_EXE_OVERRIDE=""
VALIDATE_ONLY=0
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
STATE_FILE=""
EVENTS_FILE=""
WORKFLOW_STATUS="initializing"
CURRENT_ITER=""
CURRENT_JOB_ID=""
CURRENT_JOB_NAME=""
CURRENT_JOB_STATE=""
CURRENT_JOB_ELAPSED=""
CURRENT_JOB_ELAPSED_SECONDS=""
LAST_FINAL_STATE=""
LAST_FINAL_STATE_SOURCE=""
LAST_EXIT_CODE=""
LAST_FAILURE_REASON=""
LAST_COMPLETED_ITER=""
WORKFLOW_CONVERGED=0

print_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --workdir PATH          Job directory (default: current directory)"
    echo "  --input-dir PATH        Input directory (default: auto-detect input/inputs/INPUT/INPUTS)"
    echo "  --log-dir PATH          Primary chain log directory (default: <workdir>/logs)"
    echo "  --mirror-log-dir PATH   Mirror chain log directory (default: <autoslurm>/logs)"
    echo "  --submit-script PATH    Submit script path (default: <autoslurm>/submit.sh)"
    echo "  --nodes N               Override node count for this run (optional)"
    echo "  --vasp-exe PATH_OR_CMD  Override VASP executable for submit.sh (optional)"
    echo "  --continue-from N       Iteration number to start from (default: 1)"
    echo "  --max-iter N            Last iteration number (default: 20)"
    echo "  --name PREFIX           Job name prefix (default: VASP-calc)"
    echo "  --success-string TEXT   Required success text in OUTCAR (optional)"
    echo "  --monitor-interval SEC  Status poll interval in seconds (default: 1800)"
    echo "  --validate-only         Validate config and exit (no job submission)"
    echo "  -h, --help              Show this help"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workdir)
            WORK_DIR="$2"
            shift 2
            ;;
        --input-dir)
            INPUT_DIR="$2"
            shift 2
            ;;
        --log-dir)
            LOG_DIR="$2"
            shift 2
            ;;
        --mirror-log-dir)
            MIRROR_LOG_DIR="$2"
            shift 2
            ;;
        --submit-script)
            SUBMIT_SCRIPT="$2"
            shift 2
            ;;
        --nodes)
            NODES_OVERRIDE="$2"
            shift 2
            ;;
        --vasp-exe)
            VASP_EXE_OVERRIDE="$2"
            shift 2
            ;;
        --continue-from)
            CONTINUE_FROM="$2"
            shift 2
            ;;
        --max-iter)
            MAX_ITER="$2"
            shift 2
            ;;
        --name)
            JOB_PREFIX="$2"
            shift 2
            ;;
        --success-string)
            SUCCESS_STRING="$2"
            shift 2
            ;;
        --monitor-interval)
            MONITOR_INTERVAL="$2"
            shift 2
            ;;
        --validate-only)
            VALIDATE_ONLY=1
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

if ! [[ "$CONTINUE_FROM" =~ ^[0-9]+$ ]] || [[ "$CONTINUE_FROM" -lt 1 ]]; then
    echo "Error: --continue-from must be an integer >= 1"
    exit 1
fi

if ! [[ "$MAX_ITER" =~ ^[0-9]+$ ]] || [[ "$MAX_ITER" -lt "$CONTINUE_FROM" ]]; then
    echo "Error: --max-iter must be an integer >= --continue-from"
    exit 1
fi

if [[ -n "$NODES_OVERRIDE" ]] && { ! [[ "$NODES_OVERRIDE" =~ ^[0-9]+$ ]] || [[ "$NODES_OVERRIDE" -lt 1 ]]; }; then
    echo "Error: --nodes must be an integer >= 1"
    exit 1
fi

if ! [[ "$MONITOR_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$MONITOR_INTERVAL" -lt 60 ]]; then
    echo "Error: --monitor-interval must be an integer >= 60"
    exit 1
fi

if [[ ! -d "$WORK_DIR" ]]; then
    echo "Error: --workdir does not exist: $WORK_DIR"
    exit 1
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
STATE_FILE="${WORK_DIR}/autoslurm-state.json"
EVENTS_FILE="${WORK_DIR}/autoslurm-events.jsonl"

if [[ -z "$INPUT_DIR" ]]; then
    for candidate in input inputs INPUT INPUTS; do
        if [[ -d "$WORK_DIR/$candidate" ]]; then
            INPUT_DIR="$WORK_DIR/$candidate"
            break
        fi
    done
    if [[ -z "$INPUT_DIR" ]]; then
        INPUT_DIR="${WORK_DIR}/input"
    fi
elif [[ "$INPUT_DIR" != /* ]]; then
    INPUT_DIR="${WORK_DIR}/${INPUT_DIR}"
fi

if [[ -z "$LOG_DIR" ]]; then
    LOG_DIR="${WORK_DIR}/logs"
elif [[ "$LOG_DIR" != /* ]]; then
    LOG_DIR="${WORK_DIR}/${LOG_DIR}"
fi

if [[ "$MIRROR_LOG_DIR" != /* ]]; then
    MIRROR_LOG_DIR="${SCRIPT_DIR}/${MIRROR_LOG_DIR}"
fi

if [[ "$SUBMIT_SCRIPT" != /* ]]; then
    SUBMIT_SCRIPT="${SCRIPT_DIR}/${SUBMIT_SCRIPT}"
fi

if [[ ! -d "$INPUT_DIR" ]]; then
    echo "Error: input directory does not exist: $INPUT_DIR"
    exit 1
fi

if [[ ! -f "$SUBMIT_SCRIPT" ]]; then
    echo "Error: submit script not found: $SUBMIT_SCRIPT"
    exit 1
fi

required_files=("INCAR.start" "INCAR.cont" "KPOINTS" "POSCAR" "POTCAR")
for req in "${required_files[@]}"; do
    if [[ ! -f "$INPUT_DIR/$req" ]]; then
        echo "Error: required input file missing: $INPUT_DIR/$req"
        exit 1
    fi
done

WORK_POSCAR="${WORK_DIR}/POSCAR"

if [[ "$VALIDATE_ONLY" -eq 1 ]]; then
    echo "Validation successful."
    echo "  Work dir:         $WORK_DIR"
    echo "  Input dir:        $INPUT_DIR"
    echo "  Log dir:          $LOG_DIR"
    echo "  Mirror log dir:   $MIRROR_LOG_DIR"
    echo "  Submit script:    $SUBMIT_SCRIPT"
    if [[ -n "$NODES_OVERRIDE" ]]; then
        echo "  Nodes:            $NODES_OVERRIDE (override)"
    else
        echo "  Nodes:            submit.sh default"
    fi
    if [[ -n "$VASP_EXE_OVERRIDE" ]]; then
        echo "  VASP exe:         $VASP_EXE_OVERRIDE"
    else
        echo "  VASP exe:         (from submit.sh default/env)"
    fi
    if [[ -f "$WORK_POSCAR" ]]; then
        echo "  Start POSCAR:     $WORK_POSCAR (existing)"
    else
        echo "  Start POSCAR:     $INPUT_DIR/POSCAR (will seed $WORK_POSCAR)"
    fi
    echo "  Iterations:       $CONTINUE_FROM -> $MAX_ITER"
    echo "  Monitor every:    $MONITOR_INTERVAL seconds"
    exit 0
fi

mkdir -p "$LOG_DIR" "$MIRROR_LOG_DIR"

JOB_TAG="$(basename "$WORK_DIR" | tr -cs 'A-Za-z0-9._-' '_')"
CHAIN_BASENAME="chain_${JOB_TAG}_$(date '+%Y%m%d_%H%M%S').log"
CHAIN_LOG="${LOG_DIR}/${CHAIN_BASENAME}"
MIRROR_CHAIN_LOG="${MIRROR_LOG_DIR}/${CHAIN_BASENAME}"

append_log_line() {
    local line="$1"
    echo "$line"
    echo "$line" >> "$CHAIN_LOG"
    if [[ "$MIRROR_CHAIN_LOG" != "$CHAIN_LOG" ]]; then
        echo "$line" >> "$MIRROR_CHAIN_LOG"
    fi
}

log_msg() {
    local msg="$1"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    append_log_line "[$timestamp]  $msg"
}

log_iter() {
    local iter="$1"
    local msg="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    append_log_line "[$timestamp]  [ITER-$iter]  $msg"
}

utc_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

json_quote() {
    local value="${1-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    printf '"%s"' "$value"
}

write_state_snapshot() {
    local last_event="${1:-}"
    local updated_at="${2:-$(utc_timestamp)}"
    local tmp

    if [[ -z "${STATE_FILE:-}" ]]; then
        return 0
    fi

    tmp="${STATE_FILE}.tmp.$$"
    if {
        printf '{\n'
        printf '  "schema_version": 1,\n'
        printf '  "run_id": %s,\n' "$(json_quote "$RUN_ID")"
        printf '  "updated_at": %s,\n' "$(json_quote "$updated_at")"
        printf '  "status": %s,\n' "$(json_quote "$WORKFLOW_STATUS")"
        printf '  "last_event": %s,\n' "$(json_quote "$last_event")"
        printf '  "work_dir": %s,\n' "$(json_quote "$WORK_DIR")"
        printf '  "input_dir": %s,\n' "$(json_quote "$INPUT_DIR")"
        printf '  "log_dir": %s,\n' "$(json_quote "$LOG_DIR")"
        printf '  "mirror_log_dir": %s,\n' "$(json_quote "$MIRROR_LOG_DIR")"
        printf '  "chain_log": %s,\n' "$(json_quote "${CHAIN_LOG:-}")"
        printf '  "mirror_chain_log": %s,\n' "$(json_quote "${MIRROR_CHAIN_LOG:-}")"
        printf '  "submit_script": %s,\n' "$(json_quote "$SUBMIT_SCRIPT")"
        printf '  "continue_from": %s,\n' "$(json_quote "$CONTINUE_FROM")"
        printf '  "max_iter": %s,\n' "$(json_quote "$MAX_ITER")"
        printf '  "job_prefix": %s,\n' "$(json_quote "$JOB_PREFIX")"
        printf '  "current_iteration": %s,\n' "$(json_quote "${CURRENT_ITER:-}")"
        printf '  "current_job_id": %s,\n' "$(json_quote "${CURRENT_JOB_ID:-}")"
        printf '  "current_job_name": %s,\n' "$(json_quote "${CURRENT_JOB_NAME:-}")"
        printf '  "current_job_state": %s,\n' "$(json_quote "${CURRENT_JOB_STATE:-}")"
        printf '  "current_job_elapsed": %s,\n' "$(json_quote "${CURRENT_JOB_ELAPSED:-}")"
        printf '  "current_job_elapsed_seconds": %s,\n' "$(json_quote "${CURRENT_JOB_ELAPSED_SECONDS:-}")"
        printf '  "last_final_state": %s,\n' "$(json_quote "${LAST_FINAL_STATE:-}")"
        printf '  "last_final_state_source": %s,\n' "$(json_quote "${LAST_FINAL_STATE_SOURCE:-}")"
        printf '  "last_exit_code": %s,\n' "$(json_quote "${LAST_EXIT_CODE:-}")"
        printf '  "last_failure_reason": %s,\n' "$(json_quote "${LAST_FAILURE_REASON:-}")"
        printf '  "last_completed_iteration": %s,\n' "$(json_quote "${LAST_COMPLETED_ITER:-}")"
        printf '  "converged": %s,\n' "$(json_quote "$WORKFLOW_CONVERGED")"
        printf '  "state_file": %s,\n' "$(json_quote "${STATE_FILE:-}")"
        printf '  "events_file": %s\n' "$(json_quote "${EVENTS_FILE:-}")"
        printf '}\n'
    } > "$tmp"; then
        mv -f "$tmp" "$STATE_FILE" || rm -f "$tmp"
    else
        rm -f "$tmp"
    fi

    return 0
}

record_event() {
    local event="$1"
    shift
    local timestamp
    local json
    local kv
    local key
    local value

    if [[ -z "${EVENTS_FILE:-}" ]]; then
        return 0
    fi

    timestamp="$(utc_timestamp)"
    json="{\"timestamp\":$(json_quote "$timestamp"),\"event\":$(json_quote "$event"),\"run_id\":$(json_quote "$RUN_ID"),\"status\":$(json_quote "$WORKFLOW_STATUS")"
    for kv in "$@"; do
        key="${kv%%=*}"
        value="${kv#*=}"
        json+=",\"${key}\":$(json_quote "$value")"
    done
    json+="}"

    printf '%s\n' "$json" >> "$EVENTS_FILE" || true
    write_state_snapshot "$event" "$timestamp"
    return 0
}

record_final_state() {
    local iter="$1"
    local job_id="$2"
    local state="$3"
    local source="$4"
    local exit_code="${5:-}"
    local reason="${6:-}"
    local elapsed="${7:-}"
    local raw_state="${8:-}"

    CURRENT_JOB_STATE="$state"
    if [[ -n "$elapsed" ]]; then
        CURRENT_JOB_ELAPSED="$elapsed"
        CURRENT_JOB_ELAPSED_SECONDS="$(elapsed_to_seconds "$elapsed")"
    fi
    LAST_FINAL_STATE="$state"
    LAST_FINAL_STATE_SOURCE="$source"
    LAST_EXIT_CODE="$exit_code"

    record_event "final_state" \
        "iteration=$iter" \
        "job_id=$job_id" \
        "state=$state" \
        "source=$source" \
        "exit_code=$exit_code" \
        "reason=$reason" \
        "elapsed=$elapsed" \
        "raw_state=$raw_state"
}

record_workflow_failure() {
    local reason="$1"
    local launcher_exit_code="${2:-1}"

    WORKFLOW_STATUS="failed"
    LAST_FAILURE_REASON="$reason"
    record_event "workflow_failure" \
        "iteration=${CURRENT_ITER:-}" \
        "job_id=${CURRENT_JOB_ID:-}" \
        "state=${CURRENT_JOB_STATE:-}" \
        "reason=$reason" \
        "launcher_exit_code=$launcher_exit_code"
}

fail_iteration_and_workflow() {
    local iter="$1"
    local reason="$2"
    local state="${3:-${CURRENT_JOB_STATE:-}}"

    WORKFLOW_STATUS="failed"
    LAST_FAILURE_REASON="$reason"
    if [[ -n "$state" ]]; then
        CURRENT_JOB_STATE="$state"
    fi

    record_event "iteration_failure" \
        "iteration=$iter" \
        "job_id=${CURRENT_JOB_ID:-}" \
        "state=${CURRENT_JOB_STATE:-}" \
        "reason=$reason"
    record_event "workflow_failure" \
        "iteration=$iter" \
        "job_id=${CURRENT_JOB_ID:-}" \
        "state=${CURRENT_JOB_STATE:-}" \
        "reason=$reason" \
        "launcher_exit_code=1"
    exit 1
}

log_shutdown_notice() {
    local msg="$1"
    if [[ -n "$CURRENT_ITER" ]]; then
        log_iter "$CURRENT_ITER" "$msg"
    else
        log_msg "$msg"
    fi
}

handle_signal() {
    local signal_name="$1"
    local exit_code="$2"
    trap - HUP INT TERM QUIT PIPE
    log_shutdown_notice "Launcher received ${signal_name}; background monitoring/submission is stopping"
    record_workflow_failure "received ${signal_name}" "$exit_code"
    exit "$exit_code"
}

trap 'handle_signal SIGHUP 129' HUP
trap 'handle_signal SIGINT 130' INT
trap 'handle_signal SIGQUIT 131' QUIT
trap 'handle_signal SIGPIPE 141' PIPE
trap 'handle_signal SIGTERM 143' TERM

# Parse elapsed strings from squeue %M into seconds.
# Supports D-HH:MM:SS, HH:MM:SS, and MM:SS.
elapsed_to_seconds() {
    local elapsed="$1"
    local days=0
    local hours=0
    local mins=0
    local secs=0

    if [[ "$elapsed" =~ ^([0-9]+)-([0-9]{1,2}):([0-9]{2}):([0-9]{2})$ ]]; then
        days="${BASH_REMATCH[1]}"
        hours="${BASH_REMATCH[2]}"
        mins="${BASH_REMATCH[3]}"
        secs="${BASH_REMATCH[4]}"
    elif [[ "$elapsed" =~ ^([0-9]{1,2}):([0-9]{2}):([0-9]{2})$ ]]; then
        hours="${BASH_REMATCH[1]}"
        mins="${BASH_REMATCH[2]}"
        secs="${BASH_REMATCH[3]}"
    elif [[ "$elapsed" =~ ^([0-9]+):([0-9]{2})$ ]]; then
        mins="${BASH_REMATCH[1]}"
        secs="${BASH_REMATCH[2]}"
    else
        echo 0
        return
    fi

    echo $((10#$days * 86400 + 10#$hours * 3600 + 10#$mins * 60 + 10#$secs))
}

# Returns STATE|ELAPSED where ELAPSED is from squeue %M.
# If the job is absent from queue, returns MISSING|00:00:00.
get_queue_state_elapsed() {
    local job_id="$1"
    local line
    line="$(squeue -h -j "$job_id" -o "%T|%M" 2>/dev/null | head -1 || true)"

    if [[ -z "$line" ]]; then
        printf 'MISSING|00:00:00\n'
        return
    fi

    printf '%s\n' "$line"
}

is_failure_state() {
    case "$1" in
        CANCELLED|FAILED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED)
            return 0
            ;;
    esac
    return 1
}

is_terminal_state() {
    case "$1" in
        COMPLETED|CANCELLED|FAILED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED)
            return 0
            ;;
    esac
    return 1
}

normalize_sacct_state() {
    local raw_state="${1:-}"
    local state

    state="$(printf '%s' "$raw_state" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | tr '[:lower:]' '[:upper:]')"
    state="${state%% *}"
    state="${state%%+*}"

    if is_terminal_state "$state"; then
        printf '%s\n' "$state"
        return 0
    fi

    return 1
}

# Returns STATE|EXIT_CODE|REASON|ELAPSED|RAW_STATE.
# STATE is one of the recognized terminal states, UNKNOWN, or UNAVAILABLE.
get_accounting_final_state() {
    local job_id="$1"
    local output
    local line
    local raw_job_id
    local raw_state
    local exit_code
    local reason
    local elapsed
    local normalized_state
    local first_terminal=""

    if ! command -v sacct >/dev/null 2>&1; then
        printf 'UNAVAILABLE||||\n'
        return 0
    fi

    output="$(sacct -n -P -j "$job_id" -o JobIDRaw,State%32,ExitCode,Reason%80,Elapsed 2>/dev/null || true)"
    if [[ -z "$output" ]]; then
        printf 'UNKNOWN||||\n'
        return 0
    fi

    while IFS='|' read -r raw_job_id raw_state exit_code reason elapsed _; do
        if [[ -z "${raw_job_id}${raw_state}" ]]; then
            continue
        fi

        normalized_state="$(normalize_sacct_state "$raw_state" || true)"
        if [[ -z "$normalized_state" ]]; then
            continue
        fi

        line="${normalized_state}|${exit_code}|${reason}|${elapsed}|${raw_state}"
        raw_job_id="${raw_job_id%%.*}"
        if [[ "$raw_job_id" == "$job_id" ]]; then
            printf '%s\n' "$line"
            return 0
        fi

        if [[ -z "$first_terminal" ]]; then
            first_terminal="$line"
        fi
    done <<< "$output"

    if [[ -n "$first_terminal" ]]; then
        printf '%s\n' "$first_terminal"
        return 0
    fi

    printf 'UNKNOWN||||\n'
}

# Extract a compact OUTCAR progress marker to keep chain logs informative.
get_outcar_progress() {
    local iter_dir="$1"
    local line=""

    if [[ ! -f "$iter_dir/OUTCAR" ]]; then
        return 0
    fi

    line="$(grep -E 'Iteration[[:space:]]+[0-9]+\([[:space:]]*[0-9]+\)' "$iter_dir/OUTCAR" 2>/dev/null | tail -1 || true)"
    if [[ -z "$line" ]]; then
        return 0
    fi

    line="$(echo "$line" | sed -E 's/^[[:space:]-]+//; s/[[:space:]-]+$//; s/[[:space:]]+/ /g')"
    printf '%s\n' "$line"
}

POSCAR_SEED_MSG=""
if [[ ! -f "$WORK_POSCAR" ]]; then
    PREV_ITER=$((CONTINUE_FROM - 1))
    if [[ "$CONTINUE_FROM" -gt 1 && -s "$WORK_DIR/iteration-${PREV_ITER}/CONTCAR" ]]; then
        cp -f "$WORK_DIR/iteration-${PREV_ITER}/CONTCAR" "$WORK_POSCAR"
        POSCAR_SEED_MSG="Seeded runtime POSCAR from iteration-${PREV_ITER}/CONTCAR"
    else
        cp -f "$INPUT_DIR/POSCAR" "$WORK_POSCAR"
        POSCAR_SEED_MSG="Seeded runtime POSCAR from input/POSCAR"
    fi
fi

RESTART_SEED_MSGS=()
if [[ "$CONTINUE_FROM" -gt 1 ]]; then
    PREV_ITER=$((CONTINUE_FROM - 1))
    for restart_file in WAVECAR CHGCAR; do
        if [[ ! -f "$WORK_DIR/$restart_file" && -f "$WORK_DIR/iteration-${PREV_ITER}/$restart_file" ]]; then
            cp -f "$WORK_DIR/iteration-${PREV_ITER}/$restart_file" "$WORK_DIR/$restart_file"
            RESTART_SEED_MSGS+=("Seeded runtime $restart_file from iteration-${PREV_ITER}/$restart_file")
        fi
    done
fi

log_msg "=============================================================="
log_msg "VASP Chain Automation Started"
log_msg "Script dir:        $SCRIPT_DIR"
log_msg "Work dir:          $WORK_DIR"
log_msg "Input dir:         $INPUT_DIR"
log_msg "Log file:          $CHAIN_LOG"
if [[ "$MIRROR_CHAIN_LOG" != "$CHAIN_LOG" ]]; then
    log_msg "Mirror log file:   $MIRROR_CHAIN_LOG"
fi
log_msg "Submit script:     $SUBMIT_SCRIPT"
log_msg "Iterations:        $CONTINUE_FROM -> $MAX_ITER"
log_msg "Job name prefix:   $JOB_PREFIX"
if [[ -n "$NODES_OVERRIDE" ]]; then
    log_msg "Nodes:             $NODES_OVERRIDE (override)"
else
    log_msg "Nodes:             submit.sh default"
fi
if [[ -n "$VASP_EXE_OVERRIDE" ]]; then
    log_msg "VASP executable:   $VASP_EXE_OVERRIDE (override)"
else
    log_msg "VASP executable:   submit.sh default/env"
fi
if [[ -n "$SUCCESS_STRING" ]]; then
    log_msg "Success string:    '$SUCCESS_STRING'"
else
    log_msg "Success criteria:  non-empty CONTCAR after job completion"
fi
log_msg "Monitor interval:  $MONITOR_INTERVAL seconds"
if [[ -n "$POSCAR_SEED_MSG" ]]; then
    log_msg "$POSCAR_SEED_MSG"
fi
if [[ "${#RESTART_SEED_MSGS[@]}" -gt 0 ]]; then
    for seed_msg in "${RESTART_SEED_MSGS[@]}"; do
        log_msg "$seed_msg"
    done
fi
log_msg "=============================================================="

WORKFLOW_STATUS="running"
record_event "workflow_start" \
    "continue_from=$CONTINUE_FROM" \
    "max_iter=$MAX_ITER" \
    "job_prefix=$JOB_PREFIX" \
    "monitor_interval=$MONITOR_INTERVAL" \
    "chain_log=$CHAIN_LOG" \
    "mirror_chain_log=$MIRROR_CHAIN_LOG"

iter="$CONTINUE_FROM"

while [[ "$iter" -le "$MAX_ITER" ]]; do
    CURRENT_ITER="$iter"
    log_iter "$iter" "--------------------------------------------------"
    log_iter "$iter" "Preparing iteration $iter of $MAX_ITER"

    ITER_DIR="${WORK_DIR}/iteration-${iter}"
    mkdir -p "$ITER_DIR"

    if [[ "$iter" -eq 1 ]]; then
        INCAR_SRC="INCAR.start"
    else
        INCAR_SRC="INCAR.cont"
    fi

    cp -f "$INPUT_DIR/$INCAR_SRC" "$ITER_DIR/INCAR"
    cp -f "$WORK_POSCAR" "$ITER_DIR/POSCAR"
    cp -f "$INPUT_DIR/KPOINTS" "$ITER_DIR/KPOINTS"
    cp -f "$INPUT_DIR/POTCAR" "$ITER_DIR/POTCAR"
    rm -f "$ITER_DIR/STOPCAR"

    for restart_file in WAVECAR CHGCAR; do
        if [[ -f "$WORK_DIR/$restart_file" ]]; then
            cp -f "$WORK_DIR/$restart_file" "$ITER_DIR/"
            log_iter "$iter" "Copied $restart_file for restart"
        elif [[ "$iter" -eq 1 && -f "$INPUT_DIR/$restart_file" ]]; then
            cp -f "$INPUT_DIR/$restart_file" "$ITER_DIR/"
            log_iter "$iter" "Copied $restart_file from input dir"
        fi
    done

    log_iter "$iter" "Submitting job to SLURM"

    JOB_NAME="${JOB_PREFIX}-iter-${iter}"
    JOB_OUTPUT="${ITER_DIR}/job.%J.out"
    JOB_ERROR="${ITER_DIR}/job.%J.err"
    CURRENT_JOB_ID=""
    CURRENT_JOB_NAME="$JOB_NAME"
    CURRENT_JOB_STATE="SUBMITTING"
    CURRENT_JOB_ELAPSED=""
    CURRENT_JOB_ELAPSED_SECONDS=""
    LAST_FINAL_STATE=""
    LAST_FINAL_STATE_SOURCE=""
    LAST_EXIT_CODE=""

    SBATCH_ARGS=(
        --chdir="$ITER_DIR"
        --job-name="$JOB_NAME"
        --output="$JOB_OUTPUT"
        --error="$JOB_ERROR"
        --parsable
    )

    if [[ -n "$NODES_OVERRIDE" ]]; then
        SBATCH_ARGS+=(--nodes="$NODES_OVERRIDE")
    fi

    if [[ -n "$VASP_EXE_OVERRIDE" ]]; then
        SBATCH_ARGS+=(--export="ALL,VASP_EXE=$VASP_EXE_OVERRIDE")
    fi

    JOB_ID="$(sbatch "${SBATCH_ARGS[@]}" "$SUBMIT_SCRIPT" || true)"
    JOB_ID="${JOB_ID%%;*}"

    if [[ -z "$JOB_ID" || ! "$JOB_ID" =~ ^[0-9]+$ ]]; then
        log_iter "$iter" "ERROR: sbatch failed (job id: '$JOB_ID')"
        fail_iteration_and_workflow "$iter" "sbatch failed (job id: '$JOB_ID')" "SUBMIT_FAILED"
    fi

    log_iter "$iter" "Submitted job ID: $JOB_ID"
    CURRENT_JOB_ID="$JOB_ID"
    CURRENT_JOB_STATE="SUBMITTED"
    record_event "job_submit" \
        "iteration=$iter" \
        "job_id=$JOB_ID" \
        "job_name=$JOB_NAME" \
        "iter_dir=$ITER_DIR"

    STOPCAR_WRITTEN=0
    LABORT_WRITTEN=0
    LOOP_COUNT=0
    MISSING_STATUS_COUNT=0
    STATE="PENDING"
    FINAL_STATE_RECORDED=0

    log_iter "$iter" "Starting job monitoring (squeue)"

    while true; do
        LOOP_COUNT=$((LOOP_COUNT + 1))

        JOB_META="$(get_queue_state_elapsed "$JOB_ID")"
        STATE="${JOB_META%%|*}"
        ELAPSED="${JOB_META#*|}"
        ELAPSED_SEC="$(elapsed_to_seconds "$ELAPSED")"
        CURRENT_JOB_STATE="$STATE"
        CURRENT_JOB_ELAPSED="$ELAPSED"
        CURRENT_JOB_ELAPSED_SECONDS="$ELAPSED_SEC"

        OUTCAR_PROGRESS="$(get_outcar_progress "$ITER_DIR")"
        if [[ -n "$OUTCAR_PROGRESS" ]]; then
            log_iter "$iter" "[Check $LOOP_COUNT] Status: $STATE | Elapsed: $ELAPSED ($ELAPSED_SEC s) | OUTCAR: $OUTCAR_PROGRESS"
        else
            log_iter "$iter" "[Check $LOOP_COUNT] Status: $STATE | Elapsed: $ELAPSED ($ELAPSED_SEC s)"
        fi
        record_event "poll" \
            "iteration=$iter" \
            "job_id=$JOB_ID" \
            "loop=$LOOP_COUNT" \
            "state=$STATE" \
            "elapsed=$ELAPSED" \
            "elapsed_seconds=$ELAPSED_SEC" \
            "outcar_progress=$OUTCAR_PROGRESS"

        if [[ "$STATE" == "MISSING" ]]; then
            MISSING_STATUS_COUNT=$((MISSING_STATUS_COUNT + 1))
            if [[ "$MISSING_STATUS_COUNT" -ge 2 ]]; then
                ACCOUNTING_META="$(get_accounting_final_state "$JOB_ID")"
                IFS='|' read -r ACCOUNTING_STATE ACCOUNTING_EXIT_CODE ACCOUNTING_REASON ACCOUNTING_ELAPSED ACCOUNTING_RAW_STATE <<< "$ACCOUNTING_META"

                if is_terminal_state "$ACCOUNTING_STATE"; then
                    STATE="$ACCOUNTING_STATE"
                    if [[ -n "$ACCOUNTING_ELAPSED" ]]; then
                        ELAPSED="$ACCOUNTING_ELAPSED"
                    fi
                    log_iter "$iter" "Job left queue; sacct final state: $STATE"
                    record_final_state "$iter" "$JOB_ID" "$STATE" "sacct" "$ACCOUNTING_EXIT_CODE" "$ACCOUNTING_REASON" "$ELAPSED" "$ACCOUNTING_RAW_STATE"
                    FINAL_STATE_RECORDED=1
                else
                    STATE="FINISHED"
                    if [[ "$ACCOUNTING_STATE" == "UNAVAILABLE" ]]; then
                        log_iter "$iter" "Job left queue; assuming it finished"
                        record_final_state "$iter" "$JOB_ID" "$STATE" "assumed" "" "sacct unavailable" "$ELAPSED" "$ACCOUNTING_STATE"
                    else
                        log_iter "$iter" "Job left queue; sacct final state unavailable; assuming it finished"
                        record_final_state "$iter" "$JOB_ID" "$STATE" "sacct_unknown" "" "sacct returned no terminal state" "$ELAPSED" "$ACCOUNTING_STATE"
                    fi
                    FINAL_STATE_RECORDED=1
                fi
                break
            fi
            sleep "$MONITOR_INTERVAL"
            continue
        fi

        MISSING_STATUS_COUNT=0

        if [[ "$STATE" == "RUNNING" && "$STOPCAR_WRITTEN" -eq 0 && "$ELAPSED_SEC" -ge "$STOPCAR_TIME" ]]; then
            if echo "LSTOP = .TRUE." > "$ITER_DIR/STOPCAR"; then
                log_iter "$iter" "Wrote STOPCAR at elapsed $ELAPSED"
                STOPCAR_WRITTEN=1
            else
                log_iter "$iter" "WARNING: failed to write STOPCAR"
            fi
        fi

        if [[ "$STATE" == "RUNNING" && "$LABORT_WRITTEN" -eq 0 && "$ELAPSED_SEC" -ge "$LABORT_TIME" ]]; then
            if echo "LABORT = .TRUE." >> "$ITER_DIR/STOPCAR" 2>/dev/null; then
                log_iter "$iter" "Wrote LABORT at elapsed $ELAPSED"
            elif echo "LABORT = .TRUE." > "$ITER_DIR/STOPCAR"; then
                log_iter "$iter" "Wrote LABORT to STOPCAR at elapsed $ELAPSED"
            else
                log_iter "$iter" "WARNING: failed to write LABORT"
            fi
            LABORT_WRITTEN=1
        fi

        if is_terminal_state "$STATE"; then
            if is_failure_state "$STATE"; then
                log_iter "$iter" "Job entered terminal failure state: $STATE"
            else
                log_iter "$iter" "Job entered terminal state: $STATE"
            fi
            record_final_state "$iter" "$JOB_ID" "$STATE" "squeue" "" "" "$ELAPSED" "$STATE"
            FINAL_STATE_RECORDED=1
            break
        fi

        sleep "$MONITOR_INTERVAL"
    done

    if [[ "$FINAL_STATE_RECORDED" -eq 0 ]]; then
        record_final_state "$iter" "$JOB_ID" "$STATE" "launcher" "" "" "$ELAPSED" "$STATE"
    fi

    if is_failure_state "$STATE"; then
        log_iter "$iter" "ERROR: iteration failed in final state $STATE"
        fail_iteration_and_workflow "$iter" "iteration failed in final state $STATE" "$STATE"
    fi

    if [[ ! -f "$ITER_DIR/OUTCAR" ]]; then
        log_iter "$iter" "ERROR: OUTCAR missing after job completion"
        fail_iteration_and_workflow "$iter" "OUTCAR missing after job completion" "$STATE"
    fi

    SUCCESS=0
    CONVERGED=0
    if [[ -s "$ITER_DIR/CONTCAR" ]]; then
        SUCCESS=1
        log_iter "$iter" "Checkpoint ready: CONTCAR is present and non-empty"
    else
        log_iter "$iter" "ERROR: CONTCAR missing or empty"
    fi

    if [[ -n "$SUCCESS_STRING" ]]; then
        if grep -qF "$SUCCESS_STRING" "$ITER_DIR/OUTCAR" 2>/dev/null; then
            log_iter "$iter" "SUCCESS: found success string in OUTCAR"
            CONVERGED=1
        else
            log_iter "$iter" "Success string not found yet; continuing from checkpoint"
        fi
    fi

    if [[ "$SUCCESS" -ne 1 ]]; then
        log_iter "$iter" "Stopping chain at iteration $iter"
        fail_iteration_and_workflow "$iter" "CONTCAR missing or empty" "$STATE"
    fi

    if [[ -s "$ITER_DIR/CONTCAR" ]]; then
        cp -f "$ITER_DIR/CONTCAR" "$WORK_POSCAR"
        log_iter "$iter" "Copied CONTCAR to $WORK_POSCAR"
    else
        log_iter "$iter" "ERROR: CONTCAR missing or empty"
        fail_iteration_and_workflow "$iter" "CONTCAR missing or empty" "$STATE"
    fi

    for restart_file in WAVECAR CHGCAR; do
        if [[ -f "$ITER_DIR/$restart_file" ]]; then
            cp -f "$ITER_DIR/$restart_file" "$WORK_DIR/"
            log_iter "$iter" "Copied $restart_file back to work dir"
        fi
    done

    LAST_COMPLETED_ITER="$iter"
    WORKFLOW_CONVERGED="$CONVERGED"
    record_event "iteration_success" \
        "iteration=$iter" \
        "job_id=$JOB_ID" \
        "state=$STATE" \
        "converged=$CONVERGED"

    if [[ "$CONVERGED" -eq 1 ]]; then
        log_iter "$iter" "Convergence reached; stopping chain after iteration $iter"
        break
    fi

    iter=$((iter + 1))
    log_iter "$((iter - 1))" "Advancing to iteration $iter"
done

CURRENT_ITER=""
WORKFLOW_STATUS="completed"
FINAL_ITERATION="${LAST_COMPLETED_ITER:-$((iter - 1))}"
record_event "workflow_complete" \
    "final_iteration=$FINAL_ITERATION" \
    "max_iter=$MAX_ITER" \
    "converged=$WORKFLOW_CONVERGED"

log_msg "=============================================================="
log_msg "Chain automation completed successfully"
log_msg "Final iteration: $FINAL_ITERATION / $MAX_ITER"
log_msg "=============================================================="
