import subprocess
import sys
from pathlib import Path
from typing import Optional

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fake_slurm import FakeSlurmCluster


def _submit_script(tmp_path: Path) -> Path:
    script = tmp_path / "submit.sh"
    script.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    script.chmod(0o755)
    return script


def _run_slurm(cluster: FakeSlurmCluster, *argv: str, cwd: Optional[Path] = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(argv),
        cwd=cwd,
        env=cluster.env(),
        text=True,
        capture_output=True,
        check=True,
    )


def _scheduler_api():
    try:
        from autoslurm.scheduler import SlurmJobState, SlurmScheduler
    except ModuleNotFoundError as exc:
        if exc.name in {"autoslurm", "autoslurm.scheduler"}:
            pytest.fail(
                "Expected scheduler API is missing: "
                "from autoslurm.scheduler import SlurmScheduler, SlurmJobState"
            )
        raise
    return SlurmScheduler, SlurmJobState


@pytest.mark.parametrize(
    ("terminal_state", "exit_code"),
    [
        ("COMPLETED", "0:0"),
        ("FAILED", "1:0"),
        ("TIMEOUT", "0:1"),
        ("CANCELLED", "0:15"),
        ("OUT_OF_MEMORY", "0:125"),
        ("PREEMPTED", "0:0"),
    ],
)
def test_fake_slurm_sbatch_squeue_and_sacct_cover_job_states(
    tmp_path: Path, terminal_state: str, exit_code: str
) -> None:
    cluster = FakeSlurmCluster(tmp_path / "fake-slurm.json")
    reason = terminal_state.lower()
    cluster.plan_job(
        squeue_states=[
            "PENDING",
            {"state": "RUNNING", "elapsed": "00:01:08"},
            {"state": terminal_state, "elapsed": "00:03:14", "reason": reason},
        ],
        sacct_state=terminal_state,
        exit_code=exit_code,
        reason=reason,
    )

    job_id = _run_slurm(
        cluster,
        "sbatch",
        "--parsable",
        "--chdir",
        str(tmp_path),
        "--job-name",
        f"case-{terminal_state.lower()}",
        "--output",
        str(tmp_path / "job.%J.out"),
        "--error",
        str(tmp_path / "job.%J.err"),
        str(_submit_script(tmp_path)),
    ).stdout.strip()

    assert job_id == "1000"
    assert _run_slurm(cluster, "squeue", "-h", "-j", job_id, "-o", "%T|%M").stdout.strip() == (
        "PENDING|00:00:00"
    )
    assert _run_slurm(cluster, "squeue", "-h", "-j", job_id, "-o", "%T|%M").stdout.strip() == (
        "RUNNING|00:01:08"
    )
    assert _run_slurm(cluster, "squeue", "-h", "-j", job_id, "-o", "%T|%M|%R").stdout.strip() == (
        f"{terminal_state}|00:03:14|{reason}"
    )
    assert _run_slurm(
        cluster,
        "sacct",
        "-n",
        "-P",
        "-j",
        job_id,
        "-o",
        "JobID,State,ExitCode,Reason",
    ).stdout.strip() == f"{job_id}|{terminal_state}|{exit_code}|{reason}"


def test_fake_slurm_scancel_marks_job_cancelled(tmp_path: Path) -> None:
    cluster = FakeSlurmCluster(tmp_path / "fake-slurm.json")
    cluster.plan_job(squeue_states=["PENDING", "RUNNING", "RUNNING"], sacct_state="COMPLETED")

    job_id = _run_slurm(cluster, "sbatch", "--parsable", str(_submit_script(tmp_path))).stdout.strip()
    _run_slurm(cluster, "scancel", job_id)

    assert _run_slurm(cluster, "squeue", "-h", "-j", job_id, "-o", "%T|%R").stdout.strip() == (
        "CANCELLED|Cancelled by fake scancel"
    )
    assert _run_slurm(cluster, "sacct", "-n", "-P", "-j", job_id, "-o", "State,ExitCode").stdout.strip() == (
        "CANCELLED|0:15"
    )


def test_fake_slurm_can_disappear_from_squeue_but_fail_in_sacct(tmp_path: Path) -> None:
    cluster = FakeSlurmCluster(tmp_path / "fake-slurm.json")
    cluster.plan_job(
        squeue_states=[{"state": "RUNNING", "elapsed": "00:05:00"}, "MISSING"],
        sacct_state="FAILED",
        exit_code="9:0",
        reason="launch failed after leaving queue",
    )

    job_id = _run_slurm(cluster, "sbatch", "--parsable", str(_submit_script(tmp_path))).stdout.strip()

    assert _run_slurm(cluster, "squeue", "-h", "-j", job_id, "-o", "%T|%M").stdout.strip() == (
        "RUNNING|00:05:00"
    )
    assert _run_slurm(cluster, "squeue", "-h", "-j", job_id, "-o", "%T|%M").stdout == ""
    assert _run_slurm(cluster, "sacct", "-n", "-P", "-j", job_id, "-o", "State,ExitCode,Reason").stdout.strip() == (
        "FAILED|9:0|launch failed after leaving queue"
    )


