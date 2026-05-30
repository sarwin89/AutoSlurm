from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from fake_slurm import FakeSlurmCluster


REPO_ROOT = Path(__file__).resolve().parents[1]
FIXTURES = REPO_ROOT / "tests" / "fixtures"
SUCCESS_STRING = "stopping structural energy minimisation"


def _copy_valid_input(job_dir: Path) -> Path:
    input_dir = job_dir / "input"
    shutil.copytree(FIXTURES / "vasp" / "valid-input", input_dir)
    return input_dir


def _write_submit_script(path: Path) -> Path:
    path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)
    return path


def _write_fake_sleep(bin_dir: Path) -> None:
    bin_dir.mkdir(parents=True, exist_ok=True)
    sleep = bin_dir / "sleep"
    sleep.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    sleep.chmod(0o755)


def _launcher_env(cluster: FakeSlurmCluster, tmp_path: Path) -> dict[str, str]:
    env = cluster.env()
    fast_bin = tmp_path / "fast-bin"
    _write_fake_sleep(fast_bin)
    env["PATH"] = os.pathsep.join([str(fast_bin), env["PATH"]])
    return env


def _run_launch(
    cluster: FakeSlurmCluster,
    tmp_path: Path,
    job_dir: Path,
    input_dir: Path,
    submit_script: Path,
    mirror_log_dir: Path,
    *,
    max_iter: int = 2,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            str(REPO_ROOT / "launch.sh"),
            "--workdir",
            str(job_dir),
            "--input-dir",
            str(input_dir),
            "--log-dir",
            str(job_dir / "logs"),
            "--mirror-log-dir",
            str(mirror_log_dir),
            "--submit-script",
            str(submit_script),
            "--name",
            "chain-test",
            "--continue-from",
            "1",
            "--max-iter",
            str(max_iter),
            "--monitor-interval",
            "60",
            "--success-string",
            SUCCESS_STRING,
            "--vasp-exe",
            "vasp_std",
        ],
        cwd=REPO_ROOT,
        env=_launcher_env(cluster, tmp_path),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
        check=False,
    )


