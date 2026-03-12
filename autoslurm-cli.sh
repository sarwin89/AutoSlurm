#!/bin/bash
################################################################################
# autoslurm-cli.sh - Interactive frontend wrapper for AutoSlurm launch workflow
#
# - Uses current directory as workdir
# - Runs setup-check + launch validation
# - Optional reset (full or from iteration)
# - Submits launch.sh with nohup and exits immediately
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"
INPUT_DIR="${WORK_DIR}/input"
LOG_DIR="${WORK_DIR}/logs"

AUTOSLURM_DEFAULT="${SCRIPT_DIR}"
VASP_BASE_DEFAULT="/pfs/home/shobhana/softwares/VASP-6.2.1/vasp.6.2.1/bin"

ask_with_default() {
    local prompt="$1"
    local default_value="$2"
    local answer
    read -r -p "$prompt [$default_value]: " answer
    if [[ -z "$answer" ]]; then
        printf '%s\n' "$default_value"
    else
        printf '%s\n' "$answer"
    fi
}

ask_yes_no() {
    local prompt="$1"
    local default_yes="$2"
    local answer
    if [[ "$default_yes" -eq 1 ]]; then
        read -r -p "$prompt [Y/n]: " answer
        [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
    else
        read -r -p "$prompt [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]]
    fi
}

echo "=============================================================="
echo "AutoSlurm Interactive Launcher"
echo "=============================================================="
echo "Work dir (current): $WORK_DIR"
echo "Input dir:          $INPUT_DIR"
echo "Job log dir:        $LOG_DIR"
echo ""

autoslurm="$AUTOSLURM_DEFAULT"
vasp_base="$VASP_BASE_DEFAULT"

if ! ask_yes_no "Use default AutoSlurm and VASP base paths?" 1; then
    autoslurm="$(ask_with_default "AutoSlurm directory" "$AUTOSLURM_DEFAULT")"
    vasp_base="$(ask_with_default "VASP base directory" "$VASP_BASE_DEFAULT")"
fi

if [[ "$autoslurm" != /* ]]; then
    autoslurm="${WORK_DIR}/${autoslurm}"
fi
autoslurm="$(cd "$autoslurm" && pwd)"

if [[ ! -d "$autoslurm" ]]; then
    echo "Error: AutoSlurm directory not found: $autoslurm"
    exit 1
fi

for required in launch.sh setup-check.sh submit.sh reset-run.sh; do
    if [[ ! -f "$autoslurm/$required" ]]; then
        echo "Error: missing $autoslurm/$required"
        exit 1
    fi
done

echo ""
echo "Choose VASP executable variant:"
echo "  1) vasp_std"
echo "  2) vasp_ncl"
echo "  3) vasp_gam"
echo "  4) custom executable path"
read -r -p "Selection [1]: " vasp_choice
vasp_choice="${vasp_choice:-1}"

case "$vasp_choice" in
    1)
        vasp_exe="${vasp_base}/vasp_std"
        ;;
    2)
        vasp_exe="${vasp_base}/vasp_ncl"
        ;;
    3)
        vasp_exe="${vasp_base}/vasp_gam"
        ;;
    4)
        read -r -p "Enter full VASP executable path: " vasp_exe
        if [[ -z "$vasp_exe" ]]; then
            echo "Error: VASP executable path cannot be empty"
            exit 1
        fi
        ;;
    *)
        echo "Error: invalid selection '$vasp_choice'"
        exit 1
        ;;
esac

echo ""
echo "Reset options before submit:"
echo "  0) no reset"
echo "  1) full reset (all iterations and logs)"
echo "  2) reset from iteration N onward"
read -r -p "Selection [0]: " reset_choice
reset_choice="${reset_choice:-0}"

case "$reset_choice" in
    0)
        ;;
    1)
        "$autoslurm/reset-run.sh" \
            --workdir "$WORK_DIR" \
            --log-dir "$LOG_DIR" \
            --mirror-log-dir "$autoslurm/logs" \
            --yes
        ;;
    2)
        read -r -p "Reset from iteration number: " from_iter
        if ! [[ "$from_iter" =~ ^[0-9]+$ ]] || [[ "$from_iter" -lt 1 ]]; then
            echo "Error: iteration must be an integer >= 1"
            exit 1
        fi
        "$autoslurm/reset-run.sh" \
            --workdir "$WORK_DIR" \
            --log-dir "$LOG_DIR" \
            --mirror-log-dir "$autoslurm/logs" \
            --from-iter "$from_iter" \
            --yes
        ;;
    *)
        echo "Error: invalid reset selection '$reset_choice'"
        exit 1
        ;;
esac

echo ""
echo "Running setup check..."
"$autoslurm/setup-check.sh" \
    --workdir "$WORK_DIR" \
    --input-dir "$INPUT_DIR" \
    --log-dir "$LOG_DIR" \
    --mirror-log-dir "$autoslurm/logs"

echo ""
echo "Running launch validation..."
"$autoslurm/launch.sh" --validate-only \
    --workdir "$WORK_DIR" \
    --input-dir "$INPUT_DIR" \
    --log-dir "$LOG_DIR" \
    --mirror-log-dir "$autoslurm/logs" \
    --vasp-exe "$vasp_exe"

echo ""
job_name_default="$(basename "$WORK_DIR")"
job_name="$(ask_with_default "Job name prefix" "$job_name_default")"
continue_from="$(ask_with_default "Continue from iteration" "1")"
max_iter="$(ask_with_default "Max iteration" "20")"
monitor_interval="$(ask_with_default "Monitor interval (seconds)" "1800")"

echo ""
echo "Success string options:"
echo "  1) stopping structural energy minimisation"
echo "  2) reached required accuracy - stopping structural energy minimisation"
echo "  3) none (only require non-empty CONTCAR)"
echo "  4) custom"
read -r -p "Selection [1]: " success_choice
success_choice="${success_choice:-1}"
success_string=""

case "$success_choice" in
    1)
        success_string="stopping structural energy minimisation"
        ;;
    2)
        success_string="reached required accuracy - stopping structural energy minimisation"
        ;;
    3)
        success_string=""
        ;;
    4)
        read -r -p "Enter success string: " success_string
        ;;
    *)
        echo "Error: invalid success string selection '$success_choice'"
        exit 1
        ;;
esac

launch_args=(
    --workdir "$WORK_DIR"
    --input-dir "$INPUT_DIR"
    --log-dir "$LOG_DIR"
    --mirror-log-dir "$autoslurm/logs"
    --name "$job_name"
    --continue-from "$continue_from"
    --max-iter "$max_iter"
    --monitor-interval "$monitor_interval"
    --vasp-exe "$vasp_exe"
)

if [[ -n "$success_string" ]]; then
    launch_args+=(--success-string "$success_string")
fi

echo ""
echo "Submission summary:"
echo "  AutoSlurm dir:   $autoslurm"
echo "  Work dir:        $WORK_DIR"
echo "  Input dir:       $INPUT_DIR"
echo "  Job log dir:     $LOG_DIR"
echo "  Mirror log dir:  $autoslurm/logs"
echo "  VASP executable: $vasp_exe"
echo "  Job prefix:      $job_name"
echo "  Iterations:      $continue_from -> $max_iter"
echo "  Monitor interval:$monitor_interval"
if [[ -n "$success_string" ]]; then
    echo "  Success string:  $success_string"
else
    echo "  Success string:  (disabled)"
fi

if ! ask_yes_no "Submit now with nohup in background?" 1; then
    echo "Submission aborted."
    exit 0
fi

mkdir -p "$LOG_DIR"
launcher_log="${LOG_DIR}/launcher_$(date '+%Y%m%d_%H%M%S').log"

nohup "$autoslurm/launch.sh" "${launch_args[@]}" > "$launcher_log" 2>&1 < /dev/null &
launch_pid=$!
disown "$launch_pid" 2>/dev/null || true

echo ""
echo "Submitted successfully."
echo "  Launcher PID:    $launch_pid"
echo "  Launcher log:    $launcher_log"
echo "  Chain logs:      $LOG_DIR and $autoslurm/logs"
echo ""
echo "You can close this terminal now."