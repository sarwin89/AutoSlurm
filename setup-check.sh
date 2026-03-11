#!/bin/bash
################################################################################
# setup-check.sh - Verify VASP automation setup
#
# Checks for required files, SLURM configuration, and provides diagnostics.
# Usage: ./setup-check.sh [--fix]
################################################################################

set -euo pipefail

FIX_MODE=0
if [[ "${1:-}" == "--fix" ]]; then
    FIX_MODE=1
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

print_sep() {
    echo "------------------------------------------------------------------"
}

print_sep
echo "   VASP Automation Setup Checker"
print_sep
echo ""

# ------------------------------------------------------------------
# Check Required Files
# ------------------------------------------------------------------

echo "Checking required files..."
MISSING_COUNT=0

required_files=("launch.sh" "submit.sh" "INCAR.start" "INCAR.cont" "KPOINTS" "POSCAR" "POTCAR")

for file in "${required_files[@]}"; do
    if [[ -f "$file" ]]; then
        check_pass "Found: $file"
    else
        check_fail "Missing: $file"
        MISSING_COUNT=$((MISSING_COUNT + 1))
    fi
done

echo ""

# ------------------------------------------------------------------
# Check Script Permissions and Line Endings
# ------------------------------------------------------------------

echo "Checking script permissions..."
for script in launch.sh submit.sh; do
    if [[ -f "$script" ]]; then
        if [[ -x "$script" ]]; then
            check_pass "$script is executable"
        else
            check_warn "$script is not executable (should be)"
            if [[ $FIX_MODE -eq 1 ]]; then
                chmod +x "$script"
                check_pass "Fixed: made $script executable"
            fi
        fi

        if grep -q $'\r' "$script"; then
            check_warn "$script contains CRLF line endings"
            if [[ $FIX_MODE -eq 1 ]]; then
                sed -i 's/\r$//' "$script" && check_pass "Fixed: converted $script to LF"
            fi
        fi
    fi
done

echo ""

# ------------------------------------------------------------------
# Check launch.sh Configuration
# ------------------------------------------------------------------

echo "Checking launch.sh configuration..."

if grep -q "STOPCAR_TIME=79200" launch.sh; then
    check_pass "STOPCAR time set to 22 hours (79200s)"
else
    check_warn "STOPCAR_TIME not found or modified"
fi

if grep -q "LABORT_TIME=82800" launch.sh; then
    check_pass "LABORT time set to 23 hours (82800s)"
else
    check_warn "LABORT_TIME not found or modified"
fi

if grep -q "MONITOR_INTERVAL=" launch.sh; then
    INTERVAL=$(grep "MONITOR_INTERVAL=" launch.sh | head -1 | cut -d'=' -f2 | sed 's/[[:space:]]*#.*//')
    check_info "Monitoring interval set to: $INTERVAL seconds"
fi

echo ""

# ------------------------------------------------------------------
# Check submit.sh SLURM Configuration
# ------------------------------------------------------------------

echo "Checking submit.sh SLURM configuration..."

effective_sbatch_line=$(awk '/^[[:space:]]*#SBATCH[[:space:]]/ {print NR; exit}' submit.sh)
effective_code_line=$(awk '/^[[:space:]]*$/ {next} /^[[:space:]]*#/ {next} {print NR; exit}' submit.sh)

if [[ -z "$effective_sbatch_line" ]]; then
    check_fail "No #SBATCH directives found in submit.sh"
elif [[ -n "$effective_code_line" && "$effective_code_line" -lt "$effective_sbatch_line" ]]; then
    check_fail "Executable content appears before #SBATCH directives; SLURM will ignore SBATCH settings"
else
    check_pass "SBATCH directives appear before executable shell code"
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

if line=$(grep "#SBATCH -N" submit.sh | head -1); then
    NODES=$(extract_value "$line")
    check_info "Number of nodes: $NODES"
    if ! [[ "$NODES" =~ ^[0-9]+$ ]]; then
        check_warn "Nodes value '$NODES' looks non-numeric (check SBATCH -N directive)"
    fi
fi

if line=$(grep "#SBATCH --ntasks-per-node" submit.sh | head -1); then
    TASKS=$(extract_value "$line")
    check_info "Tasks per node: $TASKS"
    if ! [[ "$TASKS" =~ ^[0-9]+$ ]]; then
        check_warn "Tasks-per-node value '$TASKS' looks non-numeric (check SBATCH directive)"
    fi
