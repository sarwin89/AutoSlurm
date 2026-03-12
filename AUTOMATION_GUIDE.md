# AutoSlurm Automation Guide

This document is the full operational reference. For a short setup path, use `README.md`.

## 1. Design

AutoSlurm is built for one shared script directory and many independent job directories.

```text
<autoslurm>/
  autoslurm-cli.sh
  launch.sh
  submit.sh
  setup-check.sh
  reset-run.sh
  logs/

<jobdir>/
  input|inputs|INPUT|INPUTS/
    INCAR.start
    INCAR.cont
    KPOINTS
    POSCAR
    POTCAR
  logs/
  iteration-1/
  iteration-2/
  ...
  POSCAR
  WAVECAR
  CHGCAR
```

Key behavior:
- `launch.sh` reads static inputs from the detected input folder.
- Runtime state is tracked in `<jobdir>` root (`POSCAR`, `WAVECAR`, `CHGCAR`).
- Every chain log line is written to both job-local logs and AutoSlurm mirror logs.

## 2. Script Responsibilities

### `autoslurm-cli.sh`
Interactive frontend that runs the full flow, asks for per-run node count, and submits `launch.sh` via 
ohup`.

### `setup-check.sh`
Checks scripts, input files, SBATCH directives, scheduler commands, and launcher validation.

### `launch.sh`
Orchestrates iteration folders, submission, monitoring, STOPCAR/LABORT writing, success checks, and carry-over.

### `reset-run.sh`
Cleans full runs or from a specific iteration onward.

### `submit.sh`
Cluster submit runner. Default node count is `5` (`#SBATCH -N 5`).

## 3. Input Folder Detection

If `--input-dir` is not passed, AutoSlurm checks in order:
1. `input`
2. `inputs`
3. `INPUT`
4. `INPUTS`

If none exist, it falls back to `<jobdir>/input` and fails with a clear message if files are missing.

## 4. Runtime Carry-Over Rules

For each successful iteration:
- `CONTCAR` is copied to `<jobdir>/POSCAR`
- `WAVECAR` and `CHGCAR` are copied to `<jobdir>/`

Next iteration uses those files.

Resume behavior:
- if `--continue-from > 1` and `<jobdir>/POSCAR` is missing,
- `launch.sh` seeds it from `iteration-(N-1)/CONTCAR` when available,
- otherwise from input `POSCAR`.

## 5. STOPCAR/LABORT Behavior

- At 22h elapsed runtime: write `LSTOP = .TRUE.` to `STOPCAR`
- At 23h elapsed runtime: append `LABORT = .TRUE.` to the same `STOPCAR` file
- There is no separate control-file workflow required for LABORT in this automation.

## 6. Monitoring Model

Queue state source:
- `squeue -h -j <jobid> -o "%T|%M"`

Elapsed parsing is base-10 safe (fixes the `08` token arithmetic issue).

Chain log check lines include OUTCAR progress snapshots when available, for example:
- `OUTCAR: Iteration 1( 8)`

## 7. Core Commands

### Wrapper run (recommended)

```bash
AUTOSLURM=/pfs/home/shobhana/sarwin/AutoSlurm
cd /pfs/home/shobhana/sarwin/bilayer-7/test
"$AUTOSLURM"/autoslurm-cli.sh
```

### Manual validate + run

```bash
AUTOSLURM=/pfs/home/shobhana/sarwin/AutoSlurm
JOBDIR=/pfs/home/shobhana/sarwin/bilayer-7/test

"$AUTOSLURM"/setup-check.sh --workdir "$JOBDIR"

"$AUTOSLURM"/launch.sh --validate-only \
  --workdir "$JOBDIR" \
  --nodes 5 \
  --vasp-exe /pfs/home/shobhana/softwares/VASP-6.2.1/vasp.6.2.1/bin/vasp_std

nohup "$AUTOSLURM"/launch.sh \
  --workdir "$JOBDIR" \
  --name "AST-7r" \
  --max-iter 5 \
  --nodes 5 \
  --monitor-interval 120 \
  --success-string "stopping structural energy minimisation" \
  --vasp-exe /pfs/home/shobhana/softwares/VASP-6.2.1/vasp.6.2.1/bin/vasp_std > "$JOBDIR"/logs/launcher_manual.log 2>&1 &
```

### Reset all

```bash
"$AUTOSLURM"/reset-run.sh --workdir "$JOBDIR" --yes
```

### Reset from iteration N

```bash
"$AUTOSLURM"/reset-run.sh --workdir "$JOBDIR" --from-iter 4 --yes
```

## 8. Option Reference

### `launch.sh`

```text
--workdir PATH
--input-dir PATH
--log-dir PATH
--mirror-log-dir PATH
--submit-script PATH
--nodes N
--vasp-exe PATH_OR_CMD
--continue-from N
--max-iter N
--name PREFIX
--success-string TEXT
--monitor-interval SEC
--validate-only
```

### `setup-check.sh`

```text
--workdir PATH
--input-dir PATH
--submit-script PATH
--log-dir PATH
--mirror-log-dir PATH
--fix
```

### `reset-run.sh`

```text
--workdir PATH
--from-iter N
--log-dir PATH
--mirror-log-dir PATH
--yes
```

## 9. Operational Notes

Background reliability:
- Wrapper uses 
ohup`, background `&`, and `disown`.
- In most clusters this survives terminal close.
- If login-node process cleanup is enforced by site policy, use `tmux/screen` or request a persistent launcher method.

SLURM target:
- Partition baseline is controlled in `submit.sh`.
- Node baseline is `5` in `submit.sh`, and can be overridden per run using `--nodes` (wrapper prompt or CLI).

## 10. Troubleshooting

### `execvp error on file vasp_std`
Use `--vasp-exe` with full executable path.

### Monitoring fails with `value too great for base`
Fixed in current `launch.sh` by base-10-safe elapsed conversion.

### No input folder found
Create one of: `input`, `inputs`, `INPUT`, `INPUTS` with required VASP files.

### Chain log stopped updating
Check launcher process:
```bash
pgrep -af launch.sh
```
If absent, relaunch using wrapper or manual 
ohup` command.