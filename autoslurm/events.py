from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional


def utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


@dataclass
class EventLog:
    path: Path

    def append(
        self,
        event: str,
        *,
        workflow_id: Optional[str] = None,
        iteration: Optional[int] = None,
        job_id: Optional[str] = None,
        state: Optional[str] = None,
        message: Optional[str] = None,
        data: Optional[dict[str, Any]] = None,
    ) -> dict[str, Any]:
        record = {
            "timestamp": utc_now(),
            "event": event,
            "workflow_id": workflow_id,
            "iteration": iteration,
            "job_id": job_id,
            "state": state,
            "message": message,
            "data": data or {},
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.path.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
        return record


def default_event_log(workdir: Path) -> EventLog:
    return EventLog(workdir / "autoslurm-events.jsonl")
