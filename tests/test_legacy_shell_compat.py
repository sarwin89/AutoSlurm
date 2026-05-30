from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

import pytest


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
                'echo "fake submit"',
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
    mirror_log_dir = tmp_path / "mirror-logs"
    submit_script = tmp_path / "submit.sh"

    job_dir.mkdir()
    log_dir.mkdir()
    mirror_log_dir.mkdir()
    _write_inputs(input_dir)
    _write_submit_script(submit_script)
    return job_dir, input_dir, mirror_log_dir, submit_script


def _write_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _fake_scheduler_bin(bin_dir: Path) -> None:
    bin_dir.mkdir()
    for name in ("sbatch", "squeue", "scontrol", "sacct"):
        _write_executable(
            bin_dir / name,
            f"#!/bin/sh\necho fake {name}\nexit 0\n",
        )


def _env_with_path(bin_dir: Path | None = None) -> dict[str, str]:
    env = os.environ.copy()
    if bin_dir is not None:
        env["PATH"] = os.pathsep.join([str(bin_dir), env.get("PATH", "")])
    return env


def _run(command: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
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


def _skip_if_shebang_bash_lacks_associative_arrays() -> None:
    result = subprocess.run(
        ["/bin/bash", "-c", "declare -A seen"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        pytest.skip("reset-run.sh requires /bin/bash with associative array support")


def test_launch_validate_only_accepts_fake_job_layout(tmp_path: Path) -> None:
    job_dir, input_dir, mirror_log_dir, submit_script = _make_job(tmp_path)

    result = _run(
        [
            str(REPO_ROOT / "launch.sh"),
            "--validate-only",
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
            "--nodes",
            "2",
            "--vasp-exe",
            "/bin/true",
            "--continue-from",
            "1",
            "--max-iter",
            "2",
            "--monitor-interval",
            "60",
        ]
    )

    output = _assert_success(result)
    assert "Validation successful." in output
    assert str(job_dir) in output
    assert str(input_dir) in output
    assert str(submit_script) in output
    assert "Iterations:       1 -> 2" in output


def test_setup_check_uses_fake_scheduler_tools_and_launch_validation(tmp_path: Path) -> None:
    job_dir, input_dir, mirror_log_dir, submit_script = _make_job(tmp_path)
    bin_dir = tmp_path / "bin"
    _fake_scheduler_bin(bin_dir)

    result = _run(
        [
            str(REPO_ROOT / "setup-check.sh"),
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
        env=_env_with_path(bin_dir),
    )

    output = _assert_success(result)
    assert "AutoSlurm Setup Checker" in output
    assert "sbatch found" in output
    assert "squeue found" in output
    assert "launch.sh validation mode works" in output
    assert "Setup looks good" in output


def test_reset_run_removes_requested_iterations_and_logs(tmp_path: Path) -> None:
    _skip_if_shebang_bash_lacks_associative_arrays()

    job_dir, _input_dir, mirror_log_dir, _submit_script = _make_job(tmp_path)
    job_tag = "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in job_dir.name)

    keep_iter = job_dir / "iteration-1"
    remove_iter = job_dir / "iteration-2"
    retry_iter = job_dir / "iteration-3-retry"
    for path in (keep_iter, remove_iter, retry_iter):
        path.mkdir()
        (path / "CONTCAR").write_text("contcar\n", encoding="utf-8")

    for name in ("POSCAR", "WAVECAR", "CHGCAR", "job.123.out", "job.123.err", "chain_root.log"):
        (job_dir / name).write_text("runtime\n", encoding="utf-8")
    for name in ("chain_job.log", "launcher_20260101.log"):
        (job_dir / "logs" / name).write_text("log\n", encoding="utf-8")
    (mirror_log_dir / f"chain_{job_tag}_20260101.log").write_text("mirror\n", encoding="utf-8")

    result = _run(
        [
            str(REPO_ROOT / "reset-run.sh"),
            "--workdir",
            str(job_dir),
            "--log-dir",
            str(job_dir / "logs"),
            "--mirror-log-dir",
            str(mirror_log_dir),
            "--from-iter",
            "2",
            "--yes",
        ]
    )

    output = _assert_success(result)
    assert "Cleanup complete." in output
    assert keep_iter.exists()
    assert not remove_iter.exists()
    assert not retry_iter.exists()
    assert (job_dir / "POSCAR").exists()
    assert (job_dir / "WAVECAR").exists()
    assert (job_dir / "CHGCAR").exists()
    assert not (job_dir / "job.123.out").exists()
    assert not (job_dir / "job.123.err").exists()
    assert not (job_dir / "chain_root.log").exists()
    assert not (job_dir / "logs" / "chain_job.log").exists()
    assert not (job_dir / "logs" / "launcher_20260101.log").exists()
    assert not (mirror_log_dir / f"chain_{job_tag}_20260101.log").exists()
