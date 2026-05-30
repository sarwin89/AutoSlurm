from __future__ import annotations

import os
import shutil
import subprocess
import time
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Optional

from .results import CheckResult, error, ok, warn


class SlurmJobState(Enum):
    PENDING = "PENDING"
    RUNNING = "RUNNING"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"
    CANCELLED = "CANCELLED"
    TIMEOUT = "TIMEOUT"
    OUT_OF_MEMORY = "OUT_OF_MEMORY"
    NODE_FAIL = "NODE_FAIL"
    PREEMPTED = "PREEMPTED"
    MISSING = "MISSING"
    UNKNOWN = "UNKNOWN"


TERMINAL_SUCCESS_STATES = {SlurmJobState.COMPLETED}
TERMINAL_FAILURE_STATES = {
    SlurmJobState.FAILED,
    SlurmJobState.CANCELLED,
    SlurmJobState.TIMEOUT,
    SlurmJobState.OUT_OF_MEMORY,
    SlurmJobState.NODE_FAIL,
    SlurmJobState.PREEMPTED,
}


@dataclass(frozen=True)
class SlurmStatus:
    job_id: str
    state: SlurmJobState
    source: str
    exit_code: Optional[str] = None
    elapsed: Optional[str] = None
    reason: Optional[str] = None
    raw: str = ""

    @property
    def ok(self) -> bool:
        return self.state in TERMINAL_SUCCESS_STATES

    @property
    def is_terminal(self) -> bool:
        return self.state in TERMINAL_SUCCESS_STATES or self.state in TERMINAL_FAILURE_STATES


