# Quick Start Examples

This file contains template configurations and usage examples.

---

## Template: INCAR.start (First Iteration)

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

---

## Template: INCAR.cont (Iterations 2+)

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

---

## Example Run Cases

### Case 1: Structure Relaxation (Typical)

```bash
./launch.sh \
    --name "bilayer-27-relax" \
    --max-iter 20 \
    --success-string "reached structural accuracy" \
    --continue-from 1 \
    --monitor-interval 1800
```

**Expected in chain log:**
```
[...] Submitted → Job ID: 12345678
[...] Status: PENDING | Elapsed: 00:00:10
[...] Status: RUNNING | Elapsed: 00:05:32
[...] Status: RUNNING | Elapsed: 00:10:45
[...] ✓ Written STOPCAR (LSTOP = .TRUE.) at 22:00:34
[...] Job finished → State: COMPLETED
[...] ✓ SUCCESS: Found 'reached structural accuracy' in OUTCAR
[...] ✓ Copied CONTCAR → base POSCAR
[...] ✓ Advancing to iteration 2
```

### Case 2: SCF-only (Not Relaxing)

For pure self-consistent field without relaxation:

**INCAR.start:**
```
ISTART = 0
NSW = 0       ! No ionic steps
ISIF = 2      ! Only relax electronic degrees of freedom
```

**INCAR.cont:**
```
ISTART = 1
ICHARG = 1
NSW = 0
ISIF = 2
```

**launch.sh command:**
```bash
./launch.sh \
    --name "scf-calc" \
    --success-string "total energy(sigma" \
    --max-iter 1 \
    --monitor-interval 600
```

### Case 3: Error-Corrected Calculation Run

Total energy = energy of system with defect - energy of pristine

**INCAR.start & INCAR.cont:** Same as relaxation case above

**launch.sh:**
```bash
./launch.sh \
    --name "defect-calcs" \
    --success-string "reached structural accuracy" \
    --max-iter 5 \
    --monitor-interval 1800
```

After completion, use:
```bash
E_defect=$(grep "total energy(sigma" iteration-5/OUTCAR | tail -1 | awk '{print $7}')
E_pristine=$(grep "total energy(sigma" ../pristine/OUTCAR | tail -1 | awk '{print $7}')
E_form=$((E_defect - E_pristine))
echo "Formation energy: $E_form eV"
```

---

## Directory Organization

Recommended structure for multiple calculations:

```
MoS2_calculations/
├── pristine/
│   ├── launch.sh (symlink or copy)
│   ├── submit.sh (symlink or copy)
│   ├── INCAR.start
│   ├── INCAR.cont
│   ├── KPOINTS
│   ├── POSCAR
│   ├── POTCAR
│   ├── iteration-1/
│   ├── iteration-2/
│   └── chain_*.log
│
├── defect-1/
│   ├── launch.sh
│   ├── submit.sh
│   ├── INCAR.start (different starting structure)
│   ├── INCAR.cont
│   ├── KPOINTS
│   ├── POSCAR (contains defect)
│   ├── POTCAR
│   ├── iteration-1/
│   └── chain_*.log
│
└── defect-2/
    └── ... (similar structure)
```

Run multiple in parallel:
```bash
cd pristine && nohup ./launch.sh --name "pristine" --max-iter 20 > launch.log 2>&1 &
cd ../defect-1 && nohup ./launch.sh --name "def-1" --max-iter 20 > launch.log 2>&1 &
cd ../defect-2 && nohup ./launch.sh --name "def-2" --max-iter 20 > launch.log 2>&1 &
```

---

## Success String Reference

Find the appropriate convergence message for your calculation type:

| Calculation Type | Success String To Use |
|------------------|----------------------|
| Structure relaxation | `"reached structural accuracy"` |
| SCF convergence | `"total energy(sigma"` or `"total energy (sigma"` |
| Band structure | `"total energy"` (after all k-points) |
| General SCF | `"total energy(sigma"` |

Check OUTCAR to find exact wording:
```bash
tail -100 iteration-1/OUTCAR | grep -i "accuracy\|energy"
```

---