fi

if line=$(grep "#SBATCH --time" submit.sh | head -1); then
    TIME=$(extract_value "$line")
    check_info "Walltime limit: $TIME"
    if [[ "$TIME" == "24:00:00" ]]; then
        check_pass "Walltime is 24 hours (correct for STOPCAR at 22h)"
    else
        check_warn "Walltime is $TIME (should be at least 24:00:00)"
    fi
fi

if line=$(grep "#SBATCH --partition" submit.sh | head -1); then
    PARTITION=$(extract_value "$line")
    check_warn "Partition set to: $PARTITION (verify this matches your cluster)"
    if [[ "${PARTITION,,}" == *gpu* ]]; then
        check_warn "Partition name contains 'gpu' - this may queue on GPU nodes"
    fi
fi

if grep -qi "gres.*gpu" submit.sh; then
    check_warn "submit.sh appears to request GPUs (check SBATCH directives)"
fi

echo ""

# ------------------------------------------------------------------
# Check INCAR Files
# ------------------------------------------------------------------

echo "Checking INCAR files..."

if [[ -f "INCAR.start" ]]; then
    LINES=$(wc -l < INCAR.start)
    check_info "INCAR.start: $LINES lines"
    if grep -q "ISTART" INCAR.start; then
        ISTART=$(grep "ISTART" INCAR.start | head -1)
        check_info "  First iteration: $ISTART"
    else
        check_warn "  ISTART not set (may need to be 0 for fresh start)"
    fi
fi

if [[ -f "INCAR.cont" ]]; then
    LINES=$(wc -l < INCAR.cont)
    check_info "INCAR.cont: $LINES lines"
    if grep -q "ISTART" INCAR.cont; then
        ISTART=$(grep "ISTART" INCAR.cont | head -1)
        check_info "  Continuation: $ISTART"
        if ! grep -q "ISTART = 1" INCAR.cont; then
            check_warn "  ISTART should typically be 1 for continuing from WAVECAR"
        fi
    else
        check_warn "  ISTART not set (should be 1 to read WAVECAR)"
    fi
fi

echo ""

# ------------------------------------------------------------------
# Check VASP Input Files
# ------------------------------------------------------------------

echo "Checking VASP input files..."

for file in KPOINTS POSCAR POTCAR; do
    if [[ -f "$file" ]]; then
        SIZE=$(du -h "$file" | cut -f1)
        LINES=$(wc -l < "$file")
        check_info "$file: $LINES lines, ~$SIZE"
    fi
done

echo ""

# ------------------------------------------------------------------
# Check SLURM Availability
# ------------------------------------------------------------------

echo "Checking SLURM availability..."

if command -v sbatch &> /dev/null; then
    check_pass "sbatch command found"
else
    check_fail "sbatch not found (SLURM not installed or not in PATH)"
fi

if command -v sacct &> /dev/null; then
    check_pass "sacct command found"
else
    check_fail "sacct not found (cannot monitor jobs)"
fi

if command -v scontrol &> /dev/null; then
    check_pass "scontrol command found"
else
    check_fail "scontrol not found (needed for job info)"
fi

echo ""

# ------------------------------------------------------------------
# Test Mode Dry-Run
# ------------------------------------------------------------------

echo "Testing launch.sh dry-run (argument parsing)..."

if ./launch.sh --validate-only >/dev/null 2>&1; then
    check_pass "launch.sh validation mode works (no job submission)"
else
    check_fail "launch.sh validation mode failed (run ./launch.sh --validate-only for details)"
fi

echo ""

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------

print_sep

if [[ $MISSING_COUNT -gt 0 ]]; then
    echo -e "${RED}Setup incomplete: $MISSING_COUNT files missing${NC}"
    echo ""
    echo "To create template files, run:"
    echo "  $0 --fix"
    echo ""
    exit 1
else
    check_pass "All required files present!"
    echo ""
    echo "Ready to run:"
    echo "  ./launch.sh --name \"yourjob\" --max-iter 20 \\"
    echo "              --success-string \"reached structural accuracy\""
    echo ""
fi

print_sep
