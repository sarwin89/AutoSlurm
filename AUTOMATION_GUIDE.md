# AutoSlurm Automation Guide

## Purpose

This guide describes the current centralized AutoSlurm workflow (validated on March 11, 2026):
- scripts live in one shared AutoSlurm directory
- each calculation has its own work directory with VASP inputs and iteration folders
- logs can be written to a shared log directory
- runtime monitoring uses `squeue`

## Directory Model

Example:

```text
/pfs/home/shobhana/sarwin/AutoSlurm/
  launch.sh
  submit.sh
  setup-check.sh
  reset-run.sh
  logs/

/pfs/home/shobhana/sarwin/bilayer-7/test/
  INCAR.start
  INCAR.cont
  KPOINTS
  POSCAR
  POTCAR
  iteration-1/
  iteration-2/
  ...
```

## One-Time Cluster Configuration

Edit `submit.sh` for your cluster:
- `#SBATCH --partition=...`
- `#SBATCH -N ...`
- `#SBATCH --ntasks-per-node=...`
- `#SBATCH --time=24:00:00`
- module loads required for MPI and VASP

`submit.sh` now validates `VASP_EXE` before launching MPI and fails with exit code `127` if not found.

## Inputs Required Per Work Directory

Each `--workdir` must contain:
- `INCAR.start`
- `INCAR.cont`
- `KPOINTS`
- `POSCAR`
- `POTCAR`

Optional restart files used automatically:
- `WAVECAR`
- `CHGCAR`

## Commands (Recommended Flow)

```bash
AUTOSLURM=/pfs/home/shobhana/sarwin/AutoSlurm
JOBDIR=/pfs/home/shobhana/sarwin/bilayer-7/test
LOGDIR=$AUTOSLURM/logs
VASP_EXE=/pfs/home/shobhana/softwares/VASP-6.2.1/vasp.6.2.1/bin/vasp_std

chmod +x "$AUTOSLURM"/launch.sh "$AUTOSLURM"/setup-check.sh "$AUTOSLURM"/submit.sh "$AUTOSLURM"/reset-run.sh

# setup-check supports --workdir and --submit-script only
"$AUTOSLURM"/setup-check.sh --workdir "$JOBDIR"

"$AUTOSLURM"/launch.sh --validate-only \
  --workdir "$JOBDIR" \
  --log-dir "$LOGDIR" \
  --vasp-exe "$VASP_EXE"

"$AUTOSLURM"/reset-run.sh --workdir "$JOBDIR" --log-dir "$LOGDIR" --yes

"$AUTOSLURM"/launch.sh \
  --workdir "$JOBDIR" \
  --log-dir "$LOGDIR" \
  --name "AST-7r" \
  --max-iter 5 \
  --success-string "stopping structural energy minimisation" \
  --monitor-interval 120 \
  --vasp-exe "$VASP_EXE"
```

## Script Behavior

### launch.sh

1. Validates arguments and required input files in `--workdir`.
2. Creates `iteration-N` directory.
3. Copies input files (`INCAR`, `POSCAR`, `KPOINTS`, `POTCAR`).
4. Copies optional restart files (`WAVECAR`, `CHGCAR`) if present.
5. Submits `submit.sh` with `sbatch` and per-iteration job name/output.
6. Monitors with:
   - `squeue -h -j <jobid> -o "%T|%M"`
7. Writes:
   - `STOPCAR` at 22h (`79200s`) while `RUNNING`
   - `LABORT` at 23h (`82800s`) while `RUNNING`
8. After completion:
   - checks `OUTCAR`
   - validates success string when provided
   - requires non-empty `CONTCAR`
   - copies `CONTCAR -> POSCAR` in workdir
   - copies `WAVECAR/CHGCAR` back to workdir

### submit.sh

- Uses cluster `#SBATCH` defaults.
- Loads module environment.
- Accepts VASP executable by:
  - `--vasp-exe` from launch (exported as env var), or
  - pre-exported `VASP_EXE`, or
  - fallback `vasp_std` in PATH.
- Emits clear error if executable is not found.

### setup-check.sh

- Checks script presence and permissions.
- Checks workdir input files.
- Parses key SBATCH directives from submit script.
- Confirms launcher validation mode works.
- Notes `sacct` as optional; workflow itself is `squeue` based.

### reset-run.sh

- Cleans:
  - `iteration-*`
  - `chain_*.log`, `job.*.out`, `job.*.err` in workdir
  - matching job-tag logs in `--log-dir`
- Supports `--yes` for non-interactive cleanup.

## Option Reference

### launch.sh

```text
--workdir PATH
--log-dir PATH
--submit-script PATH
--vasp-exe PATH_OR_CMD
--continue-from N
--max-iter N
--name PREFIX
--success-string TEXT
--monitor-interval SEC
--validate-only
```

### setup-check.sh

```text
--workdir PATH
--submit-script PATH
--fix
```

### reset-run.sh

```text
--workdir PATH
--log-dir PATH
--yes
```

## Monitoring and Debugging

Queue and runtime:

```bash
squeue -j <jobid>
squeue -h -j <jobid> -o "%T|%M|%L|%N"
```

Log tail:

```bash
tail -f "$LOGDIR"/chain_$(basename "$JOBDIR")_*.log
```

Iteration files:

```bash
ls -lah "$JOBDIR"/iteration-1
tail -n 50 "$JOBDIR"/iteration-1/OUTCAR
tail -n 50 "$JOBDIR"/iteration-1/vasp.log
```

Launcher process check:

```bash
pgrep -af launch.sh
```

## Known Failure Modes and Fixes

### `Unknown option: --log-dir` from setup-check

Cause: `setup-check.sh` does not support `--log-dir`.

Fix:
```bash
"$AUTOSLURM"/setup-check.sh --workdir "$JOBDIR"
```

### `execvp error on file vasp_std (No such file or directory)`

Cause: VASP executable not available on compute node PATH.

Fix:
```bash
"$AUTOSLURM"/launch.sh ... --vasp-exe /absolute/path/to/vasp_std
```
or export before launch:
```bash
export VASP_EXE=/absolute/path/to/vasp_std
```

### Chain appears stuck while job is running

Check:
- launcher still running: `pgrep -af launch.sh`
- monitor interval value (`--monitor-interval`)
- queue status directly with `squeue`

## Practical Defaults

- `--monitor-interval 120` for short debugging runs
- `--monitor-interval 1800` for production
- `--max-iter 2` for smoke tests
- `--max-iter 20+` for full relax workflows

## Validation Snapshot (March 11, 2026)

Observed good behavior:
- setup-check passes for centralized path model
- launch validates with explicit workdir/logdir/vasp-exe
- job submits to CPU partition
- monitor shows state transitions (`PENDING -> RUNNING`)
- queue reflects expected running job

This is the current expected baseline for AutoSlurm.