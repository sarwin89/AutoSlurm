# AutoSlurm

AutoSlurm automates iterative VASP jobs on SLURM.

Highlights:
- central script location (`AutoSlurm`)
- per-job working directories
- input folder auto-detect: `input`, `inputs`, `INPUT`, `INPUTS`
- iterative carry-over (`CONTCAR -> POSCAR`, plus `WAVECAR/CHGCAR`)
- resume mode can re-seed `POSCAR`, `WAVECAR`, and `CHGCAR` from the previous iteration
- if the success string is not reached yet, chaining continues as long as `CONTCAR` exists
- dual logs: `<jobdir>/logs` and `<autoslurm>/logs`
- wrapper submission via `nohup` so launcher continues after terminal close
- launcher logs caught shutdown signals like `SIGHUP` and `SIGTERM` before exiting

## Quick Start

```bash
AUTOSLURM=/pfs/home/shobhana/sarwin/AutoSlurm
cd /pfs/home/shobhana/sarwin/bilayer-7/test

chmod +x "$AUTOSLURM"/autoslurm-cli.sh \
         "$AUTOSLURM"/launch.sh \
         "$AUTOSLURM"/setup-check.sh \
         "$AUTOSLURM"/reset-run.sh \
         "$AUTOSLURM"/submit.sh

"$AUTOSLURM"/autoslurm-cli.sh
```

Wrapper flow:
1. detects current workdir and input folder name
2. selects VASP executable (`vasp_std`, `vasp_ncl`, `vasp_gam`, custom)
3. optional reset (full or from iteration N)
4. setup check + validation
5. asks node count and other run options
6. background submit (`nohup`) and exit

## Minimal Layout

```text
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
```

## Manual Launch (Optional)

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

## Important Defaults

- `submit.sh` baseline nodes: `#SBATCH -N 5`
- per-run override: `--nodes N` (also prompted in wrapper)
- STOPCAR timing: 21.5h (`77400s`)
- LABORT timing: 23h (`82800s`) appended to `STOPCAR` (same file)

## Monitoring

```bash
squeue -j <jobid>
tail -f <jobdir>/logs/chain_*.log
tail -f <autoslurm>/logs/chain_<jobtag>_*.log
```

## Reliability Note

`autoslurm-cli.sh` submits `launch.sh` with `nohup` + background + `disown`, so it keeps running after terminal close in normal cluster setups. If the launcher receives a catchable shutdown signal, it now writes that to the chain log before exiting. `SIGKILL` still cannot be trapped or logged from inside the process. If your site force-kills login-node user processes, use `tmux/screen` or ask admins for persistent launcher policy.

For full operational details, see [AUTOMATION_GUIDE.md](./AUTOMATION_GUIDE.md).
