# AutoSlurm
Bash based automation for slurm job submission

## What Was Created

A complete, production-ready (VASP-only for now) iteration chain automation system with the following components:

### Core Scripts (Updated)

#### 1. **`submit.sh`** - VASP Job Runner
- Clean, simplified job runner based on your tested `submit-cpu.sh`
- Loads Intel compiler + MPI modules
- Creates machinefile from SLURM node info
- Runs VASP using `mpiexec.hydra` with optimized MPI settings
- Proper cleanup and error handling
- **Key change**: Removed internal STOPCAR logic (handled by launch.sh now)

#### 2. **`launch.sh`** - Orchestrator & Monitor
- Fully rewritten with comprehensive features:
  - Configurable via command-line arguments (--name, --success-string, --monitor-interval, etc.)
  - **Resume from any iteration** with --continue-from N
  - Creates iteration-N folders with proper file management
  - Submits jobs with SBATCH coordination
  - **Monitors job status every configurable interval** (default 30 min)
  - **Detects actual compute time** via `sacct` (excludes queue time)
  - **Writes STOPCAR at 22 hours** of actual running
  - **Writes LABORT at 23 hours** as fallback
  - **Early convergence detection**: Jobs completing without STOPCAR are considered converged
  - **Divergence detection**: Monitors for increasing energy/forces, allows one retry
  - Checks OUTCAR for user-defined success string (optional)
  - **Logs everything to timestamped chain_*.log files**
  - Handles WAVECAR/CHGCAR checkpoint files automatically
  - Full error handling with descriptive messages

### Supporting Files

#### 3. **`AUTOMATION_GUIDE.md`**
- Comprehensive reference documentation
- Setup instructions
- Usage examples
- How the system works (architecture overview)
- Troubleshooting guide
- Performance optimization tips

#### 4. **`setup-check.sh`** (New Helper)
- Validates your setup before running
- Checks for required files
- Verifies SLURM configuration
- Color-coded output for pass/warn/fail
- Can auto-fix permissions if needed

---

## Key Improvements Over Previous Versions

| Feature | Before | Now |
|---------|--------|-----|
| STOPCAR Timing | Fixed 21h from submit start | **Tracks actual compute time (22h after start)** |
| Monitoring | Only checked completion | **Monitors every 30-60 min, logs status** |
| Queue Awareness | None | **Detects queue time, writes STOPCAR accordingly** |
| Logging | Simple stdout | **Timestamped chain log with iteration details** |
| Success Checking | Assumed completion meant success | **Validates success string in OUTCAR** |
| Configuration | Hardcoded base dir | **Command-line arguments for full flexibility** |
| Resume | Simple | **Robust resume from any iteration** |

---

## What You Need To Do

### Step 1: Prepare Your INCAR Files

Create two INCAR files in your calculation directory:

**INCAR.start** (first iteration - fresh start):
```ini
ISTART = 0           ! Build from scratch
ICHARG = 2           ! Build charge density
NSW = 100
EDIFFG = -0.01
[rest of your settings...]
```

**INCAR.cont** (iterations 2+ - continue from checkpoint):
```ini
ISTART = 1           ! Read WAVECAR
ICHARG = 1           ! Read CHGCAR
NSW = 100
EDIFFG = -0.01
[rest of your settings...]
```

### Step 2: Configure SLURM Settings

Edit the `#SBATCH` directives in **submit.sh**:
- `--partition`: Your cluster's partition name
- `--qos`: Your QoS level
- `-N`: Number of nodes
- `--ntasks-per-node`: Tasks per node
- `--time`: Keep at 24:00:00 (required for STOPCAR at 22h)

Also verify module loading matches your cluster:
```bash
module load compilers/intel2017/composer_xe_2017/default  # Update if needed
```

### Step 3: Verify Your Setup

```bash
chmod +x launch.sh submit.sh setup-check.sh
./setup-check.sh
```

This will verify all required files and configuration. Output looks like:
```
✓ Found: launch.sh
✓ Found: submit.sh
...
✓ Walltime is 24 hours (correct for STOPCAR at 22h)
✓ All required files present!
```

### Step 4: Run Your First Chain

```bash
./launch.sh \
    --name "your-job-name" \
    --max-iter 20 \
    --success-string "reached structural accuracy" \
    --continue-from 1 \
    --monitor-interval 1800
```

**Note**: `--success-string` is optional. If not provided, early completion (without STOPCAR) is considered successful convergence.

### Step 5: Monitor Progress

In another terminal, watch the log:
```bash
tail -f chain_*.log
```

Or check job queue:
```bash
squeue -u $USER
```

---

## Architecture Diagram

```
launch.sh (Main Orchestrator)
│
├─ Loop over iterations
│  │
│  ├─ Create iteration-N/
│  ├─ Copy files (INCAR, POSCAR, KPOINTS, POTCAR)
│  ├─ Copy WAVECAR, CHGCAR from base
│  │
│  └─ sbatch submit.sh
│     │
│     └─① Job goes to SLURM queue
│        └─② Job starts when resources available
│
├─ Monitor loop (every 30-60 min)
│  │
│  ├─ Query job status: sacct -j $JOB_ID
│  ├─ Get elapsed time (actual compute, not queue)
│  ├─ If elapsed ≥ 22h: Write STOPCAR (LSTOP=TRUE)
│  ├─ If elapsed ≥ 23h: Write LABORT (fallback)
│  ├─ Log status to chain_*.log
│  │
│  └─ When job completes:
│     └─ Check OUTCAR for success string
│        ├─ If found: Advance to next iteration
│        └─ If not found: Stop with error
│
└─ After MAX_ITER reached: Print completion summary
```

