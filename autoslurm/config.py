from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Optional

import yaml


DEFAULT_CONFIG_NAMES = (
    "autoslurm.yaml",
    "autoslurm.yml",
    "autoslurm.toml",
    ".autoslurm.yaml",
    ".autoslurm.yml",
    ".autoslurm.toml",
)


@dataclass
class WorkflowConfig:
    code: str = "vasp"
    name: str = "VASP-calc"
    max_iter: int = 20
    continue_from: int = 1


@dataclass
class SchedulerConfig:
    type: str = "slurm"
    partition: str = "cpu"
    nodes: int = 5
    ntasks_per_node: int = 24
    walltime: str = "24:00:00"


@dataclass
class RunConfig:
    executable: str = "vasp_std"
    mpi: str = "mpiexec.hydra"
    modules: list[str] = field(
        default_factory=lambda: ["compilers/intel2017/composer_xe_2017/default"]
    )


@dataclass
class VaspConfig:
    input_dir: str = "input"
    incar_start: str = "INCAR.start"
    incar_continue: str = "INCAR.cont"
    success_strings: list[str] = field(
        default_factory=lambda: ["stopping structural energy minimisation"]
    )
    carry: list[str] = field(default_factory=lambda: ["WAVECAR", "CHGCAR"])
    variants: list[str] = field(default_factory=lambda: ["vasp_std", "vasp_gam", "vasp_ncl"])


@dataclass
class AutoSlurmConfig:
    workflow: WorkflowConfig = field(default_factory=WorkflowConfig)
    scheduler: SchedulerConfig = field(default_factory=SchedulerConfig)
    run: RunConfig = field(default_factory=RunConfig)
    vasp: VaspConfig = field(default_factory=VaspConfig)
    path: Optional[Path] = None
    workdir: Optional[Path] = None
    log_dir_value: str = "logs"
    mirror_log_dir_value: str = "logs"
    submit_script_value: str = "submit.sh"
    monitor_interval: int = 1800
    raw: dict[str, Any] = field(default_factory=dict)

    @property
    def work_dir(self) -> Optional[Path]:
        return self.workdir

    def input_dir_path(self, workdir: Path) -> Path:
        return _resolve_path(workdir, self.vasp.input_dir)

    @property
    def input_dir(self) -> Path:
        return self.input_dir_path(self.workdir or Path.cwd())

    @property
    def log_dir(self) -> Path:
        return _resolve_path(self.workdir or Path.cwd(), self.log_dir_value)

    @property
    def mirror_log_dir(self) -> Path:
        return _resolve_path(self.workdir or Path.cwd(), self.mirror_log_dir_value)

    @property
    def submit_script(self) -> Path:
        return _resolve_path(self.workdir or Path.cwd(), self.submit_script_value)

    @property
    def continue_from(self) -> int:
        return self.workflow.continue_from

    @property
    def max_iter(self) -> int:
        return self.workflow.max_iter

    @property
    def nodes(self) -> int:
        return self.scheduler.nodes

    @property
    def vasp_exe(self) -> str:
        return self.run.executable

    @property
    def vasp_executable(self) -> str:
        return self.run.executable

    @property
    def success_string(self) -> str:
        return self.vasp.success_strings[0] if self.vasp.success_strings else ""


def discover_config(workdir: Path, names: Iterable[str] = DEFAULT_CONFIG_NAMES) -> Optional[Path]:
    for name in names:
        candidate = workdir / name
        if candidate.is_file():
            return candidate
    return None


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    result = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = value
    return result


def load_config(
    path: Optional[Path | str] = None,
    workdir: Path | str = ".",
    work_dir: Optional[Path | str] = None,
    cli_overrides: Optional[dict[str, Any]] = None,
    overrides: Optional[dict[str, Any]] = None,
) -> AutoSlurmConfig:
    if work_dir is not None:
        workdir = work_dir
    base_dir = Path(workdir).resolve()
    config_path = Path(path).expanduser().resolve() if path else discover_config(base_dir)
    if config_path is None:
        data = {"vasp": {"input_dir": _detect_input_dir(base_dir)}}
    else:
        data = _load_structured_config(config_path)
    effective_overrides = cli_overrides or overrides or {}
    if effective_overrides:
        data = deep_merge(data, _legacy_overrides_to_nested(effective_overrides))
    config = _config_from_dict(data, config_path)
    config.workdir = base_dir
    return config


