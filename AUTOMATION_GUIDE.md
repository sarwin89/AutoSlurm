# AutoSlurm Automation Guide

This is the practical reference for the milestone Python CLI and the supported
legacy shell workflow.

## 1. Operating Model

AutoSlurm is built around one shared tool directory and many independent VASP
job directories.

```text
<autoslurm>/
  autoslurm-cli.sh
  launch.sh
  submit.sh
  setup-check.sh
  reset-run.sh
  logs/

<jobdir>/
  autoslurm.yaml
  input|inputs|INPUT|INPUTS/
  autoslurm-state.json
  autoslurm-events.jsonl
  logs/
  iteration-1/
  iteration-2/
  POSCAR
  WAVECAR
  CHGCAR
```

The Python CLI is additive. The shell scripts remain supported for existing
cluster workflows and automation.

## 2. Python CLI

Use `autoslurm` after installation, or `python -m autoslurm` from a source
checkout.

```bash
autoslurm init --workdir /path/to/job
autoslurm check --workdir /path/to/job
autoslurm doctor --workdir /path/to/job
autoslurm run --workdir /path/to/job --dry-run
autoslurm run --workdir /path/to/job
autoslurm status --workdir /path/to/job
autoslurm reset --workdir /path/to/job --from-iter 4
```

Command responsibilities:

- `init`: create a starter `autoslurm.yaml` in the job directory.
- `check`: validate config, input files, output paths, and submit script. It must
  not call `sbatch`.
- `doctor`: run `check`, then verify scheduler tools on `PATH`.
- `run --dry-run`: resolve config and show the planned chain without submitting.
- `run`: submit and monitor the iterative SLURM chain.
- `status`: summarize the latest state file, event log, and scheduler status.
- `reset`: remove generated iterations and logs, optionally from iteration `N`.

Common flags:

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
--dry-run
--from-iter N
```

CLI flags override config values.

## 3. Config Format

`autoslurm.yaml` is the default config file written by `init`. `autoslurm.toml`
is also discovered for legacy-friendly configs. Relative paths are resolved from
the job directory.

```toml
[paths]
input_dir = "inputs"
log_dir = "configured-logs"
mirror_log_dir = "mirror-logs"
submit_script = "submit.sh"

[run]
name = "VASP-calc"
continue_from = 2
max_iter = 6
monitor_interval = 300
nodes = 4
success_string = "reached required accuracy - stopping structural energy minimisation"

[vasp]
executable = "/opt/vasp/bin/vasp_std"
```

If `input_dir` is omitted, AutoSlurm checks in order: `input`, `inputs`,
`INPUT`, `INPUTS`.

## 4. State And Event Files

The Python CLI and legacy launcher write runtime metadata in the job directory.

`autoslurm-state.json` is the current snapshot:

- resolved config and paths
- latest run id
- current iteration
- active SLURM job id
- last scheduler state and exit code
- final outcome when the chain ends

`autoslurm-events.jsonl` is append-only operational history:

- config loaded and checks completed
- dry-run plans
- job submissions and scheduler status transitions
- iteration start, completion, retry, and failure events
- reset actions
- VASP validation and fatal-error findings

Use `autoslurm status --workdir PATH` for normal inspection. Keep manual edits to
recovery cases with a backup.

## 5. VASP-First Plugin Scope

The plugin layer exists to keep domain logic separate from scheduler logic. This
milestone supports VASP only:

- required input files: `INCAR.start`, `INCAR.cont`, `KPOINTS`, `POSCAR`,
  `POTCAR`
- success detection from `OUTCAR` using the configured success string
- structurally plausible, non-empty `CONTCAR` validation before carry-over
- fatal log detection for common VASP failures such as `ZBRENT`, `BRMIX`,
  `EDDDAV`, missing `POTCAR`, and corrupted `WAVECAR`
- restart carry-over for `CONTCAR -> POSCAR`, `WAVECAR`, and `CHGCAR`

Do not assume non-VASP engines are supported by this milestone.

## 6. SLURM Monitoring

The scheduler integration targets standard SLURM tools:

- submit with `sbatch`
- live status from `squeue`
- terminal state fallback from `sacct`
- cancellation through `scancel`

The shell launcher still uses `squeue -h -j <jobid> -o "%T|%M"` for live
monitoring. The Python scheduler should also check `sacct` when a job disappears
from `squeue`.

## 7. Fake-SLURM Tests

Tests can run without a real cluster by prepending fake SLURM commands to
`PATH`. The fake cluster stores scheduler state in a JSON file selected by
`FAKE_SLURM_STATE`.

```bash
PYTHONPATH=. pytest tests
```

The fake tools cover `sbatch`, `squeue`, `sacct`, and `scancel`, including
successful jobs, failures, timeouts, cancellations, preemption, out-of-memory
states, and jobs that disappear from `squeue` before `sacct` reports the final
state.

## 8. Legacy Shell Commands

These commands remain supported:

### Interactive wrapper

```bash
AUTOSLURM=/path/to/AutoSlurm
cd /path/to/job
"$AUTOSLURM"/autoslurm-cli.sh
```

### Manual validate and run

```bash
AUTOSLURM=/path/to/AutoSlurm
JOBDIR=/path/to/job

"$AUTOSLURM"/setup-check.sh --workdir "$JOBDIR"

"$AUTOSLURM"/launch.sh --validate-only \
  --workdir "$JOBDIR" \
  --nodes 5 \
  --vasp-exe /path/to/vasp_std

nohup "$AUTOSLURM"/launch.sh \
  --workdir "$JOBDIR" \
  --name "VASP-calc" \
  --max-iter 5 \
  --nodes 5 \
  --monitor-interval 120 \
  --success-string "stopping structural energy minimisation" \
  --vasp-exe /path/to/vasp_std > "$JOBDIR"/logs/launcher_manual.log 2>&1 &
```

### Reset

```bash
"$AUTOSLURM"/reset-run.sh --workdir "$JOBDIR" --yes
"$AUTOSLURM"/reset-run.sh --workdir "$JOBDIR" --from-iter 4 --yes
```

## 9. Runtime Behavior

- Static VASP inputs are read from the configured or detected input directory.
- Runtime `POSCAR`, `WAVECAR`, and `CHGCAR` live in the job directory root.
- Each iteration runs in `iteration-N/`.
- On successful iteration completion, `CONTCAR` becomes the next runtime
  `POSCAR`; `WAVECAR` and `CHGCAR` are carried forward when present.
- If the success string is found, the chain stops successfully.
- If the success string is not found but `CONTCAR` is valid, the next iteration
  starts.
- If `CONTCAR` is missing, empty, or structurally invalid, the chain stops with
  an error.

Shell STOPCAR behavior remains:

- at 21.5h elapsed runtime, write `LSTOP = .TRUE.` to `STOPCAR`
- at 23h elapsed runtime, append `LABORT = .TRUE.` to the same `STOPCAR`

## 10. Troubleshooting

`execvp error on file vasp_std`: set `[vasp].executable` or pass
`--vasp-exe /full/path/to/vasp_std`.

No input folder found: create `input`, `inputs`, `INPUT`, or `INPUTS`, or set
`[paths].input_dir`.

Dry run submits anyway: this is a bug. `autoslurm run --dry-run` and
`autoslurm check` must not call `sbatch`.

Chain log stopped updating: check the Python status first, then check the legacy
launcher process if using shell commands:

```bash
autoslurm status --workdir "$JOBDIR"
pgrep -af launch.sh
```
