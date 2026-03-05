# VASP Iteration Chain Automation Guide

Complete automated solution for running iterative VASP calculations with proper queue handling, STOPCAR writing, and convergence checking.

## Overview

The automation consists of two main scripts:

- **`launch.sh`** - Orchestrator that manages the entire iteration chain
- **`submit.sh`** - VASP job runner that gets submitted to SLURM

### Key Features

✓ **Queue-aware STOPCAR/LABORT timing** - Detects actual compute time (excluding queue) and writes STOPCAR at 22h, LABORT at 23h  
✓ **Automatic iteration foldering** - Creates `iteration-N` folders with proper INCAR management  
✓ **Job monitoring & logging** - Monitors status every 30-60 min, logs to timestamped chain log  
✓ **Checkpoint file handling** - Automatically copies WAVECAR/CHGCAR between iterations  
✓ **Success string validation** - Checks OUTCAR for user-defined convergence string  
✓ **Resume capability** - Can restart from any iteration  

---

## Setup

### Prerequisites

In your base working directory, you need:

```
.
├── launch.sh          # Main orchestrator (provided)
├── submit.sh          # VASP job runner (provided)
├── INCAR.start        # INCAR for first iteration
├── INCAR.cont         # INCAR for iterations 2+
├── KPOINTS            # k-points file
├── POSCAR             # Initial structure
└── POTCAR             # Pseudopotential file
```

### File Descriptions

#### INCAR.start vs INCAR.cont

- **INCAR.start**: Used only for iteration 1. Typically includes full SCF setup from scratch
- **INCAR.cont**: Used for iterations 2 and beyond. Should enable `ISTART=1` to read WAVECAR/CHGCAR from previous iteration

**INCAR.start** (first iteration - fresh start):
```
! First iteration - fresh start without restart files
SYSTEM = MoS2 Bilayer Structure

! Electronic relaxation
PREC   = Accurate
ENCUT  = 400
ISTART = 0           ! Fresh start (no WAVECAR)
ICHARG = 2           ! Build charge density from scratch

! Ionic relaxation
IBRION = 2           ! CG relaxation algorithm
NSW    = 100         ! Max 100 ionic steps
POTIM  = 0.5         ! Timestep for ionic motion
ISIF   = 3           ! Relax ions and cell volume
EDIFFG = -0.01       ! Energy convergence criterion

! SCF convergence
NELM   = 100         ! Max 100 electronic steps
NELMIN = 4
EDIFF  = 1e-04       ! SCF convergence

! Output
LWAVE  = .TRUE.      ! Write WAVECAR
LCHARG = .TRUE.      ! Write CHGCAR
NWRITE = 2

! Smearing for metals (adjust for your system)
ISMEAR = 1           ! Methfessel-Paxton order 1
SIGMA  = 0.05        ! Smearing width

! Parallelization
NPAR   = 4
KPAR   = 1
```

**INCAR.cont** (iterations 2+ - continue from checkpoint):
```
! Continuation iteration - read from previous WAVECAR
SYSTEM = MoS2 Bilayer Structure

! Electronic relaxation
PREC   = Accurate
ENCUT  = 400
ISTART = 1           ! Read WAVECAR from previous iteration
ICHARG = 1           ! Read charge density from CHGCAR
ICHARGE = 0          ! Neutral charge

! Ionic relaxation (same as start, or tighter)
IBRION = 2           ! CG algorithm
NSW    = 100         ! Max 100 ionic steps per iteration
POTIM  = 0.5         ! Timestep
ISIF   = 3           ! Relax ions and cell
EDIFFG = -0.01       ! Convergence check

! SCF convergence
NELM   = 100
NELMIN = 4
EDIFF  = 1e-04

! Output
LWAVE  = .TRUE.      ! Overwrite WAVECAR for next iteration
LCHARG = .TRUE.      ! Overwrite CHGCAR for next iteration
NWRITE = 2

! Smearing
ISMEAR = 1
SIGMA  = 0.05

! Parallelization
NPAR   = 4
KPAR   = 1
```

**Key differences:**
- `ISTART = 1` to read from WAVECAR
- `ICHARG = 1` to read from CHGCAR
- Remove `ICHARGE = 2` (not needed when reading charge)

### SLURM Configuration

Edit the SBATCH directives in `submit.sh` to match your cluster:

```bash
#SBATCH --partition=standard    # Your partition name
#SBATCH --qos=small             # Your QoS
#SBATCH -N 2                    # Number of nodes
#SBATCH --ntasks-per-node=40    # Tasks per node
#SBATCH --time=24:00:00         # Total walltime (must be 24+ hours)
```

The scripts assume you have loaded the Intel compiler and MPI modules. Verify the module commands in `submit.sh` match your cluster.

---

## Usage

### Basic Usage