def apply_cli_overrides(
    config: AutoSlurmConfig,
    *,
    code: Optional[str] = None,
    name: Optional[str] = None,
    input_dir: Optional[str] = None,
    max_iter: Optional[int] = None,
    continue_from: Optional[int] = None,
    executable: Optional[str] = None,
    nodes: Optional[int] = None,
    log_dir: Optional[str] = None,
    mirror_log_dir: Optional[str] = None,
    submit_script: Optional[str] = None,
    monitor_interval: Optional[int] = None,
    success_string: Optional[str] = None,
) -> AutoSlurmConfig:
    overrides = {
        key: value
        for key, value in {
            "code": code,
            "name": name,
            "input_dir": input_dir,
            "max_iter": max_iter,
            "continue_from": continue_from,
            "executable": executable,
            "nodes": nodes,
            "log_dir": log_dir,
            "mirror_log_dir": mirror_log_dir,
            "submit_script": submit_script,
            "monitor_interval": monitor_interval,
            "success_string": success_string,
        }.items()
        if value is not None
    }
    merged = deep_merge(config.raw, _legacy_overrides_to_nested(overrides))
    updated = _config_from_dict(merged, config.path)
    updated.workdir = config.workdir
    return updated


def _config_from_dict(raw: dict[str, Any], path: Optional[Path]) -> AutoSlurmConfig:
    data = _normalize_legacy_config(raw)
    workflow_data = data.get("workflow") or {}
    scheduler_data = data.get("scheduler") or {}
    run_data = data.get("run") or {}
    vasp_data = data.get("vasp") or {}
    paths_data = data.get("paths") or {}

    workflow = WorkflowConfig(
        code=str(workflow_data.get("code", "vasp")).lower(),
        name=str(workflow_data.get("name", "VASP-calc")),
        max_iter=_positive_int(workflow_data.get("max_iter", 20), "workflow.max_iter"),
        continue_from=_positive_int(workflow_data.get("continue_from", 1), "workflow.continue_from"),
    )
    if workflow.max_iter < workflow.continue_from:
        raise ValueError("workflow.max_iter must be >= workflow.continue_from")

    scheduler = SchedulerConfig(
        type=str(scheduler_data.get("type", "slurm")).lower(),
        partition=str(scheduler_data.get("partition", "cpu")),
        nodes=_positive_int(scheduler_data.get("nodes", 5), "scheduler.nodes"),
        ntasks_per_node=_positive_int(scheduler_data.get("ntasks_per_node", 24), "scheduler.ntasks_per_node"),
        walltime=str(scheduler_data.get("walltime", "24:00:00")),
    )
    run = RunConfig(
        executable=str(run_data.get("executable", "vasp_std")),
        mpi=str(run_data.get("mpi", "mpiexec.hydra")),
        modules=_as_list(run_data.get("modules", ["compilers/intel2017/composer_xe_2017/default"])),
    )
    vasp = VaspConfig(
        input_dir=str(vasp_data.get("input_dir", "input")),
        incar_start=str(vasp_data.get("incar_start", "INCAR.start")),
        incar_continue=str(vasp_data.get("incar_continue", "INCAR.cont")),
        success_strings=_as_list(
            vasp_data.get("success_strings", ["stopping structural energy minimisation"])
        ),
        carry=_as_list(vasp_data.get("carry", ["WAVECAR", "CHGCAR"])),
        variants=_as_list(vasp_data.get("variants", ["vasp_std", "vasp_gam", "vasp_ncl"])),
    )
    return AutoSlurmConfig(
        workflow=workflow,
        scheduler=scheduler,
        run=run,
        vasp=vasp,
        path=path,
        log_dir_value=str(paths_data.get("log_dir", "logs")),
        mirror_log_dir_value=str(paths_data.get("mirror_log_dir", "logs")),
        submit_script_value=str(paths_data.get("submit_script", "submit.sh")),
        monitor_interval=int(run_data.get("monitor_interval", 1800)),
        raw=data,
    )


