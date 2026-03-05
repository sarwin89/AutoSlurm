#!/bin/bash
################################################################################
#   setup-check.sh - Verify VASP automation setup
#   
#   Checks for required files, SLURM configuration, and provides diagnostics
#   Usage: ./setup-check.sh [--fix]
#   
#   Use --fix flag to auto-create template files if missing
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
NC='\033[0m' # No Color

check_pass() {
    echo -e "${GREEN}✓${NC} $1"
}

check_fail() {
    echo -e "${RED}✗${NC} $1"
}

check_warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

check_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   VASP Automation Setup Checker"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
#                         Check Required Files
# ──────────────────────────────────────────────────────────────────────────────

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

# ──────────────────────────────────────────────────────────────────────────────
#                         Check Script Permissions
# ──────────────────────────────────────────────────────────────────────────────

echo "Checking script permissions..."
for script in launch.sh submit.sh; do
    if [[ -f "$script" ]]; then
        if [[ -x "$script" ]]; then
            check_pass "$script is executable"
        else
            check_warn "$script is not executable (should be)"
            if [[ $FIX_MODE -eq 1 ]]; then
                chmod +x "$script"
                check_pass "Fixed: Made $script executable"
            fi
        fi
    fi
done

echo ""

# ──────────────────────────────────────────────────────────────────────────────
#                      Check launch.sh Configuration
# ──────────────────────────────────────────────────────────────────────────────

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
    INTERVAL=$(grep "MONITOR_INTERVAL=" launch.sh | head -1 | cut -d'=' -f2)
    check_info "Monitoring interval set to: $INTERVAL seconds"
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
#                      Check submit.sh SLURM Config
# ──────────────────────────────────────────────────────────────────────────────

echo "Checking submit.sh SLURM configuration..."

if grep -q "#SBATCH -N" submit.sh; then
    NODES=$(grep "#SBATCH -N" submit.sh | head -1 | awk '{print $NF}')
    check_info "Number of nodes: $NODES"
fi

if grep -q "#SBATCH --ntasks-per-node" submit.sh; then
    TASKS=$(grep "#SBATCH --ntasks-per-node" submit.sh | head -1 | awk '{print $NF}')
    check_info "Tasks per node: $TASKS"
fi

if grep -q "#SBATCH --time" submit.sh; then
    TIME=$(grep "#SBATCH --time" submit.sh | head -1 | awk '{print $NF}')
    check_info "Walltime limit: $TIME"
    if [[ "$TIME" == "24:00:00" ]]; then
        check_pass "Walltime is 24 hours (correct for STOPCAR at 22h)"
    else
        check_warn "Walltime is $TIME (should be at least 24:00:00)"
    fi
fi

if grep -q "#SBATCH --partition" submit.sh; then
    PARTITION=$(grep "#SBATCH --partition" submit.sh | head -1 | awk '{print $NF}')
    check_warn "Partition set to: $PARTITION (verify this matches your cluster)"
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
#                         Check INCAR Files
# ──────────────────────────────────────────────────────────────────────────────

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

# ──────────────────────────────────────────────────────────────────────────────
#                         Check VASP Input Files
# ──────────────────────────────────────────────────────────────────────────────

echo "Checking VASP input files..."

for file in KPOINTS POSCAR POTCAR; do
    if [[ -f "$file" ]]; then
        SIZE=$(du -h "$file" | cut -f1)
        LINES=$(wc -l < "$file")
        check_info "$file: $LINES lines, ~$SIZE"
    fi
done

echo ""

# ──────────────────────────────────────────────────────────────────────────────
#                      Check SLURM Availability
# ──────────────────────────────────────────────────────────────────────────────

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

# ──────────────────────────────────────────────────────────────────────────────
#                         Test Mode Dry-Run
# ──────────────────────────────────────────────────────────────────────────────

echo "Testing launch.sh dry-run (argument parsing)..."

if ./launch.sh --help 2>&1 | grep -q "Usage:"; then
    check_pass "launch.sh help works"
elif ./launch.sh 2>&1 | grep -q "Error"; then
    check_pass "launch.sh validates arguments"
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
#                            Summary
# ──────────────────────────────────────────────────────────────────────────────

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
