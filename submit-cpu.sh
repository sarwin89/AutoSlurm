#!/bin/bash
#SBATCH --job-name=SDC-7x
#SBATCH --partition=cpu
#SBATCH --output=VASP-7x.out
#SBATCH --error=VASP-7x.err
#SBATCH --nodes=10
#SBATCH --ntasks-per-node=24
#SBATCH --ntasks=240
#SBATCH --exclude=n12,n100,n[33-38]

# Always start from submission directory
cd $SLURM_SUBMIT_DIR || exit 1

# Load Intel compiler + MPI environment
source /etc/profile.d/modules.sh
module load compilers/intel2017/composer_xe_2017/default

# Create absolute-path machinefile
MACHINE_FILE=$SLURM_SUBMIT_DIR/nodes.$SLURM_JOBID

scontrol show hostname $SLURM_JOB_NODELIST > $MACHINE_FILE
sed -i "s/$/-ib/" $MACHINE_FILE

echo "Machinefile created at: $MACHINE_FILE"
cat $MACHINE_FILE

# Define VASP executable
VASP=/pfs/home/shobhana/softwares/VASP-6.2.1/vasp.6.2.1/bin/vasp_std

# Define MPI run command
MPI="mpiexec.hydra -genv I_MPI_FABRICS shm:ofa \
                    -genv I_MPI_DEVICE rdma \
                    -machinefile $MACHINE_FILE \
                    -np $SLURM_NTASKS"

# Loop over configurations
for d in AA AAX AB ABX AXB
do
    base="/pfs/home/shobhana/sarwin/bilayer-7x/$d"

    echo "Starting pristine SCF for $d"
    cd $base/prist-nsoc/scf || exit 1
    $MPI $VASP > scf.log

    echo "Starting relaxation for $d"
    cd $base/1def-nsoc/relax || exit 1
    $MPI $VASP > relax.log

    echo "Copying relaxed structure for $d"
    cd $base/1def-nsoc || exit 1
    ./rel_cp.sh

    echo "Starting defect SCF for $d"

    cd $base/1def-nsoc/scf || exit 1
    $MPI $VASP > scf.log
done

echo "All calculations completed."