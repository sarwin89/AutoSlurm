from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _write_inputs(input_dir: Path) -> None:
    input_dir.mkdir(parents=True)
    for name in ("INCAR.start", "INCAR.cont", "KPOINTS", "POSCAR", "POTCAR"):
        (input_dir / name).write_text(f"fake {name}\n", encoding="utf-8")


def _write_submit_script(path: Path) -> None:
    path.write_text(
        "\n".join(
            [
                "#!/bin/bash",
                "#SBATCH -N 1",
                "#SBATCH --ntasks-per-node=1",
                "#SBATCH --time=24:00:00",
                "set -euo pipefail",
                'echo "fake submit should not run in validation tests"',
                "",
            ]
        ),
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _make_job(tmp_path: Path) -> tuple[Path, Path, Path, Path]:
    job_dir = tmp_path / "job"
    input_dir = job_dir / "input"
    log_dir = job_dir / "logs"
    mirror_log_dir = tmp_path / "autoslurm-logs"
    submit_script = tmp_path / "submit.sh"

    job_dir.mkdir()
    log_dir.mkdir()
    mirror_log_dir.mkdir()
    _write_inputs(input_dir)
    _write_submit_script(submit_script)
    return job_dir, input_dir, mirror_log_dir, submit_script


def _python_env(tmp_path: Path, bin_dir: Path | None = None) -> dict[str, str]:
    env = os.environ.copy()
    pythonpath = [str(REPO_ROOT), str(REPO_ROOT / "src")]
    if env.get("PYTHONPATH"):
        pythonpath.append(env["PYTHONPATH"])
    env["PYTHONPATH"] = os.pathsep.join(pythonpath)
    if bin_dir is not None:
        env["PATH"] = os.pathsep.join([str(bin_dir), env.get("PATH", "")])
    env["AUTOSLURM_TEST_TMP"] = str(tmp_path)
    return env


def _write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _fake_sbatch_that_must_not_run(bin_dir: Path, marker: Path) -> None:
    bin_dir.mkdir()
    _write_executable(
        bin_dir / "sbatch",
        f"#!/bin/sh\nprintf invoked > '{marker!s}'\nexit 98\n",
    )


def _fake_scheduler_bin(bin_dir: Path) -> None:
    bin_dir.mkdir()
    for name in ("sbatch", "squeue", "scontrol", "sacct"):
        _write_executable(
            bin_dir / name,
            f"#!/bin/sh\necho fake {name}\nexit 0\n",
        )


def _run(command: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=REPO_ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=20,
        check=False,
    )


def _assert_success(result: subprocess.CompletedProcess[str]) -> str:
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    return output


def test_python_check_validates_job_without_submitting(tmp_path: Path) -> None:
    job_dir, input_dir, mirror_log_dir, submit_script = _make_job(tmp_path)
    bin_dir = tmp_path / "bin"
    sbatch_marker = tmp_path / "sbatch-was-called"
    _fake_sbatch_that_must_not_run(bin_dir, sbatch_marker)

    result = _run(
        [
            sys.executable,
            "-m",
            "autoslurm",
            "check",
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
        ],
        env=_python_env(tmp_path, bin_dir),
    )

    output = _assert_success(result)
    assert str(job_dir) in output
    assert str(input_dir) in output
    assert str(submit_script) in output
    assert not sbatch_marker.exists(), output


def test_python_doctor_runs_against_fake_scheduler_tools(tmp_path: Path) -> None:
    job_dir, input_dir, mirror_log_dir, submit_script = _make_job(tmp_path)
    bin_dir = tmp_path / "bin"
    _fake_scheduler_bin(bin_dir)

    result = _run(
        [
            sys.executable,
            "-m",
            "autoslurm",
            "doctor",
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
        ],
        env=_python_env(tmp_path, bin_dir),
    )

    output = _assert_success(result)
    assert str(job_dir) in output
    assert "sbatch" in output
    assert "squeue" in output


def test_init_config_can_be_checked_without_job_local_submit_script(tmp_path: Path) -> None:
    job_dir, _input_dir, _mirror_log_dir, submit_script = _make_job(tmp_path)
    submit_script.unlink()

    init_result = _run(
        [sys.executable, "-m", "autoslurm", "init", "--workdir", str(job_dir)],
        env=_python_env(tmp_path),
    )
    _assert_success(init_result)

    check_result = _run(
        [sys.executable, "-m", "autoslurm", "check", "--workdir", str(job_dir)],
        env=_python_env(tmp_path),
    )

    output = _assert_success(check_result)
    assert str(REPO_ROOT / "submit.sh") in output


def test_status_reads_legacy_launcher_state_schema(tmp_path: Path) -> None:
    job_dir = tmp_path / "job"
    job_dir.mkdir()
    (job_dir / "autoslurm-state.json").write_text(
        (
            "{\n"
            '  "run_id": "run-123",\n'
            '  "job_prefix": "chain",\n'
            '  "status": "completed",\n'
            '  "current_iteration": "2",\n'
            '  "current_job_id": "1001",\n'
            '  "last_final_state": "COMPLETED"\n'
            "}\n"
        ),
        encoding="utf-8",
    )

    result = _run(
        [sys.executable, "-m", "autoslurm", "status", "--workdir", str(job_dir), "--json"],
        env=_python_env(tmp_path),
    )

    output = _assert_success(result)
    status = json.loads(output)
    assert status["workflow_id"] == "run-123"
    assert status["name"] == "chain"
    assert status["final_status"] == "completed"
    assert status["current_iteration"] == 2
    assert status["job_states"] == {"1001": "COMPLETED"}