```bash
./launch.sh --name "MoS2-relax" \
            --success-string "reached structural accuracy" \
            --continue-from 1 \
            --max-iter 20 \
            --monitor-interval 1800
```

### Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `--name PREFIX` | `VASP-calc` | Job name prefix (becomes `NAME-iter-N` in SLURM) |
| `--success-string TEXT` | `reached structural accuracy` | String to search for in OUTCAR to mark iteration as successful |
| `--continue-from N` | `1` | Starting iteration number |
| `--max-iter M` | `20` | Maximum iteration number |
| `--monitor-interval SECS` | `1800` | How often to check job status (30 min = 1800 s) |

### Common Examples

**First-time run with 10 iterations:**
```bash
nohup ./launch.sh --name "bil-27-relax" \
                  --max-iter 10 \
                  --success-string "reached structural accuracy" > launch.log 2>&1 &
```

**Resume from iteration 5:**
```bash
./launch.sh --continue-from 5 --max-iter 20
```

**Fast monitoring (every 10 min) for SCF runs:**
```bash
./launch.sh --name "scf" \
            --success-string "total energy" \
            --monitor-interval 600 \
            --max-iter 5
```

---

## How It Works

### Iteration Flow

```
For each iteration N:
  1. Create iteration-N/ folder
  2. Copy INCAR.start (if N=1) or INCAR.cont (if N>1) as INCAR
  3. Copy POSCAR, KPOINTS, POTCAR
  4. Copy WAVECAR, CHGCAR from base (if exist)
  5. Submit job: sbatch --chdir=iteration-N --job-name=NAME-iter-N submit.sh
  6. Poll job status every MONITOR_INTERVAL seconds
  7. At 22h actual runtime: write STOPCAR with LSTOP=.TRUE.
  8. At 23h actual runtime: write LABORT=.TRUE. to STOPCAR
  9. When job finishes:
     - Check OUTCAR for SUCCESS_STRING
     - If found: copy CONTCAR→POSCAR, WAVECAR/CHGCAR→base, advance to N+1
     - If not found: stop with error
```

### STOPCAR/LABORT Timing

The scripts track **actual compute time** (not queue time):

- `sacct` is queried every `MONITOR_INTERVAL` to get elapsed time
- At **22 hours** of actual running: `STOPCAR` with `LSTOP = .TRUE.` is written
- At **23 hours** of actual running: `LABORT = .TRUE.` is added to STOPCAR
- VASP terminates gracefully via LSTOP, or LABORT as final fallback

This ensures the next iteration has time to start before the 24h hard limit.

### Job Monitoring & Logging

All activity is logged to a timestamped file: `chain_YYYYMMDD_HHMMSS.log`

Example log excerpt:
```
[2026-03-04 14:30:15]  ═════════════════════════════════════════════════════════════
[2026-03-04 14:30:15]  VASP Chain Automation Started
[2026-03-04 14:30:15]  Base directory:    /home/user/MoS2
[2026-03-04 14:30:15]  Iterations:        1 → 20
[2026-03-04 14:30:15]  Job name prefix:   MoS2-relax
[2026-03-04 14:30:15]  Success string:    reached structural accuracy
[2026-03-04 14:30:15]  ═════════════════════════════════════════════════════════════
[2026-03-04 14:30:16]  [ITER-1]  ────────────────────────────────────────────────
[2026-03-04 14:30:16]  [ITER-1]  Preparing iteration 1 of 20
[2026-03-04 14:30:18]  [ITER-1]  Copied input files (INCAR, POSCAR, KPOINTS, POTCAR)
[2026-03-04 14:30:19]  [ITER-1]  Submitted → Job ID: 12345678
[2026-03-04 14:30:20]  [ITER-1]  Starting job monitoring
[2026-03-04 14:35:20]  [ITER-1]  [Check 1] Status: PENDING | Elapsed: 00:00:04
[2026-03-04 14:40:23]  [ITER-1]  [Check 2] Status: RUNNING | Elapsed: 00:05:07
...
[2026-03-04 14:30:15]  [ITER-1]  ✓ Written STOPCAR (LSTOP = .TRUE.) at 22:00:34
```

### Success String Checking

After each job completes, the script searches `iteration-N/OUTCAR` for the success string:

**For relaxations:**
```bash
./launch.sh --success-string "reached structural accuracy"
```

**For SCF calculations:**
```bash
./launch.sh --success-string "total energy(sigma"
```

**For band structure:**
```bash
./launch.sh --success-string "total energy"
```

If the string is not found, the chain **stops** and logs the error.

---

## Troubleshooting

### Job never starts (stays PENDING)

The job is in the queue. The script will wait. Monitor with:
```bash
squeue -j <job-id>
```

### STOPCAR/LABORT not written

Check:
1. Job is actually running (status = RUNNING)
2. Iteration folder has proper permissions
3. Check chain log for which check found the condition

### "Success string not found" error