def test_launch_iterative_vasp_chain_uses_sacct_state_and_writes_structured_logs(
    tmp_path: Path,
) -> None:
    job_dir = tmp_path / "job"
    mirror_log_dir = tmp_path / "mirror-logs"
    job_dir.mkdir()
    mirror_log_dir.mkdir()
    input_dir = _copy_valid_input(job_dir)
    submit_script = _write_submit_script(tmp_path / "submit.sh")
    cluster = FakeSlurmCluster(tmp_path / "fake-slurm.json")

    first_contcar = (FIXTURES / "vasp" / "contcar" / "valid.CONTCAR").read_text(encoding="utf-8")
    final_contcar = first_contcar.replace("relaxed cell", "final relaxed cell")
    cluster.plan_job(
        squeue_states=[{"state": "RUNNING", "elapsed": "00:00:05"}, "MISSING", "MISSING"],
        sacct_state="COMPLETED",
        exit_code="0:0",
        artifacts={
            "OUTCAR": (FIXTURES / "vasp" / "outcar" / "not-converged.OUTCAR").read_text(encoding="utf-8"),
            "CONTCAR": first_contcar,
            "WAVECAR": "wave restart 1\n",
            "CHGCAR": "charge restart 1\n",
        },
    )
    cluster.plan_job(
        squeue_states=[{"state": "RUNNING", "elapsed": "00:00:04"}, "MISSING", "MISSING"],
        sacct_state="COMPLETED",
        exit_code="0:0",
        artifacts={
            "OUTCAR": (FIXTURES / "vasp" / "outcar" / "success-default.OUTCAR").read_text(encoding="utf-8"),
            "CONTCAR": final_contcar,
        },
    )

    result = _run_launch(cluster, tmp_path, job_dir, input_dir, submit_script, mirror_log_dir)

    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert (job_dir / "iteration-1" / "INCAR").read_text(encoding="utf-8") == (
        input_dir / "INCAR.start"
    ).read_text(encoding="utf-8")
    assert (job_dir / "iteration-2" / "INCAR").read_text(encoding="utf-8") == (
        input_dir / "INCAR.cont"
    ).read_text(encoding="utf-8")
    assert (job_dir / "iteration-2" / "WAVECAR").read_text(encoding="utf-8") == "wave restart 1\n"
    assert (job_dir / "iteration-2" / "CHGCAR").read_text(encoding="utf-8") == "charge restart 1\n"
    assert (job_dir / "POSCAR").read_text(encoding="utf-8") == final_contcar
    assert "Final iteration: 2 / 2" in output

    state = json.loads((job_dir / "autoslurm-state.json").read_text(encoding="utf-8"))
    assert state["status"] == "completed"
    assert state["last_final_state"] == "COMPLETED"
    assert state["last_final_state_source"] == "sacct"
    assert state["last_completed_iteration"] == "2"

    events = [
        json.loads(line)
        for line in (job_dir / "autoslurm-events.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert any(event["event"] == "final_state" and event["source"] == "sacct" for event in events)
    assert any(event["event"] == "iteration_success" and event["iteration"] == "2" for event in events)
    assert events[-1]["event"] == "workflow_complete"

    status_result = subprocess.run(
        [sys.executable, "-m", "autoslurm", "status", "--workdir", str(job_dir), "--json"],
        cwd=REPO_ROOT,
        env={**os.environ, "PYTHONPATH": str(REPO_ROOT)},
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
        check=False,
    )
    assert status_result.returncode == 0, status_result.stdout + status_result.stderr
    status = json.loads(status_result.stdout)
    assert status["final_status"] == "completed"
    assert status["current_iteration"] == 2


def test_launch_fails_when_sacct_reports_failure_after_squeue_disappears(tmp_path: Path) -> None:
    job_dir = tmp_path / "job"
    mirror_log_dir = tmp_path / "mirror-logs"
    job_dir.mkdir()
    mirror_log_dir.mkdir()
    input_dir = _copy_valid_input(job_dir)
    submit_script = _write_submit_script(tmp_path / "submit.sh")
    cluster = FakeSlurmCluster(tmp_path / "fake-slurm.json")
    cluster.plan_job(
        squeue_states=[{"state": "RUNNING", "elapsed": "00:00:03"}, "MISSING", "MISSING"],
        sacct_state="FAILED",
        exit_code="1:0",
        reason="fake failure from accounting",
        artifacts={"OUTCAR": "", "CONTCAR": ""},
    )

    result = _run_launch(
        cluster,
        tmp_path,
        job_dir,
        input_dir,
        submit_script,
        mirror_log_dir,
        max_iter=1,
    )

    output = result.stdout + result.stderr
    assert result.returncode == 1, output
    assert "iteration failed in final state FAILED" in output
    state = json.loads((job_dir / "autoslurm-state.json").read_text(encoding="utf-8"))
    assert state["status"] == "failed"
    assert state["last_final_state"] == "FAILED"
    assert state["last_final_state_source"] == "sacct"
    events = [
        json.loads(line)
        for line in (job_dir / "autoslurm-events.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    assert any(event["event"] == "workflow_failure" for event in events)


def test_launch_writes_stopcar_and_labort_before_walltime(tmp_path: Path) -> None:
    job_dir = tmp_path / "job"
    mirror_log_dir = tmp_path / "mirror-logs"
    job_dir.mkdir()
    mirror_log_dir.mkdir()
    input_dir = _copy_valid_input(job_dir)
    submit_script = _write_submit_script(tmp_path / "submit.sh")
    cluster = FakeSlurmCluster(tmp_path / "fake-slurm.json")
    cluster.plan_job(
        squeue_states=[
            {"state": "RUNNING", "elapsed": "21:30:00"},
            {"state": "RUNNING", "elapsed": "23:00:00"},
            {"state": "COMPLETED", "elapsed": "23:01:00"},
        ],
        sacct_state="COMPLETED",
        exit_code="0:0",
        artifacts={
            "OUTCAR": (FIXTURES / "vasp" / "outcar" / "success-default.OUTCAR").read_text(encoding="utf-8"),
            "CONTCAR": (FIXTURES / "vasp" / "contcar" / "valid.CONTCAR").read_text(encoding="utf-8"),
        },
    )

    result = _run_launch(
        cluster,
        tmp_path,
        job_dir,
        input_dir,
        submit_script,
        mirror_log_dir,
        max_iter=1,
    )

    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    stopcar = (job_dir / "iteration-1" / "STOPCAR").read_text(encoding="utf-8")
    assert "LSTOP = .TRUE." in stopcar
    assert "LABORT = .TRUE." in stopcar
