# AutoSlurm Automation Guide

## Scope

This guide documents the AutoSlurm workflow.

## Architecture

AutoSlurm directory:

```text
<autoslurm>/
  autoslurm-cli.sh
  launch.sh
  submit.sh
  setup-check.sh
  reset-run.sh
  logs/
```

Job directory:

```text
<jobdir>/
  input/
    INCAR.start
    INCAR.cont
    KPOINTS
    POSCAR
    POTCAR
  logs/
  iteration-1/
  iteration-2/
  ...
  POSCAR      # runtime carry-forwards created by launch.sh
  WAVECAR 
  CHGCAR 
```

## Script Responsibilities

### autoslurm-cli.sh

Interactive frontend:
1. Uses current directory as jobdir
2. Selects default/custom AutoSlurm + VASP locations
3. Chooses VASP binary variant (`std`, `ncl`, `gam`)
4. Optionally resets (none, all, from-iteration)
5. Runs setup-check
6. Runs launch validation
7. Prompts launch settings
8. Submits with `nohup`, prints PID/log paths, exits

### launch.sh

Core script:
- validates paths/options
- reads canonical inputs from `<jobdir>/input`
- creates `iteration-N` directories under `<jobdir>`
- submits each iteration via `sbatch`
- monitors state/time with `squeue -h -j <jobid> -o "%T|%M"`
- writes STOPCAR with LSTOP at 22h and LABORT at 23h while RUNNING
- logs check lines to both:
  - primary: `<jobdir>/logs`
  - mirror: `<autoslurm>/logs`
- includes OUTCAR grep progress in monitor lines
- promotes `CONTCAR` to `<jobdir>/POSCAR` for next iteration
- copies `WAVECAR/CHGCAR` back to `<jobdir>`

### setup-check.sh

Validation helper:
- checks required scripts
- checks required input files in `<jobdir>/input`
- checks submit SBATCH directives and scheduler tools
- validates `launch.sh --validate-only` for current config

### reset-run.sh

Cleanup helper:
- full reset: removes all iterations/logs and runtime carry files (`POSCAR`, `WAVECAR`, `CHGCAR`)
- partial reset: removes iterations from `--from-iter N` onward plus chain logs
- cleans both primary and mirror log locations

### submit.sh

SLURM runner:
- cluster-specific SBATCH configuration
- module loading
- VASP executable precheck (`VASP_EXE`)
- MPI launch + cleanup

## Standard Operating Procedure

```bash
AUTOSLURM=/pfs/home/shobhana/sarwin/AutoSlurm
cd /pfs/home/shobhana/sarwin/bilayer-7/test

chmod +x "$AUTOSLURM"/autoslurm-cli.sh \
         "$AUTOSLURM"/launch.sh \
         "$AUTOSLURM"/setup-check.sh \
         "$AUTOSLURM"/submit.sh \
         "$AUTOSLURM"/reset-run.sh

"$AUTOSLURM"/autoslurm-cli.sh
```

## Manual Procedure (No Wrapper)

```bash
AUTOSLURM=/pfs/home/shobhana/sarwin/AutoSlurm
JOBDIR=/pfs/home/shobhana/sarwin/bilayer-7/test
INPUTDIR=$JOBDIR/input
LOGDIR=$JOBDIR/logs
MIRROR=$AUTOSLURM/logs
VASP_EXE=/pfs/home/shobhana/softwares/VASP-6.2.1/vasp.6.2.1/bin/vasp_std

"$AUTOSLURM"/setup-check.sh \
  --workdir "$JOBDIR" \
  --input-dir "$INPUTDIR" \
  --log-dir "$LOGDIR" \
  --mirror-log-dir "$MIRROR"

"$AUTOSLURM"/launch.sh --validate-only \
  --workdir "$JOBDIR" \
  --input-dir "$INPUTDIR" \
  --log-dir "$LOGDIR" \
  --mirror-log-dir "$MIRROR" \
  --vasp-exe "$VASP_EXE"

nohup "$AUTOSLURM"/launch.sh \
  --workdir "$JOBDIR" \
  --input-dir "$INPUTDIR" \
  --log-dir "$LOGDIR" \
  --mirror-log-dir "$MIRROR" \
  --name "AST-7r" \
  --continue-from 1 \
  --max-iter 5 \
  --success-string "stopping structural energy minimisation" \
  --monitor-interval 120 \
  --vasp-exe "$VASP_EXE" > "$LOGDIR"/launcher_manual.log 2>&1 &
```

## Option Summary

### launch.sh

```text
--workdir PATH
--input-dir PATH
--log-dir PATH
--mirror-log-dir PATH
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
--input-dir PATH
--submit-script PATH
--log-dir PATH
--mirror-log-dir PATH
--fix
```

### reset-run.sh

```text
--workdir PATH
--from-iter N
--log-dir PATH
--mirror-log-dir PATH
--yes
```

## Logging Model

Primary chain logs:
- `<jobdir>/logs/chain_<jobtag>_<timestamp>.log`

Mirror chain logs:
- `<autoslurm>/logs/chain_<jobtag>_<timestamp>.log`

Launcher wrapper logs:
- `<jobdir>/logs/launcher_<timestamp>.log`

Each monitor check can include an OUTCAR snapshot, e.g.:
- `OUTCAR: Iteration 1( 4)`

## Reset Strategy

Use full reset when starting a clean chain from scratch:
- removes all iteration folders
- removes chain/launcher logs
- removes runtime carry files (`POSCAR`, `WAVECAR`, `CHGCAR`)

Use `--from-iter N` when re-running tail iterations:
- removes only `iteration-N` and above
- keeps prior iteration history and runtime carry files

## Monitoring and Diagnostics

Queue:
```bash
squeue -j <jobid>
squeue -h -j <jobid> -o "%T|%M|%L|%N"
```

Logs:
```bash
tail -f <jobdir>/logs/chain_*.log
tail -f <autoslurm>/logs/chain_<jobtag>_*.log
```

Process check:
```bash
pgrep -af launch.sh
```

Iteration status:
```bash
ls -lah <jobdir>/iteration-1
tail -n 50 <jobdir>/iteration-1/OUTCAR
tail -n 50 <jobdir>/iteration-1/vasp.log
```

## Known Issues and Fixes

### `execvp error on file vasp_std`
Set `--vasp-exe` to full path or export `VASP_EXE` before launch.

### setup-check unknown option in old script
Use latest AutoSlurm scripts; new setup-check supports input/log/mirror options.

### Chain log appears stale
Check launcher process and monitor interval; if launcher is stopped, re-submit wrapper/manual launch.

## Operational Baseline

Observed working baseline:
- CPU submission via `submit.sh` partition settings
- `PENDING -> RUNNING` transitions visible in chain logs
- job monitoring stable with `squeue`
- wrapper submission detaches via `nohup`