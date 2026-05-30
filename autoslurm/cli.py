from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

from . import __version__
from .config import apply_cli_overrides, load_config, render_default_config
from .events import default_event_log
from .plugins.vasp import VaspProfile
from .results import CheckResult, error, ok, warn
from .scheduler import SlurmScheduler
from .state import WorkflowState, default_state_store


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="autoslurm")
    parser.add_argument("--version", action="version", version=f"autoslurm {__version__}")
    subparsers = parser.add_subparsers(dest="command")

    init_parser = subparsers.add_parser("init")
    init_parser.add_argument("--workdir", default=".")
    init_parser.add_argument("--force", action="store_true")

    for command in ("check", "doctor", "run"):
        command_parser = subparsers.add_parser(command)
        add_common_args(command_parser)
        if command == "doctor":
            command_parser.add_argument("--fix", action="store_true")
        if command == "run":
            command_parser.add_argument("--dry-run", action="store_true")
            command_parser.add_argument("--legacy-launcher", default=None)

    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--workdir", default=".")
    status_parser.add_argument("--json", action="store_true")

    reset_parser = subparsers.add_parser("reset")
    reset_parser.add_argument("--workdir", default=".")
    reset_parser.add_argument("--from-iter", type=int, default=None)
    reset_parser.add_argument("--yes", "-y", action="store_true")

    cancel_parser = subparsers.add_parser("cancel")
    cancel_parser.add_argument("job_id")

    for command in ("monitor", "resume", "summarize", "tail", "test-scheduler"):
        subparsers.add_parser(command)

    return parser


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--workdir", default=".")
    parser.add_argument("--config", default=None)
    parser.add_argument("--code", default=None)
    parser.add_argument("--input-dir", default=None)
    parser.add_argument("--log-dir", default=None)
    parser.add_argument("--mirror-log-dir", default=None)
    parser.add_argument("--submit-script", default=None)
    parser.add_argument("--name", default=None)
    parser.add_argument("--max-iter", type=int, default=None)
    parser.add_argument("--continue-from", type=int, default=None)
    parser.add_argument("--executable", default=None)
    parser.add_argument("--vasp-exe", default=None)
    parser.add_argument("--nodes", type=int, default=None)
    parser.add_argument("--monitor-interval", type=int, default=None)
    parser.add_argument("--success-string", default=None)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--write-state", action="store_true")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command is None:
        parser.print_help()
        return 2
    if args.command == "init":
        return cmd_init(args)
    if args.command in {"check", "doctor"}:
        return cmd_check(args, doctor=args.command == "doctor")
    if args.command == "run":
        return cmd_run(args)
    if args.command == "status":
        return cmd_status(args)
    if args.command == "reset":
        return cmd_reset(args)
    if args.command == "cancel":
        SlurmScheduler().cancel(args.job_id)
        print(f"cancelled {args.job_id}")
        return 0
    if args.command == "test-scheduler":
        return cmd_test_scheduler()
    print(f"`autoslurm {args.command}` is planned; use check/doctor/status/run --dry-run today.")
    return 0


def cmd_init(args: argparse.Namespace) -> int:
    workdir = Path(args.workdir).resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    config_path = workdir / "autoslurm.yaml"
    if config_path.exists() and not args.force:
        print(f"config already exists: {config_path}", file=sys.stderr)
        return 1
    config_path.write_text(render_default_config(), encoding="utf-8")
    print(f"wrote {config_path}")
    return 0


def load_with_overrides(args: argparse.Namespace):
    workdir = Path(args.workdir).resolve()
    config = load_config(args.config, workdir)
    return workdir, apply_cli_overrides(
        config,
        code=args.code,
        name=args.name,
        input_dir=args.input_dir,
        max_iter=args.max_iter,
        continue_from=args.continue_from,
        executable=args.executable or args.vasp_exe,
        nodes=args.nodes,
        log_dir=args.log_dir,
        mirror_log_dir=args.mirror_log_dir,
        submit_script=args.submit_script,
        monitor_interval=args.monitor_interval,
        success_string=args.success_string,
    )


def cmd_check(args: argparse.Namespace, *, doctor: bool = False) -> int:
    try:
        workdir, config = load_with_overrides(args)
        results = run_checks(workdir, config, doctor=doctor)
    except Exception as exc:
        workdir = Path(args.workdir).resolve()
        config = None
        results = [error("config.load_failed", str(exc))]
    if args.write_state and config is not None:
        write_check_state(workdir, config, results)
    if args.json:
        print(json.dumps([result.to_dict() for result in results], indent=2, sort_keys=True))
    else:
        print_results(results)
    has_errors = any(result.is_error for result in results)
    has_warnings = any(result.is_warning for result in results)
    return 1 if has_errors or (args.strict and has_warnings) else 0


