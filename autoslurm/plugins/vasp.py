from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Iterable

from autoslurm.config import AutoSlurmConfig
from autoslurm.results import CheckResult, error, ok, warn

from .base import WorkflowProfile


class VaspValidationError(ValueError):
    pass


COMMON_FATAL_PATTERNS = {
    "ZBRENT": "VASP ZBRENT ionic-step failure detected",
    "BRMIX": "VASP BRMIX charge-mixing failure detected",
    "EDDDAV": "VASP EDDDAV diagonalization failure detected",
    "EDWAV": "VASP EDWAV wavefunction failure detected",
    "TOO FEW BANDS": "VASP reports too few bands",
    "TOO FEW K-POINTS": "VASP reports too few k-points",
    "POTCAR": "VASP POTCAR error detected",
    "WAVECAR": "VASP WAVECAR error detected",
    "CHGCAR": "VASP CHGCAR error detected",
    "OUT OF MEMORY": "out-of-memory message detected",
    "MPI_ABORT": "MPI abort detected",
}


class VaspProfile(WorkflowProfile):
    code = "vasp"

    def required_input_files(self, config: AutoSlurmConfig) -> list[str]:
        return [config.vasp.incar_start, config.vasp.incar_continue, "KPOINTS", "POSCAR", "POTCAR"]

    def validate_inputs(self, workdir: Path, config: AutoSlurmConfig) -> list[CheckResult]:
        input_dir = config.input_dir_path(workdir)
        if not input_dir.is_dir():
            return [error("vasp.input_dir_missing", f"input directory not found: {input_dir}", input_dir)]
        results: list[CheckResult] = []
        for filename in self.required_input_files(config):
            path = input_dir / filename
            if path.is_file():
                results.append(ok("vasp.required_input_found", f"found {filename}", path))
            else:
                results.append(error("vasp.required_input_missing", f"missing {filename}", path))
        poscar = input_dir / "POSCAR"
        if poscar.is_file():
            for result in validate_poscar(poscar, label="POSCAR"):
                results.append(warn(result.code, result.message, result.path) if result.is_error else result)
        potcar = input_dir / "POTCAR"
        if potcar.is_file() and potcar.stat().st_size == 0:
            results.append(error("vasp.potcar_empty", "POTCAR is empty", potcar))
        incar = input_dir / config.vasp.incar_start
        if incar.is_file():
            results.extend(validate_incar(incar))
        for restart_file in config.vasp.carry:
            restart_path = input_dir / restart_file
            if restart_path.is_file() and restart_path.stat().st_size == 0:
                results.append(warn("vasp.restart_empty", f"restart file {restart_file} is empty", restart_path))
        return results

    def validate_contcar(self, path: Path) -> list[CheckResult]:
        return validate_poscar(path, label="CONTCAR")

    def detect_success(self, iteration_dir: Path, config: AutoSlurmConfig) -> bool:
        return any(outcar_has_success(iteration_dir / "OUTCAR", success) for success in config.vasp.success_strings)

    def detect_failures(self, iteration_dir: Path) -> list[CheckResult]:
        paths = [
            iteration_dir / "OUTCAR",
            iteration_dir / "vasp.log",
            *iteration_dir.glob("job.*.err"),
            *iteration_dir.glob("job.*.out"),
        ]
        return detect_vasp_failures(paths)

    def carry_over_plan(self, iteration_dir: Path, workdir: Path, config: AutoSlurmConfig) -> list[dict]:
        plan = [{"source": str(iteration_dir / "CONTCAR"), "destination": str(workdir / "POSCAR"), "required": True}]
        for filename in config.vasp.carry:
            plan.append({"source": str(iteration_dir / filename), "destination": str(workdir / filename), "required": False})
        return plan

    def input_hashes(self, workdir: Path, config: AutoSlurmConfig) -> dict[str, str]:
        input_dir = config.input_dir_path(workdir)
        hashes: dict[str, str] = {}
        for filename in self.required_input_files(config):
            path = input_dir / filename
            if path.is_file():
                hashes[filename] = sha256_file(path)
        return hashes

    def summarize_outputs(self, iteration_dir: Path, config: AutoSlurmConfig) -> dict:
        summary = {
            "code": "vasp",
            "iteration_dir": str(iteration_dir),
            "converged": self.detect_success(iteration_dir, config),
            "warnings": [result.message for result in self.detect_failures(iteration_dir)],
        }
        energy = extract_final_energy(iteration_dir / "OUTCAR", iteration_dir / "OSZICAR")
        if energy is not None:
            summary["final_energy"] = energy
        if (iteration_dir / "CONTCAR").is_file():
            summary["final_structure_path"] = str(iteration_dir / "CONTCAR")
        return summary


def validate_required_inputs(input_dir: Path) -> bool:
    missing = [filename for filename in ("INCAR.start", "INCAR.cont", "KPOINTS", "POSCAR", "POTCAR") if not (input_dir / filename).is_file()]
    if missing:
        raise VaspValidationError(f"missing required VASP input files: {', '.join(missing)}")
    return True


