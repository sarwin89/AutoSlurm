#!/bin/bash
################################################################################
# submit.sh - VASP job runner for automated iteration chain
# Called by launch.sh for each iteration in an iteration-N directory.
################################################################################

# Keep SBATCH directives before any executable shell code.
# launch.sh overrides job-name/output/error via sbatch CLI options.
#SBATCH --partition=cpu
#SBATCH -N 8
#SBATCH --ntasks-per-node=24
#SBATCH --time=24:00:00
#SBATCH --error=job.%J.err
#SBATCH --output=job.%J.out
##SBATCH --exclusive

set -euo pipefail

# Load Intel compiler + MPI environment.
source /etc/profile.d/modules.sh
module load compilers/intel2017/composer_xe_2017/default

ulimit -c unlimited
ulimit -s unlimited

export OMP_NUM_THREADS=1
export MKL_NUM_THREADS=1

VASP_EXE="${VASP_EXE:-vasp_std}" #insert some vasp locator logic here

MACHINE_FILE="nodes.$SLURM_JOBID"
scontrol show hostname "$SLURM_JOB_NODELIST" > "$MACHINE_FILE"
sed -i "s/$/-ib/" "$MACHINE_FILE"

echo "$(date '+%Y-%m-%d %H:%M:%S')  Machinefile: $MACHINE_FILE"

MPI_CMD="mpiexec.hydra -genv I_MPI_FABRICS shm:ofa \
                       -genv I_MPI_DEVICE rdma \
                       -machinefile $MACHINE_FILE \
                       -np $SLURM_NTASKS"

echo "$(date '+%Y-%m-%d %H:%M:%S')  Starting VASP calculation in: $(pwd)"
echo "  Job ID:  $SLURM_JOBID"
echo "  Nodes:   $SLURM_NNODES"
echo "  Tasks:   $SLURM_NTASKS"
echo "  Command: $MPI_CMD $VASP_EXE"

if $MPI_CMD $VASP_EXE > vasp.log 2>&1; then
    VASP_EXIT=0
else
    VASP_EXIT=$?
fi

echo "$(date '+%Y-%m-%d %H:%M:%S')  VASP finished with exit code: $VASP_EXIT"

rm -f "$MACHINE_FILE" STOPCAR LABORT 2>/dev/null || true

exit "$VASP_EXIT"