def _normalize_legacy_config(data: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(data)
    paths = dict(normalized.get("paths") or {})
    run = dict(normalized.get("run") or {})
    vasp = dict(normalized.get("vasp") or {})
    workflow = dict(normalized.get("workflow") or {})
    scheduler = dict(normalized.get("scheduler") or {})
    if "input_dir" in paths and "input_dir" not in vasp:
        vasp["input_dir"] = paths["input_dir"]
    if "continue_from" in run and "continue_from" not in workflow:
        workflow["continue_from"] = run["continue_from"]
    if "max_iter" in run and "max_iter" not in workflow:
        workflow["max_iter"] = run["max_iter"]
    if "name" in run and "name" not in workflow:
        workflow["name"] = run["name"]
    if "nodes" in run and "nodes" not in scheduler:
        scheduler["nodes"] = run["nodes"]
    if "success_string" in run and "success_strings" not in vasp:
        vasp["success_strings"] = [run["success_string"]]
    if "executable" in vasp and "executable" not in run:
        run["executable"] = vasp["executable"]
    if "vasp_exe" in run and "executable" not in run:
        run["executable"] = run["vasp_exe"]
    normalized.update({"paths": paths, "run": run, "vasp": vasp, "workflow": workflow, "scheduler": scheduler})
    return normalized


def _legacy_overrides_to_nested(overrides: dict[str, Any]) -> dict[str, Any]:
    nested: dict[str, Any] = {}
    for key, value in overrides.items():
        if key == "code":
            nested.setdefault("workflow", {})["code"] = value
        elif key == "input_dir":
            nested.setdefault("vasp", {})["input_dir"] = value
        elif key in {"max_iter", "continue_from", "name"}:
            nested.setdefault("workflow", {})[key] = value
        elif key == "nodes":
            nested.setdefault("scheduler", {})["nodes"] = value
        elif key in {"vasp_exe", "vasp_executable", "executable"}:
            nested.setdefault("run", {})["executable"] = value
        elif key == "success_string":
            nested.setdefault("vasp", {})["success_strings"] = [value]
        elif key in {"log_dir", "mirror_log_dir", "submit_script"}:
            nested.setdefault("paths", {})[key] = value
        elif key == "monitor_interval":
            nested.setdefault("run", {})["monitor_interval"] = value
    return nested


def _load_structured_config(config_path: Path) -> dict[str, Any]:
    if config_path.suffix.lower() == ".toml":
        return _load_toml_subset(config_path)
    with config_path.open("r", encoding="utf-8") as handle:
        loaded = yaml.safe_load(handle) or {}
    if not isinstance(loaded, dict):
        raise ValueError(f"config must be a mapping: {config_path}")
    return loaded


def _load_toml_subset(config_path: Path) -> dict[str, Any]:
    data: dict[str, Any] = {}
    section: Optional[str] = None
    for raw_line in config_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
            data.setdefault(section, {})
            continue
        if "=" not in line:
            continue
        key, value = [part.strip() for part in line.split("=", 1)]
        if section:
            data.setdefault(section, {})[key] = _parse_toml_scalar(value)
        else:
            data[key] = _parse_toml_scalar(value)
    return data


def _parse_toml_scalar(value: str) -> Any:
    value = value.split(" #", 1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    if value.lower() in {"true", "false"}:
        return value.lower() == "true"
    try:
        return int(value)
    except ValueError:
        return value


def _resolve_path(base: Path, value: str) -> Path:
    path = Path(value)
    return path.resolve() if path.is_absolute() else (base / path).resolve()


def _detect_input_dir(workdir: Path) -> str:
    for candidate in ("input", "inputs", "INPUT", "INPUTS"):
        if (workdir / candidate).is_dir():
            return candidate
    return "input"


def _as_list(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(item) for item in value]
    return [str(value)]


def _positive_int(value: Any, field_name: str) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} must be an integer") from exc
    if parsed < 1:
        raise ValueError(f"{field_name} must be >= 1")
    return parsed


def render_default_config() -> str:
    return """workflow:
  code: vasp
  name: VASP-calc
  max_iter: 5

scheduler:
  type: slurm
  partition: cpu
  nodes: 5
  ntasks_per_node: 24
  walltime: "24:00:00"

run:
  executable: vasp_std
  mpi: mpiexec.hydra
  modules:
    - compilers/intel2017/composer_xe_2017/default

vasp:
  input_dir: input
  incar_start: INCAR.start
  incar_continue: INCAR.cont
  success_strings:
    - stopping structural energy minimisation
  carry:
    - WAVECAR
    - CHGCAR
"""