def validate_contcar(path: Path) -> bool:
    errors = [result for result in validate_poscar(path, label="CONTCAR") if result.is_error]
    if errors:
        raise VaspValidationError("; ".join(result.message for result in errors))
    return True


def outcar_has_success(path: Path, success_string: str) -> bool:
    return bool(success_string and success_string in _read_text(path))


def detect_fatal_errors(path: Path) -> list[CheckResult]:
    text = _read_text(path).upper()
    codes = {
        "ZBRENT": "ZBRENT",
        "BRMIX": "BRMIX",
        "EDDDAV": "EDDDAV",
        "POTCAR": "MISSING_POTCAR",
        "WAVECAR": "CORRUPTED_WAVECAR",
    }
    return [error(code, f"detected {code}", path) for pattern, code in codes.items() if pattern in text]


def validate_poscar(path: Path, *, label: str = "POSCAR") -> list[CheckResult]:
    if not path.is_file():
        return [error("vasp.structure_missing", f"{label} not found", path)]
    if path.stat().st_size == 0:
        return [error("vasp.structure_empty", f"{label} is empty", path)]
    lines = [line.strip() for line in _read_text(path).splitlines() if line.strip()]
    if len(lines) < 7:
        return [error("vasp.structure_invalid", f"{label} is too short to be a POSCAR/CONTCAR structure", path)]
    results: list[CheckResult] = []
    try:
        float(lines[1])
    except (ValueError, IndexError):
        results.append(error("vasp.structure_invalid_scale", f"{label} has invalid scale factor", path))
    for idx in range(2, 5):
        parts = lines[idx].split() if idx < len(lines) else []
        if len(parts) < 3:
            results.append(error("vasp.structure_invalid_lattice", f"{label} lattice vector {idx - 1} is incomplete", path))
            continue
        try:
            [float(part) for part in parts[:3]]
        except ValueError:
            results.append(error("vasp.structure_invalid_lattice", f"{label} lattice vector {idx - 1} is not numeric", path))
    counts_line = _find_counts_line(lines)
    if counts_line is None:
        results.append(error("vasp.structure_missing_counts", f"{label} atom-count line not found", path))
    else:
        counts = [int(part) for part in lines[counts_line].split()]
        coord_start = counts_line + 1
        if coord_start < len(lines) and lines[coord_start].lower().startswith("s"):
            coord_start += 1
        if coord_start < len(lines) and lines[coord_start].lower()[0] in {"d", "c", "k"}:
            coord_start += 1
        if sum(counts) <= 0:
            results.append(error("vasp.structure_empty_counts", f"{label} atom counts sum to zero", path))
        if len(lines) - coord_start < sum(counts):
            results.append(error("vasp.structure_missing_coordinates", f"{label} does not contain enough coordinate lines", path))
    if not results:
        results.append(ok("vasp.structure_valid", f"{label} is structurally plausible", path))
    return results


def validate_incar(path: Path) -> list[CheckResult]:
    text = _read_text(path).upper()
    if not text.strip():
        return [warn("vasp.incar_empty", "INCAR is empty", path)]
    results: list[CheckResult] = []
    if "ENCUT" not in text:
        results.append(warn("vasp.incar_missing_encut", "INCAR does not define ENCUT", path))
    if "EDIFF" not in text:
        results.append(warn("vasp.incar_missing_ediff", "INCAR does not define EDIFF", path))
    return results or [ok("vasp.incar_readable", "INCAR is readable", path)]


def detect_vasp_failures(paths: Iterable[Path]) -> list[CheckResult]:
    results: list[CheckResult] = []
    seen: set[tuple[str, Path]] = set()
    for path in paths:
        if not path.is_file():
            continue
        text = _read_text(path).upper()
        for pattern, message in COMMON_FATAL_PATTERNS.items():
            if pattern in text and (pattern, path) not in seen:
                seen.add((pattern, path))
                results.append(error(f"vasp.error.{pattern.lower().replace(' ', '_')}", message, path))
    return results


def extract_final_energy(outcar: Path, oszicar: Path) -> float | None:
    candidates: list[float] = []
    if outcar.is_file():
        for match in re.finditer(r"energy\s+without entropy=\s*([-+]?\d+(?:\.\d+)?)", _read_text(outcar)):
            candidates.append(float(match.group(1)))
    if oszicar.is_file():
        for match in re.finditer(r"\bF=\s*([-+]?\d+(?:\.\d+)?)", _read_text(oszicar)):
            candidates.append(float(match.group(1)))
    return candidates[-1] if candidates else None


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _find_counts_line(lines: list[str]) -> int | None:
    for idx in (5, 6):
        if idx < len(lines):
            parts = lines[idx].split()
            if parts and all(part.isdigit() for part in parts):
                return idx
    return None


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""
