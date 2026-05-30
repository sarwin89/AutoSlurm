#!/bin/bash
#SBATCH --partition=cpu
#SBATCH -N 4
#SBATCH --ntasks-per-node=24
#SBATCH --time=24:00:00

exec "${VASP_EXE:-vasp_std}"
