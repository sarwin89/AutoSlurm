#!/bin/bash
################################################################################
#   launch.sh - Automated VASP iteration chain orchestrator
#   
#   Handles:
#   - Creating iteration folders with proper INCAR/POSCAR/KPOINTS/POTCAR
#   - Submitting jobs to SLURM  
#   - Monitoring job status every 30-60 minutes
#   - Writing STOPCAR/LABORT at 22h/23h of actual compute time (excluding queue)
#   - Checking success criteria in OUTCAR
#   - Logging all activity to a chain log file
#   - Advancing iterations based on successful completion
#
#   Usage: ./launch.sh [--continue-from N] [--max-iter M] [--name JOB_PREFIX] \
#                      [--success-string "text"] [--monitor-interval SECS]
#
#   Example: ./launch.sh --continue-from 1 --max-iter 20 --name "MoS2-relax" \
#                --success-string "reached structural accuracy" --monitor-interval 1800
################################################################################

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
#                           DEFAULTS & SETUP
# ──────────────────────────────────────────────────────────────────────────────

CONTINUE_FROM=1
MAX_ITER=20
JOB_PREFIX="VASP-calc"
SUCCESS_STRING="reached structural accuracy"  # User can override
MONITOR_INTERVAL=1800                          # 30 minutes in seconds
STOPCAR_TIME=79200                            # 22 hours of actual run time (seconds)
LABORT_TIME=82800                             # 23 hours of actual run time (seconds)

BASE_DIR="$(pwd)"
CHAIN_LOG="${BASE_DIR}/chain_$(date '+%Y%m%d_%H%M%S').log"
SUBMIT_SCRIPT="${BASE_DIR}/submit.sh"

# ──────────────────────────────────────────────────────────────────────────────
#                         ARGUMENT PARSING
# ──────────────────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
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
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--continue-from N] [--max-iter M] [--name PREFIX]"
            echo "          [--success-string TEXT] [--monitor-interval SECS]"
            exit 1
            ;;
    esac
done


# ──────────────────────────────────────────────────────────────────────────────
#                       VALIDATION & FILE CHECKS
# ──────────────────────────────────────────────────────────────────────────────

if ! [[ "$CONTINUE_FROM" =~ ^[0-9]+$ ]] || [[ "$CONTINUE_FROM" -lt 1 ]]; then
    echo "Error: --continue-from must be integer >= 1"
    exit 1
fi
if ! [[ "$MAX_ITER" =~ ^[0-9]+$ ]] || [[ "$MAX_ITER" -lt "$CONTINUE_FROM" ]]; then
    echo "Error: --max-iter must be >= --continue-from"
    exit 1
fi
if ! [[ "$MONITOR_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$MONITOR_INTERVAL" -lt 60 ]]; then
    echo "Error: --monitor-interval must be >= 60 seconds"
    exit 1
fi

# Verify required files exist
for file in INCAR.start INCAR.cont KPOINTS POSCAR POTCAR "$SUBMIT_SCRIPT"; do
    if [[ ! -f "$file" ]]; then
        echo "Error: Required file not found: $file"
        exit 1
    fi
done

# ──────────────────────────────────────────────────────────────────────────────
#                         LOGGING FUNCTION
# ──────────────────────────────────────────────────────────────────────────────

log_msg() {
    local msg="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp]  $msg" | tee -a "$CHAIN_LOG"
}

log_iter() {
    local iter="$1"
    local msg="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp]  [ITER-$iter]  $msg" | tee -a "$CHAIN_LOG"
}

# ──────────────────────────────────────────────────────────────────────────────
#                         START MAIN CHAIN
# ──────────────────────────────────────────────────────────────────────────────

log_msg "═════════════════════════════════════════════════════════════"
log_msg "VASP Chain Automation Started"
log_msg "Base directory:    $BASE_DIR"
log_msg "Iterations:        $CONTINUE_FROM → $MAX_ITER"
log_msg "Job name prefix:   $JOB_PREFIX"
log_msg "Success string:    $SUCCESS_STRING"
log_msg "Monitor interval:  $MONITOR_INTERVAL seconds (${MONITOR_INTERVAL}s ≈ $((MONITOR_INTERVAL/60)) min)"
log_msg "═════════════════════════════════════════════════════════════"



