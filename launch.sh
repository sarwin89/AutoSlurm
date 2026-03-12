#!/bin/bash
################################################################################
# launch.sh - Automated VASP iteration orchestrator (squeue-only monitoring)
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
STOPCAR_TIME=79200
LABORT_TIME=82800
WORK_DIR="$(pwd)"
INPUT_DIR=""
LOG_DIR=""
MIRROR_LOG_DIR="${SCRIPT_DIR}/logs"
SUBMIT_SCRIPT="${SCRIPT_DIR}/submit.sh"
NODES_OVERRIDE=""
VASP_EXE_OVERRIDE=""
VALIDATE_ONLY=0

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
log_msg "=============================================================="

iter="$CONTINUE_FROM"

while [[ "$iter" -le "$MAX_ITER" ]]; do
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
        exit 1
    fi

    log_iter "$iter" "Submitted job ID: $JOB_ID"

    STOPCAR_WRITTEN=0
    LABORT_WRITTEN=0
    LOOP_COUNT=0
    MISSING_STATUS_COUNT=0
    STATE="PENDING"

    log_iter "$iter" "Starting job monitoring (squeue)"

    while true; do
        LOOP_COUNT=$((LOOP_COUNT + 1))

        JOB_META="$(get_queue_state_elapsed "$JOB_ID")"
        STATE="${JOB_META%%|*}"
        ELAPSED="${JOB_META#*|}"
        ELAPSED_SEC="$(elapsed_to_seconds "$ELAPSED")"

        OUTCAR_PROGRESS="$(get_outcar_progress "$ITER_DIR")"
        if [[ -n "$OUTCAR_PROGRESS" ]]; then
            log_iter "$iter" "[Check $LOOP_COUNT] Status: $STATE | Elapsed: $ELAPSED ($ELAPSED_SEC s) | OUTCAR: $OUTCAR_PROGRESS"
        else
            log_iter "$iter" "[Check $LOOP_COUNT] Status: $STATE | Elapsed: $ELAPSED ($ELAPSED_SEC s)"
        fi

        if [[ "$STATE" == "MISSING" ]]; then
            MISSING_STATUS_COUNT=$((MISSING_STATUS_COUNT + 1))
            if [[ "$MISSING_STATUS_COUNT" -ge 2 ]]; then
                log_iter "$iter" "Job left queue; assuming it finished"
                STATE="FINISHED"
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

        case "$STATE" in
            CANCELLED|FAILED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED)
                log_iter "$iter" "Job entered terminal failure state: $STATE"
                break
                ;;
        esac

        sleep "$MONITOR_INTERVAL"
    done

    case "$STATE" in
        CANCELLED|FAILED|TIMEOUT|NODE_FAIL|OUT_OF_MEMORY|PREEMPTED)
            log_iter "$iter" "ERROR: iteration failed in queue state $STATE"
            exit 1
            ;;
    esac

    if [[ ! -f "$ITER_DIR/OUTCAR" ]]; then
        log_iter "$iter" "ERROR: OUTCAR missing after job completion"
        exit 1
    fi

    SUCCESS=0
    if [[ -n "$SUCCESS_STRING" ]]; then
        if grep -qF "$SUCCESS_STRING" "$ITER_DIR/OUTCAR" 2>/dev/null; then
            log_iter "$iter" "SUCCESS: found success string in OUTCAR"
            SUCCESS=1
        else
            log_iter "$iter" "ERROR: success string not found in OUTCAR"
            SUCCESS=0
        fi
    else
        if [[ -s "$ITER_DIR/CONTCAR" ]]; then
            log_iter "$iter" "SUCCESS: CONTCAR is present and non-empty"
            SUCCESS=1
        else
            log_iter "$iter" "ERROR: CONTCAR missing or empty"
            SUCCESS=0
        fi
    fi

    if [[ "$SUCCESS" -ne 1 ]]; then
        log_iter "$iter" "Stopping chain at iteration $iter"
        exit 1
    fi

    if [[ -s "$ITER_DIR/CONTCAR" ]]; then
        cp -f "$ITER_DIR/CONTCAR" "$WORK_POSCAR"
        log_iter "$iter" "Copied CONTCAR to $WORK_POSCAR"
    else
        log_iter "$iter" "ERROR: CONTCAR missing or empty"
        exit 1
    fi

    for restart_file in WAVECAR CHGCAR; do
        if [[ -f "$ITER_DIR/$restart_file" ]]; then
            cp -f "$ITER_DIR/$restart_file" "$WORK_DIR/"
            log_iter "$iter" "Copied $restart_file back to work dir"
        fi
    done

    iter=$((iter + 1))
    log_iter "$((iter - 1))" "Advancing to iteration $iter"
done

log_msg "=============================================================="
log_msg "Chain automation completed successfully"
log_msg "Final iteration: $((iter - 1)) / $MAX_ITER"
log_msg "=============================================================="