def test_scheduler_contract_submits_and_waits_for_success(tmp_path: Path) -> None:
    SlurmScheduler, SlurmJobState = _scheduler_api()
    cluster = FakeSlurmCluster(tmp_path / "fake-slurm.json")
    cluster.plan_job(
        squeue_states=[
            "PENDING",
            {"state": "RUNNING", "elapsed": "00:00:08"},
            {"state": "COMPLETED", "elapsed": "00:00:16"},
        ],
        sacct_state="COMPLETED",
        exit_code="0:0",
    )

    scheduler = SlurmScheduler(env=cluster.env(), poll_interval=0)
    job_id = scheduler.submit(
        script=_submit_script(tmp_path),
        chdir=tmp_path,
        job_name="success-case",
        output=tmp_path / "job.%J.out",
        error=tmp_path / "job.%J.err",
        nodes=2,
        export={"VASP_EXE": "vasp_std"},
    )

    recorded_job = cluster.job(job_id)
    assert recorded_job["submit_options"]["nodes"] == "2"
    assert recorded_job["submit_options"]["job_name"] == "success-case"
    assert recorded_job["submit_options"]["export"] == "ALL,VASP_EXE=vasp_std"
    assert scheduler.status(job_id).state is SlurmJobState.PENDING
    assert scheduler.status(job_id).state is SlurmJobState.RUNNING

    final_status = scheduler.wait(job_id, timeout=1, poll_interval=0)
    assert final_status.state is SlurmJobState.COMPLETED
    assert final_status.exit_code == "0:0"
    assert final_status.ok is True
    assert final_status.is_terminal is True


@pytest.mark.parametrize(
    ("terminal_state", "enum_name", "exit_code"),
    [
        ("FAILED", "FAILED", "1:0"),
        ("TIMEOUT", "TIMEOUT", "0:1"),
        ("CANCELLED", "CANCELLED", "0:15"),
        ("OUT_OF_MEMORY", "OUT_OF_MEMORY", "0:125"),
        ("PREEMPTED", "PREEMPTED", "0:0"),
    ],
)
def test_scheduler_contract_maps_terminal_failures(
    tmp_path: Path, terminal_state: str, enum_name: str, exit_code: str
) -> None:
    SlurmScheduler, SlurmJobState = _scheduler_api()
    cluster = FakeSlurmCluster(tmp_path / "fake-slurm.json")
    cluster.plan_job(
        squeue_states=[{"state": terminal_state, "elapsed": "00:02:00"}],
        sacct_state=terminal_state,
        exit_code=exit_code,
        reason=f"fake {terminal_state}",
    )

    scheduler = SlurmScheduler(env=cluster.env(), poll_interval=0)
    job_id = scheduler.submit(script=_submit_script(tmp_path), chdir=tmp_path, job_name="failure-case")

    final_status = scheduler.wait(job_id, timeout=1, poll_interval=0)
    assert final_status.state is getattr(SlurmJobState, enum_name)
    assert final_status.exit_code == exit_code
    assert final_status.ok is False
    assert final_status.is_terminal is True


def test_scheduler_contract_checks_sacct_when_job_disappears_from_squeue(tmp_path: Path) -> None:
    SlurmScheduler, SlurmJobState = _scheduler_api()
    cluster = FakeSlurmCluster(tmp_path / "fake-slurm.json")
    cluster.plan_job(
        squeue_states=[{"state": "RUNNING", "elapsed": "00:04:00"}, "MISSING", "MISSING"],
        sacct_state="FAILED",
        exit_code="9:0",
        reason="failed after leaving queue",
    )

    scheduler = SlurmScheduler(env=cluster.env(), poll_interval=0)
    job_id = scheduler.submit(script=_submit_script(tmp_path), chdir=tmp_path, job_name="missing-case")

    assert scheduler.status(job_id).state is SlurmJobState.RUNNING
    final_status = scheduler.wait(job_id, timeout=1, poll_interval=0)
    assert final_status.state is SlurmJobState.FAILED
    assert final_status.exit_code == "9:0"
    assert final_status.reason == "failed after leaving queue"
    assert final_status.ok is False


def test_scheduler_contract_cancel_delegates_to_scancel(tmp_path: Path) -> None:
    SlurmScheduler, SlurmJobState = _scheduler_api()
    cluster = FakeSlurmCluster(tmp_path / "fake-slurm.json")
    cluster.plan_job(squeue_states=["RUNNING", "RUNNING"], sacct_state="COMPLETED")

    scheduler = SlurmScheduler(env=cluster.env(), poll_interval=0)
    job_id = scheduler.submit(script=_submit_script(tmp_path), chdir=tmp_path, job_name="cancel-case")

    scheduler.cancel(job_id)
    status = scheduler.status(job_id)
    assert status.state is SlurmJobState.CANCELLED
    assert status.ok is False
    assert status.is_terminal is True
