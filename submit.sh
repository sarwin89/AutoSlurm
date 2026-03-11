#!/bin/bash
################################################################################
#   submit.sh - VASP job runner for automated iteration chain
#   Called by launch.sh for each iteration in a dedicated iteration-N folder
#   
#   Sets up MPI environment and runs VASP with proper module loading
#   based on tested submit-cpu.sh configuration
################################################################################

set -euo pipefail

# normalize line endings if file was checked out with CRLF
if grep -q $'\r' "${BASH_SOURCE[0]}" 2>/dev/null; then
    sed -i 's/\r$//' "${BASH_SOURCE[0]}" || true
fi

# ──────────────────────────────────────────────────────────────────────────────
#                         SBATCH CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────
# These will be overridden by launch.sh via sbatch --job-name, --output, etc.
#SBATCH --partition=standard
#SBATCH --qos=small
#SBATCH -N 2
#SBATCH --ntasks-per-node=24
#SBATCH --time=24:00:00
#SBATCH --gres=gpu:0            # explicitly request no GPUs so the job
#                              # cannot accidentally land on a GPU node
#SBATCH --constraint=cpu       # cluster-dependent; ensure only CPU nodes
#SBATCH --error=job.%J.err
#SBATCH --output=job.%J.out
#SBATCH --exclusive

# ──────────────────────────────────────────────────────────────────────────────
#                       ENVIRONMENT SETUP
# ──────────────────────────────────────────────────────────────────────────────

# Load Intel compiler + MPI (based on submit-cpu.sh which is tested working)
source /etc/profile.d/modules.sh
module load compilers/intel2017/composer_xe_2017/default

# Ulimits
ulimit -c unlimited
ulimit -s unlimited

# MPI/OpenMP threading
export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

# ──────────────────────────────────────────────────────────────────────────────
#                      VASP EXECUTABLE & MPI SETUP
#                      (Based on submit-cpu.sh structure)
# ──────────────────────────────────────────────────────────────────────────────

VASP_EXE="vasp_std"

# Create machinefile from SLURM node list
MACHINE_FILE="nodes.$SLURM_JOBID"
scontrol show hostname "$SLURM_JOB_NODELIST" > "$MACHINE_FILE"
sed -i "s/$/-ib/" "$MACHINE_FILE"

echo "$(date '+%Y-%m-%d %H:%M:%S')  Machinefile: $MACHINE_FILE"

# MPI command setup (from submit-cpu.sh)
MPI_CMD="mpiexec.hydra -genv I_MPI_FABRICS shm:ofa \
                       -genv I_MPI_DEVICE rdma \
                       -machinefile $MACHINE_FILE \
                       -np $SLURM_NTASKS"

# ──────────────────────────────────────────────────────────────────────────────
#                           RUN VASP
# ──────────────────────────────────────────────────────────────────────────────

echo "$(date '+%Y-%m-%d %H:%M:%S')  Starting VASP calculation in: $(pwd)"
echo "  Job ID:  $SLURM_JOBID"
echo "  Nodes:   $SLURM_NNODES"
echo "  Tasks:   $SLURM_NTASKS"
echo "  Command: $MPI_CMD $VASP_EXE"

# capture VASP stdout/stderr in a separate log so it's easy to monitor
# (VASP still writes OUTCAR and other files as usual)
$MPI_CMD $VASP_EXE > vasp.log 2>&1
VASP_EXIT=$?

# vasp.log will be located in the iteration folder; you may tail it
# if the job is running or inspect after completion.

echo "$(date '+%Y-%m-%d %H:%M:%S')  VASP finished with exit code: $VASP_EXIT"

# ──────────────────────────────────────────────────────────────────────────────
#                             CLEANUP
# ──────────────────────────────────────────────────────────────────────────────

rm -f "$MACHINE_FILE" STOPCAR LABORT 2>/dev/null || true

exit $VASP_EXIT