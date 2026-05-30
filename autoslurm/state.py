from __future__ import annotations

import json
import uuid
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Optional

from .events import utc_now


@dataclass
class WorkflowState:
    workflow_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    code: str = "vasp"
    name: str = "VASP-calc"
    current_iteration: int = 0
    submitted_job_ids: list[str] = field(default_factory=list)
    job_states: dict[str, str] = field(default_factory=dict)
    input_hashes: dict[str, str] = field(default_factory=dict)
    output_hashes: dict[str, str] = field(default_factory=dict)
    restart_files_used: list[str] = field(default_factory=list)
    final_status: str = "not_started"
    failure_reason: Optional[str] = None
    created_at: str = field(default_factory=utc_now)
    updated_at: str = field(default_factory=utc_now)

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "WorkflowState":
        allowed = set(cls.__dataclass_fields__)
        return cls(**{key: value for key, value in data.items() if key in allowed})


class StateStore:
    def __init__(self, path: Path):
        self.path = path

    def load(self) -> WorkflowState:
        if not self.path.is_file():
            return WorkflowState()
        with self.path.open("r", encoding="utf-8") as handle:
            data = json.load(handle)
        if not isinstance(data, dict):
            raise ValueError(f"state file must contain a JSON object: {self.path}")
        return WorkflowState.from_dict(data)

    def save(self, state: WorkflowState) -> WorkflowState:
        state.updated_at = utc_now()
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self.path.with_suffix(self.path.suffix + ".tmp")
        with tmp_path.open("w", encoding="utf-8") as handle:
            json.dump(state.to_dict(), handle, indent=2, sort_keys=True)
            handle.write("\n")
        tmp_path.replace(self.path)
        return state


def default_state_store(workdir: Path) -> StateStore:
    return StateStore(workdir / "autoslurm-state.json")
