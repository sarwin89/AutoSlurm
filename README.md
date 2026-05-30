# AutoSlurm

AutoSlurm automates iterative VASP jobs on SLURM. The milestone adds a Python
CLI while keeping the original shell commands supported.

Highlights:
- Python CLI: `autoslurm init/check/doctor/run/status/reset`
- VASP-first workflow: input validation, `CONTCAR -> POSCAR` carry-over, restart
  file handling, and common VASP failure detection
- `autoslurm.yaml` or `autoslurm.toml` job config with CLI overrides
- runtime state and events in `<jobdir>/autoslurm-state.json` and
  `<jobdir>/autoslurm-events.jsonl`
- fake-SLURM test utilities for local scheduler tests
- legacy shell workflow remains available: `autoslurm-cli.sh`, `launch.sh`,
  `setup-check.sh`, `reset-run.sh`, and `submit.sh`

## Quick Start

From a VASP job directory:

```bash
cd /path/to/job

autoslurm init --workdir .
autoslurm check --workdir .
autoslurm doctor --workdir .
autoslurm run --workdir . --dry-run
autoslurm run --workdir .
autoslurm status --workdir .
```

Use `python -m autoslurm ...` instead of `autoslurm ...` when running directly
from a source checkout without an installed console script.

## Job Layout

```text
<jobdir>/
  autoslurm.yaml
  input|inputs|INPUT|INPUTS/
    INCAR.start
    INCAR.cont
    KPOINTS
    POSCAR
    POTCAR
  autoslurm-state.json
  autoslurm-events.jsonl
  logs/
  iteration-1/
  iteration-2/
```

If `input_dir` is not configured, AutoSlurm looks for `input`, `inputs`,
`INPUT`, then `INPUTS`.

## Python CLI

- `autoslurm init --workdir PATH` writes a starter `autoslurm.yaml`.
- `autoslurm check --workdir PATH` validates config, paths, VASP inputs, and the
  submit script without submitting to SLURM.
- `autoslurm doctor --workdir PATH` runs `check` plus local scheduler command
  checks such as `sbatch`, `squeue`, `sacct`, and `scancel`.
- `autoslurm run --workdir PATH --dry-run` resolves config and prints the planned
  run without calling `sbatch`.
- `autoslurm run --workdir PATH` starts or resumes the iteration chain.
- `autoslurm status --workdir PATH` reads AutoSlurm state/events and reports the
  latest run and scheduler state when available.
- `autoslurm reset --workdir PATH [--from-iter N]` removes generated iteration
  folders and run logs so a chain can be restarted.

Common overrides mirror the shell launcher: `--input-dir`, `--log-dir`,
`--mirror-log-dir`, `--submit-script`, `--nodes`, `--vasp-exe`,
`--continue-from`, `--max-iter`, `--monitor-interval`, and `--success-string`.

## Config

`autoslurm.yaml` is the default config file written by `init`. AutoSlurm also
discovers `autoslurm.toml` for legacy-friendly configs. Relative paths are
resolved from the job directory, and explicit CLI flags take precedence.

```toml
[paths]
input_dir = "inputs"
log_dir = "logs"
mirror_log_dir = "../AutoSlurm/logs"
submit_script = "../AutoSlurm/submit.sh"

[run]
name = "VASP-calc"
continue_from = 1
max_iter = 5
monitor_interval = 120
nodes = 5
success_string = "stopping structural energy minimisation"

[vasp]
executable = "/path/to/vasp_std"
```

## State And Events

The Python CLI and legacy launcher record runtime files in the job directory:

- `autoslurm-state.json` stores the latest run, current iteration, active SLURM
  job id, resolved paths, and terminal outcome.
- `autoslurm-events.jsonl` is append-only and records operational events such as
  checks, submissions, scheduler status, iteration transitions, dry runs, resets,
  and VASP validation failures.

These files are for inspection and troubleshooting. Prefer `autoslurm status`
over manual edits.

## VASP Scope

The plugin boundary is VASP-first. The current supported domain is VASP input
validation, output success-string detection, `CONTCAR` validation, common fatal
error detection, and restart file carry-over. Other simulation engines are out
of scope for this milestone.

## Tests

The fake-SLURM tests provide local coverage without a real cluster. They use
file-backed `sbatch`, `squeue`, `sacct`, and `scancel` shims plus a JSON fake
cluster state file.

```bash
PYTHONPATH=. pytest tests
```

## Legacy Shell Workflow

Existing shell commands remain supported and are not deprecated:

```bash
AUTOSLURM=/path/to/AutoSlurm
JOBDIR=/path/to/job

"$AUTOSLURM"/autoslurm-cli.sh
"$AUTOSLURM"/setup-check.sh --workdir "$JOBDIR"
"$AUTOSLURM"/launch.sh --validate-only --workdir "$JOBDIR" --nodes 5
nohup "$AUTOSLURM"/launch.sh --workdir "$JOBDIR" --nodes 5 > "$JOBDIR"/logs/launcher_manual.log 2>&1 &
"$AUTOSLURM"/reset-run.sh --workdir "$JOBDIR" --from-iter 4 --yes
```

For full operational details, see [AUTOMATION_GUIDE.md](./AUTOMATION_GUIDE.md).
