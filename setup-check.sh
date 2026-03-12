#!/bin/bash
################################################################################
# setup-check.sh - Verify AutoSlurm configuration
#
# Validates:
# - required scripts and VASP input files
# - submit script SBATCH directives
# - launch.sh validation mode
#
# Usage:
#   ./setup-check.sh [--workdir PATH] [--input-dir PATH] [--submit-script PATH]
#                    [--log-dir PATH] [--mirror-log-dir PATH] [--fix]
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(pwd)"
INPUT_DIR=""
LOG_DIR=""
MIRROR_LOG_DIR="${SCRIPT_DIR}/logs"
SUBMIT_SCRIPT="${SCRIPT_DIR}/submit.sh"
FIX_MODE=0

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
        --submit-script)
            SUBMIT_SCRIPT="$2"
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
        --fix)
            FIX_MODE=1
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--workdir PATH] [--input-dir PATH] [--submit-script PATH] [--log-dir PATH] [--mirror-log-dir PATH] [--fix]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ ! -d "$WORK_DIR" ]]; then
    echo "Error: workdir does not exist: $WORK_DIR"
    exit 1
fi
WORK_DIR="$(cd "$WORK_DIR" && pwd)"

if [[ -z "$INPUT_DIR" ]]; then
    INPUT_DIR="${WORK_DIR}/input"
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

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

check_pass() {
    echo -e "${GREEN}[OK]${NC} $1"
}

check_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
}

check_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

check_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

sep() {
    echo "------------------------------------------------------------------"
}

sep
echo "   AutoSlurm Setup Checker"
sep
echo ""
check_info "Script dir:      $SCRIPT_DIR"
check_info "Work dir:        $WORK_DIR"
check_info "Input dir:       $INPUT_DIR"
check_info "Log dir:         $LOG_DIR"
check_info "Mirror log dir:  $MIRROR_LOG_DIR"
check_info "Submit script:   $SUBMIT_SCRIPT"
echo ""

MISSING_COUNT=0

echo "Checking required scripts..."
if [[ -f "$SCRIPT_DIR/launch.sh" ]]; then
    check_pass "Found: launch.sh"
else
    check_fail "Missing: $SCRIPT_DIR/launch.sh"
    MISSING_COUNT=$((MISSING_COUNT + 1))
fi

if [[ -f "$SUBMIT_SCRIPT" ]]; then
    check_pass "Found: submit.sh"
else
    check_fail "Missing: $SUBMIT_SCRIPT"
    MISSING_COUNT=$((MISSING_COUNT + 1))
fi

if [[ -f "$SCRIPT_DIR/reset-run.sh" ]]; then
    check_pass "Found: reset-run.sh"
else
    check_warn "Missing: $SCRIPT_DIR/reset-run.sh"
fi

echo ""

echo "Checking required VASP input files in input dir..."
if [[ -d "$INPUT_DIR" ]]; then
    for file in INCAR.start INCAR.cont KPOINTS POSCAR POTCAR; do
        if [[ -f "$INPUT_DIR/$file" ]]; then
            check_pass "Found: input/$file"
        else
            check_fail "Missing: $INPUT_DIR/$file"
            MISSING_COUNT=$((MISSING_COUNT + 1))
        fi
    done
else
    check_fail "Input directory not found: $INPUT_DIR"
    MISSING_COUNT=$((MISSING_COUNT + 1))
fi

echo ""

echo "Checking script permissions..."
for script in "$SCRIPT_DIR/launch.sh" "$SUBMIT_SCRIPT" "$SCRIPT_DIR/reset-run.sh"; do
    if [[ -f "$script" ]]; then
        if [[ -x "$script" ]]; then
            check_pass "$(basename "$script") is executable"
        else
            check_warn "$(basename "$script") is not executable"
            if [[ "$FIX_MODE" -eq 1 ]]; then
                chmod +x "$script"
                check_pass "Fixed: made $(basename "$script") executable"
            fi
        fi

        if grep -q $'\r' "$script"; then
            check_warn "$(basename "$script") has CRLF line endings"
            if [[ "$FIX_MODE" -eq 1 ]]; then
                sed -i 's/\r$//' "$script"
                check_pass "Fixed: converted $(basename "$script") to LF"
            fi
        fi
    fi
done

echo ""

echo "Checking launch.sh timing values..."
if grep -q "STOPCAR_TIME=79200" "$SCRIPT_DIR/launch.sh"; then
    check_pass "STOPCAR_TIME is 79200 (22h)"
else
    check_warn "STOPCAR_TIME not found or modified"
fi