class SlurmScheduler:
    def __init__(
        self,
        *,
        env: Optional[dict[str, str]] = None,
        poll_interval: float = 5,
        runner: Optional["CommandRunner"] = None,
    ):
        self.env = dict(os.environ if env is None else env)
        self.poll_interval = poll_interval
        self.runner = runner or CommandRunner(self.env)

    def check_commands(self) -> list[CheckResult]:
        results: list[CheckResult] = []
        path = self.env.get("PATH")
        for command in ("sbatch", "squeue", "sacct", "scancel"):
            found = shutil.which(command, path=path)
            if found:
                results.append(ok("scheduler.command_found", f"{command} found", Path(found)))
            elif command == "sacct":
                results.append(warn("scheduler.sacct_missing", "sacct not found; final-state detection is limited"))
            elif command == "scancel":
                results.append(warn("scheduler.scancel_missing", "scancel not found; cancellation is unavailable"))
            else:
                results.append(error("scheduler.command_missing", f"{command} not found"))
        return results

    def submit(
        self,
        script: Path,
        *,
        chdir: Optional[Path] = None,
        job_name: Optional[str] = None,
        output: Optional[Path] = None,
        error: Optional[Path] = None,
        nodes: Optional[int] = None,
        export: Optional[dict[str, str]] = None,
        extra_args: Optional[list[str]] = None,
    ) -> str:
        command = ["sbatch", "--parsable"]
        if chdir is not None:
            command.extend(["--chdir", str(chdir)])
        if job_name:
            command.extend(["--job-name", job_name])
        if output is not None:
            command.extend(["--output", str(output)])
        if error is not None:
            command.extend(["--error", str(error)])
        if nodes is not None:
            command.extend(["--nodes", str(nodes)])
        if export:
            exports = ",".join(f"{key}={value}" for key, value in export.items())
            command.extend(["--export", f"ALL,{exports}"])
        if extra_args:
            command.extend(extra_args)
        command.append(str(script))
        result = self.runner.run(command, cwd=chdir)
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "sbatch failed")
        job_id = result.stdout.strip().splitlines()[0].split(";")[0]
        if not job_id.isdigit():
            raise RuntimeError(f"sbatch did not return a numeric job id: {job_id!r}")
        return job_id

    def status(self, job_id: str) -> SlurmStatus:
        queue_status = self.queue_state(job_id)
        if queue_status.state is not SlurmJobState.MISSING:
            return queue_status
        accounting_status = self.accounting_state(job_id)
        if accounting_status.state is SlurmJobState.UNKNOWN:
            return queue_status
        return accounting_status

    def wait(
        self,
        job_id: str,
        *,
        timeout: Optional[float] = None,
        poll_interval: Optional[float] = None,
    ) -> SlurmStatus:
        interval = self.poll_interval if poll_interval is None else poll_interval
        deadline = None if timeout is None else time.monotonic() + timeout
        last_status = self.status(job_id)
        missing_seen = last_status.state is SlurmJobState.MISSING
        while True:
            if last_status.is_terminal:
                if last_status.source == "squeue":
                    accounting = self.accounting_state(job_id)
                    return accounting if accounting.state is not SlurmJobState.UNKNOWN else last_status
                return last_status
            if last_status.state is SlurmJobState.MISSING:
                if missing_seen:
                    accounting = self.accounting_state(job_id)
                    return accounting if accounting.state is not SlurmJobState.UNKNOWN else last_status
                missing_seen = True
            else:
                missing_seen = False
            if deadline is not None and time.monotonic() >= deadline:
                return last_status
            if interval:
                time.sleep(interval)
            last_status = self.status(job_id)

    def queue_state(self, job_id: str) -> SlurmStatus:
        result = self.runner.run(["squeue", "-h", "-j", str(job_id), "-o", "%T|%M|%R"])
        if result.returncode != 0 or not result.stdout.strip():
            return SlurmStatus(str(job_id), SlurmJobState.MISSING, "squeue", raw=result.stderr.strip())
        line = result.stdout.strip().splitlines()[0]
        parts = line.split("|")
        return SlurmStatus(
            str(job_id),
            normalize_slurm_state(parts[0] if parts else ""),
            "squeue",
            elapsed=parts[1] if len(parts) > 1 else None,
            reason=parts[2] if len(parts) > 2 else None,
            raw=line,
        )

    def accounting_state(self, job_id: str) -> SlurmStatus:
        result = self.runner.run(
            ["sacct", "-n", "-P", "-j", str(job_id), "-o", "JobIDRaw,State,ExitCode,Elapsed,Reason"]
        )
        if result.returncode != 0 or not result.stdout.strip():
            return SlurmStatus(str(job_id), SlurmJobState.UNKNOWN, "sacct", raw=result.stderr.strip())
        selected = ""
        for line in result.stdout.strip().splitlines():
            parts = line.split("|")
            if parts and parts[0] == str(job_id):
                selected = line
                break
            if not selected:
                selected = line
        parts = selected.split("|")
        offset = 1 if parts and parts[0] == str(job_id) else 0
        return SlurmStatus(
            str(job_id),
            normalize_slurm_state(parts[offset] if len(parts) > offset else ""),
            "sacct",
            exit_code=parts[offset + 1] if len(parts) > offset + 1 else None,
            elapsed=parts[offset + 2] if len(parts) > offset + 2 else None,
            reason=parts[offset + 3] if len(parts) > offset + 3 else None,
            raw=selected,
        )

    def final_state(self, job_id: str) -> SlurmStatus:
        return self.status(job_id)

    def cancel(self, job_id: str) -> None:
        result = self.runner.run(["scancel", str(job_id)])
        if result.returncode != 0:
            raise RuntimeError(result.stderr.strip() or result.stdout.strip() or "scancel failed")


class CommandRunner:
    def __init__(self, env: Optional[dict[str, str]] = None):
        self.env = env

    def run(self, args: list[str], cwd: Optional[Path] = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            args,
            cwd=str(cwd) if cwd else None,
            env=self.env,
            check=False,
            text=True,
            capture_output=True,
        )


def normalize_slurm_state(state: str) -> SlurmJobState:
    normalized = (state or "UNKNOWN").strip().upper().split()[0].split("+")[0]
    if normalized.startswith("CANCELLED"):
        normalized = "CANCELLED"
    return SlurmJobState.__members__.get(normalized, SlurmJobState.UNKNOWN)
