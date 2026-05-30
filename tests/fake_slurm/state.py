import json
import os
from pathlib import Path
from typing import Any, Optional, Union


TERMINAL_STATES = {
    "COMPLETED",
    "FAILED",
    "TIMEOUT",
    "CANCELLED",
    "NODE_FAIL",
    "OUT_OF_MEMORY",
    "PREEMPTED",
}


class FakeSlurmError(RuntimeError):
    pass


def state_path_from_env(env: Optional[dict[str, str]] = None) -> Path:
    raw_path = (env or os.environ).get("FAKE_SLURM_STATE")
    if not raw_path:
        raise FakeSlurmError("FAKE_SLURM_STATE must point at a fake SLURM state file")
    return Path(raw_path)


def new_state() -> dict[str, Any]:
    return {
        "next_job_id": 1000,
        "planned_jobs": [],
        "jobs": {},
        "events": [],
    }


def init_state(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    save_state(new_state(), path)


def load_state(path: Optional[Path] = None) -> dict[str, Any]:
    path = path or state_path_from_env()
    if not path.exists():
        init_state(path)
    return json.loads(path.read_text(encoding="utf-8"))


def save_state(state: dict[str, Any], path: Optional[Path] = None) -> None:
    path = path or state_path_from_env()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")
    tmp_path.replace(path)


def normalize_squeue_entry(entry: Optional[Union[str, dict[str, Any]]]) -> dict[str, str]:
    if entry is None:
        return {"state": "MISSING", "elapsed": "00:00:00", "reason": ""}

    if isinstance(entry, str):
        state = entry.upper()
        elapsed = "00:00:00"
        if state == "RUNNING":
            elapsed = "00:01:00"
        return {"state": state, "elapsed": elapsed, "reason": ""}

    state = str(entry.get("state", "MISSING")).upper()
    return {
        "state": state,
        "elapsed": str(entry.get("elapsed", "00:00:00")),
        "reason": str(entry.get("reason", "")),
    }


def make_plan(
    *,
    squeue_states: Optional[list[Optional[Union[str, dict[str, Any]]]]] = None,
    sacct_state: str = "COMPLETED",
    exit_code: str = "0:0",
    reason: str = "",
    artifacts: Optional[Union[dict[str, str], list[dict[str, Any]]]] = None,
) -> dict[str, Any]:
    normalized_artifacts: list[dict[str, Any]] = []
    if isinstance(artifacts, dict):
        normalized_artifacts = [
            {"path": path, "content": content, "when": "terminal"}
            for path, content in artifacts.items()
        ]
    elif artifacts:
        normalized_artifacts = artifacts

    squeue_states = squeue_states or [sacct_state]
    return {
        "squeue": [normalize_squeue_entry(entry) for entry in squeue_states],
        "sacct": {
            "state": sacct_state.upper(),
            "exit_code": exit_code,
            "reason": reason,
        },
        "artifacts": normalized_artifacts,
    }