def run_checks(workdir: Path, config, *, doctor: bool = False) -> list[CheckResult]:
    if not workdir.is_dir():
        return [error("project.workdir_missing", f"workdir not found: {workdir}", workdir)]
    results: list[CheckResult] = [
        ok("config.loaded", f"config loaded: {config.path or 'defaults'}"),
        ok("project.workdir_found", f"workdir found: {workdir}", workdir),
        ok("paths.input_dir", f"input dir: {config.input_dir}", config.input_dir),
        ok("paths.log_dir", f"log dir: {config.log_dir}", config.log_dir),
        ok("paths.mirror_log_dir", f"mirror log dir: {config.mirror_log_dir}", config.mirror_log_dir),
    ]
    if config.submit_script.is_file():
        results.append(ok("paths.submit_script", f"submit script: {config.submit_script}", config.submit_script))
    else:
        results.append(error("paths.submit_script_missing", f"submit script not found: {config.submit_script}", config.submit_script))
    if config.workflow.code == "vasp":
        results.extend(VaspProfile().validate_inputs(workdir, config))
    else:
        results.append(warn("workflow.unsupported_code", f"{config.workflow.code} is planned; VASP is supported first"))
    if doctor:
        results.extend(check_legacy_scripts(Path(__file__).resolve().parents[1]))
        if config.scheduler.type == "slurm":
            results.extend(SlurmScheduler().check_commands())
    return results


def check_legacy_scripts(repo_dir: Path) -> list[CheckResult]:
    results: list[CheckResult] = []
    for script in ("launch.sh", "setup-check.sh", "reset-run.sh", "submit.sh"):
        path = repo_dir / script
        results.append(ok("legacy.script_found", f"found {script}", path) if path.is_file() else error("legacy.script_missing", f"missing {script}", path))
    return results


def write_check_state(workdir: Path, config, results: list[CheckResult]) -> None:
    state = WorkflowState(
        code=config.workflow.code,
        name=config.workflow.name,
        current_iteration=config.workflow.continue_from,
        input_hashes=VaspProfile().input_hashes(workdir, config) if config.workflow.code == "vasp" else {},
        final_status="check_failed" if any(result.is_error for result in results) else "checked",
        failure_reason="; ".join(result.message for result in results if result.is_error) or None,
    )
    default_state_store(workdir).save(state)
    default_event_log(workdir).append(
        "check.completed",
        workflow_id=state.workflow_id,
        state=state.final_status,
        message=state.failure_reason,
        data={"errors": [result.to_dict() for result in results if result.is_error]},
    )


def print_results(results: list[CheckResult]) -> None:
    markers = {"ok": "OK", "warning": "WARN", "error": "FAIL"}
    for result in results:
        path = f" ({result.path})" if result.path else ""
        print(f"[{markers.get(result.severity, result.severity.upper())}] {result.message}{path}")


def cmd_run(args: argparse.Namespace) -> int:
    workdir, config = load_with_overrides(args)
    results = run_checks(workdir, config, doctor=False)
    errors = [result for result in results if result.is_error]
    if args.dry_run:
        print(json.dumps({
            "workflow": {"code": config.workflow.code, "name": config.workflow.name, "iterations": [config.workflow.continue_from, config.workflow.max_iter]},
            "input_dir": str(config.input_dir),
            "executable": config.run.executable,
            "nodes": config.scheduler.nodes,
            "carry_over": VaspProfile().carry_over_plan(workdir / "iteration-N", workdir, config) if config.workflow.code == "vasp" else [],
            "checks": [result.to_dict() for result in results],
        }, indent=2, sort_keys=True))
        return 1 if errors else 0
    if errors:
        print_results(results)
        return 1
    launcher = Path(args.legacy_launcher).resolve() if args.legacy_launcher else Path(__file__).resolve().parents[1] / "launch.sh"
    command = [
        str(launcher),
        "--workdir", str(workdir),
        "--input-dir", str(config.input_dir),
        "--log-dir", str(config.log_dir),
        "--mirror-log-dir", str(config.mirror_log_dir),
        "--submit-script", str(config.submit_script),
        "--name", config.workflow.name,
        "--continue-from", str(config.workflow.continue_from),
        "--max-iter", str(config.workflow.max_iter),
        "--nodes", str(config.scheduler.nodes),
        "--monitor-interval", str(config.monitor_interval),
        "--vasp-exe", config.run.executable,
    ]
    if config.success_string:
        command.extend(["--success-string", config.success_string])
    return subprocess.run(command, check=False).returncode


def cmd_status(args: argparse.Namespace) -> int:
    state = default_state_store(Path(args.workdir).resolve()).load()
    if args.json:
        print(json.dumps(state.to_dict(), indent=2, sort_keys=True))
    else:
        print(f"workflow: {state.name} ({state.code})")
        print(f"status:   {state.final_status}")
        print(f"iter:     {state.current_iteration}")
        if state.failure_reason:
            print(f"reason:   {state.failure_reason}")
    return 0


def cmd_reset(args: argparse.Namespace) -> int:
    reset_script = Path(__file__).resolve().parents[1] / "reset-run.sh"
    command = [str(reset_script), "--workdir", str(Path(args.workdir).resolve())]
    if args.from_iter is not None:
        command.extend(["--from-iter", str(args.from_iter)])
    if args.yes:
        command.append("--yes")
    return subprocess.run(command, check=False).returncode


def cmd_test_scheduler() -> int:
    missing = [command for command in ("sbatch", "squeue", "sacct", "scancel") if not shutil.which(command)]
    if missing:
        print("missing scheduler commands: " + ", ".join(missing))
        return 1
    print("scheduler commands found")
    return 0