1. Verify the success string matches your calculation type
2. Check `iteration-N/OUTCAR` manually to find the actual completion message
3. Use `--success-string "your-string"` with the correct text

### Job status shows COMPLETED but no OUTCAR

This is a job crash. Check:
- `iteration-N/job.*.err` for error messages
- `iteration-N/job.*.out` for VASP stdout
- Module loading in `submit.sh`

### Wrong INCAR being used

1. Verify files exist: `ls INCAR.start INCAR.cont`
2. Check first few lines are copied to `iteration-1/INCAR`
3. For iterations 2+, check `iteration-N/INCAR` starts with correct settings

### WAVECAR/CHGCAR not being copied

1. After iteration 1 completes, verify files exist: `ls iteration-1/WAVECAR iteration-1/CHGCAR`
2. Check base directory for copied files: `ls WAVECAR CHGCAR`
3. If missing, VASP didn't write them (check ISTART in INCAR.start)

---

## Advanced Usage

### Running in Background

```bash
nohup ./launch.sh --name "long-calc" --max-iter 50 > launch.log 2>&1 &
```

Then monitor:
```bash
tail -f launch.log
```

### Multiple Chains

Run different calculations in separate directories:
```bash
/path/to/relax/$ nohup ./launch.sh --name "relax" --max-iter 20 &
/path/to/scf/$ nohup ./launch.sh --name "scf" --max-iter 5 &
```

Each creates its own `chain_*.log`.

### Custom Monitor Interval

For **fast-converging systems** that finish < 1 hour per iter:
```bash
./launch.sh --monitor-interval 300    # Check every 5 minutes
```

For **slow systems** to reduce system load:
```bash
./launch.sh --monitor-interval 3600   # Check every 1 hour
```

### Partial Restart After Failure

If iteration 5 fails, fix the issue and restart:
```bash
cd iteration-5/
# Fix POSCAR or INCAR as needed
cd ..
./launch.sh --continue-from 5    # Will reuse iteration-5 folder or create new one
```

Actually, to be safer, rename the failed folder and restart:
```bash
mv iteration-5 iteration-5-failed
./launch.sh --continue-from 5    # Creates fresh iteration-5
```

---

## Performance & Resource Tips

### MPI Settings in submit.sh

The scripts use `mpiexec.hydra` based on the tested `submit-cpu.sh`:
```bash
MPI_CMD="mpiexec.hydra -genv I_MPI_FABRICS shm:ofa \
                       -genv I_MPI_DEVICE rdma \
                       -machinefile $MACHINE_FILE \
                       -np $SLURM_NTASKS"
```

Adjust if your cluster uses different MPI:
- **OpenMPI**: Use `mpirun -np $SLURM_NTASKS`
- **Different interconnect**: Change `I_MPI_FABRICS` and `I_MPI_DEVICE`

### Optimizing Iteration Timing

For relaxations that converge quickly:
- Use smaller `--monitor-interval` (e.g., 600s)
- Use smaller `NSW` in INCAR to keep iterations short
- Use smaller `--max-iter` and increase later if needed

### Disk Space

Iterations create large DOSCAR/IBZKPT files. Optional cleanup in each iteration-N:
```bash
rm -f iteration-N/DOSCAR iteration-N/IBZKPT
```

Add to `submit.sh` after VASP finishes if needed.

---

## Files Generated

### Per Iteration

```
iteration-N/
├── INCAR                 # Input file (copied from INCAR.start or INCAR.cont)
├── POSCAR               # Atomic positions input
├── KPOINTS              # k-point mesh
├── POTCAR               # Pseudopotentials
├── CONTCAR              # Output atomic positions
├── OUTCAR               # Main output (checked for success string)
├── job.JOBID.out        # SLURM stdout
├── job.JOBID.err        # SLURM stderr
├── STOPCAR              # Written by launch.sh at 22h/23h
├── WAVECAR              # Wavefunction restart (copied in from base)
├── CHGCAR               # Charge density restart (copied in from base)
└── [other VASP outputs...]
```

### Base Directory

```
.
├── POSCAR               # Updated after each iteration
├── WAVECAR              # Copied from latest iteration
├── CHGCAR               # Copied from latest iteration
└── chain_YYYYMMDD_HHMMSS.log   # Timestamped chain log
```

---

## Summary

1. **Prepare**: INCAR.start, INCAR.cont, KPOINTS, POSCAR, POTCAR
2. **Configure**: Edit `submit.sh` for SLURM directives (partition, QoS, nodes, etc.)
3. **Run**: `./launch.sh --name "yourjob" --success-string "your string"`
4. **Monitor**: `tail -f chain_*.log` or `squeue -u $USER`
5. **Results**: Check `iteration-N/OUTCAR` and copied POSCAR/WAVECAR/CHGCAR in base

The scripts handle everything else: iterations, queue waiting, STOPCAR timing, success checking, and restart file management.
