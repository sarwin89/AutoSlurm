import os
from pathlib import Path
from typing import Any, Optional, Union

from .state import init_state, load_state, make_plan, save_state


class FakeSlurmCluster:
    """Small file-backed fake SLURM cluster for subprocess-based tests."""

    bin_dir = Path(__file__).resolve().with_name("bin")

    def __init__(self, state_path: Path):
        self.state_path = Path(state_path)
        init_state(self.state_path)

    def env(self, base: Optional[dict[str, str]] = None) -> dict[str, str]:
        env = dict(os.environ if base is None else base)
        env["FAKE_SLURM_STATE"] = str(self.state_path)
        env["PATH"] = f"{self.bin_dir}{os.pathsep}{env.get('PATH', '')}"
        return env

    def plan_job(
        self,
        *,
        squeue_states: Optional[list[Optional[Union[str, dict[str, Any]]]]] = None,
        sacct_state: str = "COMPLETED",
        exit_code: str = "0:0",
        reason: str = "",
        artifacts: Optional[Union[dict[str, str], list[dict[str, Any]]]] = None,
    ) -> None:
        state = load_state(self.state_path)
        state["planned_jobs"].append(
            make_plan(
                squeue_states=squeue_states,
                sacct_state=sacct_state,
                exit_code=exit_code,
                reason=reason,
                artifacts=artifacts,
            )
        )
        save_state(state, self.state_path)

    def job(self, job_id: Union[str, int]) -> dict[str, Any]:
        return load_state(self.state_path)["jobs"][str(job_id)]

    def jobs(self) -> dict[str, Any]:
        return load_state(self.state_path)["jobs"]

    def events(self) -> list[dict[str, Any]]:
        return load_state(self.state_path)["events"]