iter=$CONTINUE_FROM

while [[ $iter -le $MAX_ITER ]]; do
    log_iter "$iter" "────────────────────────────────────────────────"
    log_iter "$iter" "Preparing iteration $iter of $MAX_ITER"

    # ──────────────────────────────
    #   Setup iteration folder
    # ──────────────────────────────
    ITER_DIR="${BASE_DIR}/iteration-${iter}"
    mkdir -p "$ITER_DIR" || { log_iter "$iter" "ERROR: Cannot create $ITER_DIR"; exit 1; }

    # Select INCAR source (start for first, cont for rest)
    if [[ $iter -eq 1 ]]; then
        INCAR_SRC="INCAR.start"
    else
        INCAR_SRC="INCAR.cont"
    fi

    [[ -f "$INCAR_SRC" ]] || { log_iter "$iter" "ERROR: Missing $INCAR_SRC"; exit 1; }

    # Copy input files to iteration folder
    for src in "$INCAR_SRC" POSCAR KPOINTS POTCAR; do
        if [[ "$src" == "INCAR.start" || "$src" == "INCAR.cont" ]]; then
            cp -f "$src" "${ITER_DIR}/INCAR" || { log_iter "$iter" "ERROR: Failed to copy $src"; exit 1; }
        else
            cp -f "$src" "${ITER_DIR}/" || { log_iter "$iter" "ERROR: Failed to copy $src"; exit 1; }
        fi
    done

    log_iter "$iter" "Copied input files (INCAR, POSCAR, KPOINTS, POTCAR)"

    # Copy restart files from base if they exist from previous iteration
    for restart_file in WAVECAR CHGCAR; do
        if [[ -f "${BASE_DIR}/${restart_file}" ]]; then
            cp -f "${BASE_DIR}/${restart_file}" "${ITER_DIR}/"
            log_iter "$iter" "Copied $restart_file for restart"
        fi
    done

    # ──────────────────────────────
    #   Submit job to SLURM
    # ──────────────────────────────
    log_iter "$iter" "Submitting job to SLURM"

    JOB_NAME="${JOB_PREFIX}-iter-${iter}"
    JOB_OUTPUT="${ITER_DIR}/job.%J.out"
    JOB_ERROR="${ITER_DIR}/job.%J.err"

    JOB_ID=$(sbatch \
        --chdir="${ITER_DIR}" \
        --job-name="$JOB_NAME" \
        --output="$JOB_OUTPUT" \
        --error="$JOB_ERROR" \
        --parsable \
        "$SUBMIT_SCRIPT" 2>&1 || echo "")

    if [[ -z "$JOB_ID" ]]; then
        log_iter "$iter" "ERROR: sbatch failed"
        exit 1
    fi

    log_iter "$iter" "Submitted → Job ID: $JOB_ID"

    # ──────────────────────────────
    #   Monitor job with STOPCAR/LABORT handling
    # ──────────────────────────────
    STOPCAR_WRITTEN=0
    LABORT_WRITTEN=0
    LOOP_COUNT=0

    log_iter "$iter" "Starting job monitoring"

    while true; do
        LOOP_COUNT=$((LOOP_COUNT + 1))

        # Get job status via sacct
        STATE=$(sacct -n -X -o State -j "$JOB_ID" 2>/dev/null | head -1 || echo "UNKNOWN")

        # Get elapsed time (only valid if job is running)
        ELAPSED=$(sacct -n -X -o Elapsed -j "$JOB_ID" 2>/dev/null | head -1 || echo "00:00:00")

        # Convert elapsed time to seconds for comparison
        ELAPSED_SEC=$(echo "$ELAPSED" | awk -F: '{print $1*3600 + $2*60 + $3}')

        log_iter "$iter" "[Check $LOOP_COUNT] Status: $STATE | Elapsed: $ELAPSED ($ELAPSED_SEC s)"

        # ──────────────────────────
        #   Handle STOPCAR at 22 hours
        # ──────────────────────────
        if [[ "$STATE" == "RUNNING" ]] && [[ $STOPCAR_WRITTEN -eq 0 ]] && [[ $ELAPSED_SEC -ge $STOPCAR_TIME ]]; then
            if echo "LSTOP = .TRUE." > "${ITER_DIR}/STOPCAR"; then
                log_iter "$iter" "✓ Written STOPCAR (LSTOP = .TRUE.) at $ELAPSED"
                STOPCAR_WRITTEN=1
            else
                log_iter "$iter" "⚠ WARNING: Failed to write STOPCAR"
            fi
        fi

        # ──────────────────────────
        #   Handle LABORT at 23 hours
        # ──────────────────────────
        if [[ "$STATE" == "RUNNING" ]] && [[ $LABORT_WRITTEN -eq 0 ]] && [[ $ELAPSED_SEC -ge $LABORT_TIME ]]; then
            if echo "LABORT = .TRUE." >> "${ITER_DIR}/STOPCAR" 2>/dev/null; then
                log_iter "$iter" "✓ Written LABORT (LABORT = .TRUE.) appended at $ELAPSED"
            elif echo "LABORT = .TRUE." > "${ITER_DIR}/STOPCAR"; then
                log_iter "$iter" "✓ Written LABORT to STOPCAR at $ELAPSED"
            else
                log_iter "$iter" "⚠ WARNING: Failed to write LABORT"
            fi
            LABORT_WRITTEN=1
        fi

        # ──────────────────────────
        #   Check if job finished
        # ──────────────────────────
        if [[ "$STATE" == "COMPLETED" || "$STATE" == "FAILED" || "$STATE" == "CANCELLED" || "$STATE" == "TIMEOUT" ]]; then
            log_iter "$iter" "Job finished → State: $STATE"
            break
        fi

        # Sleep before next check
        sleep "$MONITOR_INTERVAL"
    done

    # ──────────────────────────────
    #   Post-job: Check success
    # ──────────────────────────────
    if [[ "$STATE" == "COMPLETED" ]]; then
        log_iter "$iter" "Job completed. Checking convergence..."

        # Look for success string in OUTCAR
        if [[ -f "${ITER_DIR}/OUTCAR" ]] && grep -q "$SUCCESS_STRING" "${ITER_DIR}/OUTCAR"; then
            log_iter "$iter" "✓ SUCCESS: Found '$SUCCESS_STRING' in OUTCAR"

            # Copy CONTCAR to POSCAR for next iteration
            if [[ -f "${ITER_DIR}/CONTCAR" && -s "${ITER_DIR}/CONTCAR" ]]; then
                cp -f "${ITER_DIR}/CONTCAR" "${BASE_DIR}/POSCAR"
                log_iter "$iter" "✓ Copied CONTCAR → base POSCAR"

                # Copy restart files back to base for next iteration
                for restart_file in WAVECAR CHGCAR; do
                    if [[ -f "${ITER_DIR}/${restart_file}" ]]; then
                        cp -f "${ITER_DIR}/${restart_file}" "${BASE_DIR}/"
                        log_iter "$iter" "✓ Copied $restart_file to base"
                    fi
                done

                next=$((iter + 1))
                log_iter "$iter" "Advancing to iteration $next"
                iter=$next

            else
                log_iter "$iter" "✗ ERROR: CONTCAR missing or empty in iteration folder"
                log_iter "$iter" "Stopping chain - check job output in $ITER_DIR"
                exit 1
            fi

        else
            log_iter "$iter" "✗ ERROR: Success string '$SUCCESS_STRING' not found in OUTCAR"
            log_iter "$iter" "Check ${ITER_DIR}/OUTCAR or job.*.out for details"
            log_iter "$iter" "Stopping chain"
            exit 1
        fi

    else
        # Job did not complete successfully
        log_iter "$iter" "✗ ERROR: Job did not complete (state: $STATE)"
        log_iter "$iter" "Check output in ${ITER_DIR}/"
        log_iter "$iter" "Stopping chain"
        exit 1
    fi

done

# ──────────────────────────────────────────────────────────────────────────────
#                         COMPLETION
# ──────────────────────────────────────────────────────────────────────────────

log_msg "═════════════════════════════════════════════════════════════"
log_msg "✓ Chain automation completed successfully"
log_msg "Final iteration: $((iter - 1)) / $MAX_ITER"
log_msg "Log file: $CHAIN_LOG"
log_msg "═════════════════════════════════════════════════════════════"