---

## Example Session

```bash
$ cd /scratch/user/MoS2-calc

$ ls
INCAR.start  INCAR.cont  KPOINTS  POSCAR  POTCAR  launch.sh  submit.sh

$ ./setup-check.sh
✓ Found: launch.sh
✓ Found: submit.sh
✓ Found: INCAR.start
✓ Found: INCAR.cont
✓ Found: KPOINTS
✓ Found: POSCAR
✓ Found: POTCAR
✓ All required files present!

Ready to run:
  ./launch.sh --name "MoS2" --max-iter 20 --success-string "reached structural accuracy"

$ nohup ./launch.sh --name "MoS2-relax" --max-iter 20 \
    --success-string "reached structural accuracy" > launch.log 2>&1 &
[1] 54321

$ tail -f chain_2026*.log
[2026-03-04 14:30:16]  [ITER-1]  Submitted → Job ID: 12345678
[2026-03-04 14:30:20]  [ITER-1]  Starting job monitoring
[2026-03-04 14:35:20]  [ITER-1]  [Check 1] Status: PENDING | Elapsed: 00:00:04
[2026-03-04 14:40:23]  [ITER-1]  [Check 2] Status: RUNNING | Elapsed: 00:05:07
...
[2026-03-04 22:30:45]  [ITER-1]  ✓ Written STOPCAR (LSTOP = .TRUE.) at 22:00:34
[2026-03-04 23:35:12]  [ITER-1]  Job finished → State: COMPLETED
[2026-03-04 23:35:15]  [ITER-1]  ✓ SUCCESS: Found 'reached structural accuracy' in OUTCAR
[2026-03-04 23:35:16]  [ITER-1]  ✓ Advancing to iteration 2
[2026-03-04 23:35:17]  [ITER-2]  ────────────────────────────
[2026-03-04 23:35:17]  [ITER-2]  Preparing iteration 2 of 20
...
```

---

## STOPCAR/LABORT Timing Explanation

The system tracks **actual computer runtime** (excluding queue time):

1. **Job submitted** at T=0 (may sit in queue)
2. **Job starts** at T=Tqueue (detected via `sacct`)
3. **Actual runtime** = current_time - job_start_time
4. **At 22h actual runtime** → Write STOPCAR (LSTOP = .TRUE.)
5. **At 23h actual runtime** → Write LABORT (LABORT = .TRUE.) as backup
6. **Hard limit at 24h** → SLURM auto-kills job (but STOPCAR already triggered graceful stop)

This ensures VASP:
- Gets ~20 hours of actual compute time
- 1-2 hours for graceful checkpoint/stop
- Results are saved before hard timeout

---

## Customization Reference

### Change STOPCAR Timing

Edit `launch.sh`:
```bash
STOPCAR_TIME=61200    # 17 hours (change from 79200)
LABORT_TIME=68400     # 19 hours (change from 82800)
```

If running on very slow systems or long-running relaxations.

### Change Monitoring Interval

```bash
./launch.sh --monitor-interval 300     # Check every 5 min (fast)
./launch.sh --monitor-interval 3600    # Check every 1 hour (slow)
```

Default is 1800 seconds (30 minutes).

### Custom Success String

Find convergence message in OUTCAR:
```bash
tail -50 iteration-1/OUTCAR
```

Use exact text:
```bash
./launch.sh --success-string "your exact string here"
```

### Early Convergence (No Success String)

For calculations that converge before the STOPCAR timing:
```bash
./launch.sh --name "fast-converging" --max-iter 10
# No --success-string needed - early completion = success
```

### Resume from Specific Iteration

```bash
# Continue from iteration 7
./launch.sh --continue-from 7 --max-iter 20
```

---

## Monitoring Commands

Monitor a running chain:

```bash
# Watch log file
tail -f chain_*.log

# Check SLURM queue
squeue -u $USER

# Check specific job
squeue -j 12345678

# View job resource usage
sstat -j 12345678

# Check iteration OUTCAR
tail -50 iteration-5/OUTCAR

# Verify STOPCAR was written
cat iteration-5/STOPCAR
```

---

## Troubleshooting Quick Links

**See AUTOMATION_GUIDE.md for detailed troubleshooting, including:**

- Job stays in queue
- STOPCAR not written
- Success string not found
- WAVECAR/CHGCAR not copied
- Wrong INCAR used
- Custom success strings by calculation type

---

## Next Steps

1. **Review** `AUTOMATION_GUIDE.md` for in-depth information
2. **Run** `./setup-check.sh` to validate your setup
3. **Execute** your first chain with proper arguments
4. **Monitor** progress with `tail -f chain_*.log`

---

## Support Materials

- 📖 **AUTOMATION_GUIDE.md** - Complete reference manual
- ✓ **setup-check.sh** - Configuration validator
- 📊 **chain_*.log** - Detailed execution logs

Everything is timestamped and logged for your records!
