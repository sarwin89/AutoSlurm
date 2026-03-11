# AutoSlurm

Bash-based automation for iterative VASP jobs on SLURM.

This version is built for a centralized layout:
- Keep automation scripts in one shared AutoSlurm directory.
- Keep job inputs and iteration folders in separate work directories.
- Monitor runtime using `squeue` (no `sacct` dependency for core flow).

## Quick Start (Centralized)

```bash
# 1) Paths
AUTOSLURM=/pfs/home/shobhana/sarwin/AutoSlurm
JOBDIR=/pfs/home/shobhana/sarwin/bilayer-7/test
LOGDIR=$AUTOSLURM/logs
VASP_EXE=/pfs/home/shobhana/softwares/VASP-6.2.1/vasp.6.2.1/bin/vasp_std

# 2) Ensure scripts are executable
chmod +x "$AUTOSLURM"/launch.sh "$AUTOSLURM"/setup-check.sh "$AUTOSLURM"/submit.sh "$AUTOSLURM"/reset-run.sh

# 3) Validate setup
# setup-check.sh supports --workdir and --submit-script (not --log-dir)
"$AUTOSLURM"/setup-check.sh --workdir "$JOBDIR"

# 4) Validate launch configuration
"$AUTOSLURM"/launch.sh --validate-only \
  --workdir "$JOBDIR" \
  --log-dir "$LOGDIR" \
  --vasp-exe "$VASP_EXE"

# 5) Optional clean restart
"$AUTOSLURM"/reset-run.sh --workdir "$JOBDIR" --log-dir "$LOGDIR" --yes

# 6) Run chain
"$AUTOSLURM"/launch.sh \
  --workdir "$JOBDIR" \
  --log-dir "$LOGDIR" \
  --name "AST-7r" \
  --max-iter 5 \
  --success-string "stopping structural energy minimisation" \
  --monitor-interval 120 \
  --vasp-exe "$VASP_EXE"
```

## Required Files

Place these in `JOBDIR`:
- `INCAR.start`
- `INCAR.cont`
- `KPOINTS`
- `POSCAR`
- `POTCAR`

During execution, AutoSlurm creates:
- `iteration-1`, `iteration-2`, ... inside `JOBDIR`
- chain logs in `LOGDIR` as `chain_<jobtag>_<timestamp>.log`

## Script Roles

- `launch.sh`
  - orchestrates iterations
  - submits each iteration via `sbatch`
  - monitors queue state via `squeue -h -j <jobid> -o "%T|%M"`
  - writes STOPCAR/LABORT by elapsed runtime
  - copies `CONTCAR -> POSCAR` and restart files for next iteration

- `submit.sh`
  - contains cluster-specific `#SBATCH` settings
  - loads modules
  - runs VASP through MPI
  - validates `VASP_EXE` early and exits clearly if missing

- `setup-check.sh`
  - checks required scripts and input files
  - checks SBATCH directives in submit script
  - confirms launcher `--validate-only` works

- `reset-run.sh`
  - removes iteration folders and chain/job logs for a clean rerun
  - supports external log directory via `--log-dir`

## CLI Reference

### launch.sh

```bash
launch.sh [options]

--workdir PATH          Required in centralized usage
--log-dir PATH          Chain log output directory (default: <autoslurm>/logs)
--submit-script PATH    Alternate submit script (default: <autoslurm>/submit.sh)
--vasp-exe PATH_OR_CMD  Override VASP executable passed to submit.sh
--continue-from N       Start iteration (default: 1)
--max-iter N            End iteration (default: 20)
--name PREFIX           SLURM job name prefix (default: VASP-calc)
--success-string TEXT   Required text in OUTCAR (optional)
--monitor-interval SEC  Poll interval in seconds (default: 1800)
--validate-only         Validate config and exit
```

### setup-check.sh

```bash
setup-check.sh [--workdir PATH] [--submit-script PATH] [--fix]
```

### reset-run.sh

```bash
reset-run.sh --workdir PATH [--log-dir PATH] [--yes]
```

## Monitoring

```bash
# queue state
squeue -j <jobid>

# live chain log
tail -f "$LOGDIR"/chain_$(basename "$JOBDIR")_*.log

# iteration outputs
ls -lah "$JOBDIR"/iteration-1
tail -n 50 "$JOBDIR"/iteration-1/OUTCAR
```

## Troubleshooting

### Unknown option: --log-dir (from setup-check.sh)
Use:
```bash
"$AUTOSLURM"/setup-check.sh --workdir "$JOBDIR"
```
`setup-check.sh` does not accept `--log-dir`.

### Job submitted but VASP fails immediately
If `iteration-N/vasp.log` shows `execvp error ... vasp_std (No such file or directory)`, set one of:
- `--vasp-exe /absolute/path/to/vasp_std` in `launch.sh`
- or `export VASP_EXE=/absolute/path/to/vasp_std` before launch

### Job runs but chain log is not moving
Check launcher process:
```bash
pgrep -af launch.sh
```
If missing, restart launch command. If present, verify `--monitor-interval` is not too large.

### STOPCAR/LABORT timing
Defaults in `launch.sh`:
- `STOPCAR_TIME=79200` (22h)
- `LABORT_TIME=82800` (23h)

These use `squeue` elapsed runtime (`%M`) and are applied while state is `RUNNING`.

## Notes

- `submit-cpu.sh` can remain as a known-good local reference.
- Main production path is now `launch.sh` + `submit.sh` + `setup-check.sh` + `reset-run.sh`.