if grep -q "LABORT_TIME=82800" "$SCRIPT_DIR/launch.sh"; then
    check_pass "LABORT_TIME is 82800 (23h)"
else
    check_warn "LABORT_TIME not found or modified"
fi

if grep -q "MONITOR_INTERVAL=" "$SCRIPT_DIR/launch.sh"; then
    INTERVAL=$(grep "MONITOR_INTERVAL=" "$SCRIPT_DIR/launch.sh" | head -1 | cut -d'=' -f2 | sed 's/[[:space:]]*#.*//')
    check_info "Default monitor interval: $INTERVAL seconds"
fi

echo ""

echo "Checking submit.sh SBATCH configuration..."

if [[ -f "$SUBMIT_SCRIPT" ]]; then
    effective_sbatch_line=$(awk '/^[[:space:]]*#SBATCH[[:space:]]/ {print NR; exit}' "$SUBMIT_SCRIPT")
    effective_code_line=$(awk '/^[[:space:]]*$/ {next} /^[[:space:]]*#/ {next} {print NR; exit}' "$SUBMIT_SCRIPT")

    if [[ -z "$effective_sbatch_line" ]]; then
        check_fail "No #SBATCH directives found"
    elif [[ -n "$effective_code_line" && "$effective_code_line" -lt "$effective_sbatch_line" ]]; then
        check_fail "Executable content appears before #SBATCH directives"
    else
        check_pass "SBATCH directives are before executable shell code"
    fi

    extract_value() {
        local line="$1"
        line="$(echo "$line" | sed 's/[[:space:]]#.*$//')"
        if [[ "$line" == *"="* ]]; then
            echo "$line" | awk -F'=' '{print $NF}' | tr -d ' '
        else
            echo "$line" | awk '{print $NF}'
        fi
    }

    if line=$(grep "#SBATCH -N" "$SUBMIT_SCRIPT" | head -1); then
        NODES=$(extract_value "$line")
        check_info "Nodes: $NODES"
    fi

    if line=$(grep "#SBATCH --ntasks-per-node" "$SUBMIT_SCRIPT" | head -1); then
        TASKS=$(extract_value "$line")
        check_info "Tasks per node: $TASKS"
    fi

    if line=$(grep "#SBATCH --time" "$SUBMIT_SCRIPT" | head -1); then
        TIME=$(extract_value "$line")
        check_info "Walltime: $TIME"
        if [[ "$TIME" == "24:00:00" ]]; then
            check_pass "Walltime is 24h"
        else
            check_warn "Walltime is $TIME (24h recommended)"
        fi
    fi

    if line=$(grep "#SBATCH --partition" "$SUBMIT_SCRIPT" | head -1); then
        PARTITION=$(extract_value "$line")
        check_info "Partition: $PARTITION"
        if [[ "${PARTITION,,}" == *gpu* ]]; then
            check_warn "Partition contains 'gpu'"
        fi
    fi

    if grep -qi "gres.*gpu" "$SUBMIT_SCRIPT"; then
        check_warn "submit.sh appears to request GPUs"
    fi
fi

echo ""

echo "Checking scheduler commands..."
if command -v sbatch >/dev/null 2>&1; then
    check_pass "sbatch found"
else
    check_fail "sbatch not found"
fi

if command -v squeue >/dev/null 2>&1; then
    check_pass "squeue found"
else
    check_fail "squeue not found"
fi

if command -v scontrol >/dev/null 2>&1; then
    check_pass "scontrol found"
else
    check_warn "scontrol not found"
fi

if command -v sacct >/dev/null 2>&1; then
    check_info "sacct found (optional for this workflow)"
else
    check_info "sacct not found (workflow uses squeue monitoring)"
fi

echo ""

echo "Testing launch.sh --validate-only..."
if "$SCRIPT_DIR/launch.sh" \
    --validate-only \
    --workdir "$WORK_DIR" \
    --input-dir "$INPUT_DIR" \
    --log-dir "$LOG_DIR" \
    --mirror-log-dir "$MIRROR_LOG_DIR" \
    --submit-script "$SUBMIT_SCRIPT" >/dev/null 2>&1; then
    check_pass "launch.sh validation mode works"
else
    check_fail "launch.sh validation mode failed"
fi

echo ""
sep
if [[ "$MISSING_COUNT" -gt 0 ]]; then
    check_fail "Setup incomplete: $MISSING_COUNT missing files"
    exit 1
else
    check_pass "Setup looks good"
    echo ""
    echo "Run example:"
    echo "  $SCRIPT_DIR/launch.sh --workdir $WORK_DIR --name my-job --max-iter 5"
fi
sep