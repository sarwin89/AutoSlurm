# AutoSlurm

AutoSlurm is a Bash automation toolkit for iterative VASP jobs on SLURM.

Current model:
- scripts live in one shared AutoSlurm directory
- each calculation uses its own work directory
- canonical input files are in `<workdir>/input`
- iteration folders are created directly under `<workdir>`
- chain logs are written to `<workdir>/logs` and mirrored to `<autoslurm>/logs`

## Main Scripts

- `autoslurm-cli.sh`: interactive frontend wrapper (recommended for daily use)
- `launch.sh`: iteration orchestrator + queue monitor (`squeue` based)
- `submit.sh`: SLURM submit runner for VASP
- `setup-check.sh`: setup validator
- `reset-run.sh`: cleanup helper (full or from iteration onward)

## Required Workdir Layout

```text
<workdir>/
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
```

Notes:
- `input/POSCAR` is the initial seed.
- runtime POSCAR is maintained at `<workdir>/POSCAR` during chain progress.
- `WAVECAR` and `CHGCAR` are stored in `<workdir>` between iterations.

## Quick Start (Interactive Wrapper)

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

Wrapper flow:
1. uses current directory as `workdir`
2. asks default or custom AutoSlurm + VASP locations
3. asks VASP binary variant (`vasp_std`, `vasp_ncl`, `vasp_gam`, custom)
4. optional reset (none, all, or from iteration N)
5. runs `setup-check.sh`
6. runs `launch.sh --validate-only`
7. collects job name, iteration range, success string, monitor interval
8. submits with `nohup` and exits while run continues in background

## Non-Interactive Usage

```bash
AUTOSLURM=/pfs/home/shobhana/sarwin/AutoSlurm
JOBDIR=/pfs/home/shobhana/sarwin/bilayer-7/test

"$AUTOSLURM"/setup-check.sh \
  --workdir "$JOBDIR" \
  --input-dir "$JOBDIR/input"

"$AUTOSLURM"/launch.sh --validate-only \
  --workdir "$JOBDIR" \
  --input-dir "$JOBDIR/input" \
  --log-dir "$JOBDIR/logs" \
  --mirror-log-dir "$AUTOSLURM/logs" \
  --vasp-exe /pfs/home/shobhana/softwares/VASP-6.2.1/vasp.6.2.1/bin/vasp_std

"$AUTOSLURM"/launch.sh \
  --workdir "$JOBDIR" \
  --input-dir "$JOBDIR/input" \
  --log-dir "$JOBDIR/logs" \
  --mirror-log-dir "$AUTOSLURM/logs" \
  --name "AST-7r" \
  --continue-from 1 \
  --max-iter 5 \
  --success-string "stopping structural energy minimisation" \
  --monitor-interval 120 \
  --vasp-exe /pfs/home/shobhana/softwares/VASP-6.2.1/vasp.6.2.1/bin/vasp_std
```

## Reset Options

Full reset:
```bash
"$AUTOSLURM"/reset-run.sh \
  --workdir "$JOBDIR" \
  --log-dir "$JOBDIR/logs" \
  --mirror-log-dir "$AUTOSLURM/logs" \
  --yes
```

Reset from iteration N onward:
```bash
"$AUTOSLURM"/reset-run.sh \
  --workdir "$JOBDIR" \
  --log-dir "$JOBDIR/logs" \
  --mirror-log-dir "$AUTOSLURM/logs" \
  --from-iter 3 \
  --yes
```

## Monitoring

```bash
# queue
squeue -j <jobid>
squeue -h -j <jobid> -o "%T|%M|%L|%N"

# chain logs (primary + mirror)
tail -f "$JOBDIR"/logs/chain_*.log
tail -f "$AUTOSLURM"/logs/chain_$(basename "$JOBDIR")_*.log

# current OUTCAR progress
# launch logs now include grep-based progress markers like:
# OUTCAR: Iteration 1( 4)
```

## Launch CLI Reference

```text
launch.sh [options]

--workdir PATH
--input-dir PATH              default: <workdir>/input
--log-dir PATH                default: <workdir>/logs
--mirror-log-dir PATH         default: <autoslurm>/logs
--submit-script PATH          default: <autoslurm>/submit.sh
--vasp-exe PATH_OR_CMD
--continue-from N             default: 1
--max-iter N                  default: 20
--name PREFIX                 default: VASP-calc
--success-string TEXT         optional
--monitor-interval SEC        default: 1800
--validate-only
```

## setup-check CLI Reference

```text
setup-check.sh [--workdir PATH] [--input-dir PATH] [--submit-script PATH]
               [--log-dir PATH] [--mirror-log-dir PATH] [--fix]
```

## Troubleshooting

### `Unknown option: --log-dir` on old setup-check
You are using an older script version. Pull latest AutoSlurm scripts.

### `execvp error ... vasp_std (No such file or directory)`
Set `--vasp-exe` to the full executable path or ensure module path exports VASP on compute nodes.

### Job is running but chain log is static
Check if launcher process still exists:
```bash
pgrep -af launch.sh
```
Also verify monitor interval is not too high.

### CPU vs GPU partition
`submit.sh` partition controls submission target. Keep `#SBATCH --partition=cpu` if CPU-only is desired.