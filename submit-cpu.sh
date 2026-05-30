#!/bin/bash
#SBATCH --job-name=vasp-job          # Replace with your job name
#SBATCH --partition=cpu              # Replace with your partition name
#SBATCH --output=job.%j.out          # %j will be replaced with job ID
#SBATCH --error=job.%j.err           # %j will be replaced with job ID
#SBATCH --nodes=8                    # Number of nodes
#SBATCH --ntasks-per-node=24         # Tasks per node
#SBATCH --ntasks=192                 # Total tasks (nodes * ntasks-per-node)

# Always start from submission directory
cd $SLURM_SUBMIT_DIR || exit 1

# Load Intel compiler + MPI environment (adjust module names for your cluster)
source /etc/profile.d/modules.sh
module load compilers/intel2017/composer_xe_2017/default  # Update if needed

# Create absolute-path machinefile
MACHINE_FILE=$SLURM_SUBMIT_DIR/nodes.$SLURM_JOBID

scontrol show hostname $SLURM_JOB_NODELIST > $MACHINE_FILE
sed -i "s/$/-ib/" $MACHINE_FILE  # Adjust suffix if needed for your interconnect

echo "Machinefile created at: $MACHINE_FILE"
cat $MACHINE_FILE

# Define VASP executable (update path to your VASP binary)
VASP=/path/to/your/vasp/bin/vasp_std  # Replace with actual path

# Define MPI run command (adjust for your MPI implementation)
MPI="mpiexec.hydra -genv I_MPI_FABRICS shm:ofa \
                    -genv I_MPI_DEVICE rdma \
                    -machinefile $MACHINE_FILE \
                    -np $SLURM_NTASKS"

# Run VASP
echo "Starting VASP calculation..."
$MPI $VASP > vasp.log

echo "VASP calculation completed."