## Monitoring a Running Chain

### Watch the log file

```bash
tail -f chain_*.log
```

### Check job queue

```bash
squeue -u $USER
squeue -j 12345678     # Check specific job
```

### Check VASP progress in iteration

```bash
tail -50 iteration-5/OUTCAR | grep -E "ionic|energy"
```

### Check if STOPCAR was written

```bash
cat iteration-5/STOPCAR
tail -20 chain_*.log | grep STOPCAR
```

---

## Troubleshooting Common Issues

### "Success string not found but OUTCAR looks converged"

1. Check exact wording:
   ```bash
   grep "accuracy\|total energy" iteration-N/OUTCAR | tail -5
   ```

2. Update `--success-string` with exact text:
   ```bash
   ./launch.sh --success-string "exact string from OUTCAR"
   ```

### Job killed by SLURM before STOPCAR written

Check if timing is too aggressive. Current settings:
- STOPCAR at 22h (79200s)
- LABORT at 23h (82800s)
- Hard limit: 24h

If running on very slow nodes, increase times:
```bash
# Edit launch.sh
STOPCAR_TIME=61200    # 17 hours instead of 22
LABORT_TIME=68400     # 19 hours instead of 23
```

### WAVECAR/CHGCAR too large, running out of disk

Delete per-iteration checkpoint files after they're copied:
```bash
for i in iteration-*/; do
    rm -f "$i/DOSCAR" "$i/IBZKPT" "$i/WAVECAR" "$i/CHGCAR"
done
```

Or modify INCAR to not write everything:
```
! INCAR.cont
LWAVE  = .FALSE.    ! Don't write WAVECAR (faster, but need ICHARG)
LCHARG = .FALSE.    ! Don't write CHGCAR
# But then for next iteration must use ICHARG = 0 (build from atomic charge)
```

### Cannot resume from middle of calculation

To safely pause and resume:
```bash
# After iteration 7 completes
cp iteration-7/POSCAR POSCAR      # Ensure base POSCAR is updated
cp iteration-7/WAVECAR .
cp iteration-7/CHGCAR .

# Later, resume
./launch.sh --continue-from 8 --max-iter 20
```

---

## Performance Tips

### Faster Convergence with Smarter INCAR

```
! Use smaller systems for testing
! For production:

PREC   = Accurate       ! High precision
ENCUT  = 400            ! Or your recommended value

! Ionic convergence
EDIFFG = -0.01          ! 0.01 eV/Angstrom - tighter
NSW    = 100

! Electronic convergence
NELM   = 200            ! Allow more electronic steps
NELMIN = 10             ! Minimum before exit
EDIFF  = 1e-05          ! Tighter SCF

! Smearing for narrow band systems
ISMEAR = -5             ! Bloechl tetrahedron (most accurate)
# Or for metals:
ISMEAR = 1              ! Methfessel-Paxton
SIGMA  = 0.05
```

### Reduce Wall-clock Time Per Iteration

```
! In INCAR.cont:
NSW    = 50         ! Reduce from 100
EDIFFG = -0.02      ! Relax criterion (less tight)
NELM   = 80         ! Fewer SCF steps
```

Then run more iterations:
```bash
./launch.sh --max-iter 40    # More iterations, each shorter
```

---

## Creating KPOINTS File

For consistent k-point density:

```bash
# Using Monkhorst-Pack grid
# Example: 12x12x1 for 2D materials

cat > KPOINTS << EOF
Automatic mesh
0
Monkhorst-Pack
12 12 1
0.0 0.0 0.0
EOF
```

Or use `pymatgen` if available:
```python
from pymatgen.io.vasp import Kpoints
kpts = Kpoints.automatic_density(structure, kppa=1000)
kpts.write_file("KPOINTS")
```

---

## Contact & Debugging

If chains fail:

1. **Always check**: `iteration-N/OUTCAR` and `iteration-N/job.*.err`
2. **Review**: The chain log `chain_*.log` for exact error
3. **Validate**: `./setup-check.sh` to ensure configuration is correct
4. **Test single iteration**: Run a single VASP job in iteration-1 manually to debug
