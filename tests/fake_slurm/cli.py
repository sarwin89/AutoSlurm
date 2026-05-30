import re
import sys
from pathlib import Path
from typing import Any, Optional

from .state import TERMINAL_STATES, FakeSlurmError, load_state, make_plan, save_state


SQUEUE_FIELDS = {
    "i": "id",
    "A": "id",
    "j": "job_name",
    "T": "state",
    "M": "elapsed",
    "R": "reason",
}


def main(command: Optional[str] = None, argv: Optional[list[str]] = None) -> int:
    command = command or Path(sys.argv[0]).name
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        if command == "sbatch":
            return sbatch(argv)
        if command == "squeue":
            return squeue(argv)
        if command == "sacct":
            return sacct(argv)
        if command == "scancel":
            return scancel(argv)
    except FakeSlurmError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    print(f"unknown fake SLURM command: {command}", file=sys.stderr)
    return 2


def sbatch(argv: list[str]) -> int:
    state = load_state()
    options, script, script_args = _parse_sbatch_args(argv)

    planned_jobs = state["planned_jobs"]
    plan = planned_jobs.pop(0) if planned_jobs else make_plan()
    if plan.get("submit_error"):
        print(str(plan["submit_error"]), file=sys.stderr)
        save_state(state)
        return int(plan.get("submit_exit_code", 1))

    job_id = str(state["next_job_id"])
    state["next_job_id"] += 1
    chdir = options.get("chdir") or str(Path.cwd())

    state["jobs"][job_id] = {
        "id": job_id,
        "script": script,
        "script_args": script_args,
        "chdir": chdir,
        "job_name": options.get("job_name") or Path(script).name,
        "submit_options": options,
        "plan": plan,
        "squeue_calls": 0,
        "sacct_calls": 0,
        "cancelled": False,
        "artifacts_materialized": False,
    }
    state["events"].append({"command": "sbatch", "job_id": job_id, "argv": argv})
    save_state(state)

    if options.get("parsable"):
        print(job_id)
    else:
        print(f"Submitted batch job {job_id}")
    return 0


def squeue(argv: list[str]) -> int:
    state = load_state()
    job_id, fmt, no_header = _parse_squeue_args(argv)
    rows: list[str] = []

    selected_jobs = _select_jobs(state, job_id)
    for job in selected_jobs:
        entry = _next_squeue_entry(job)
        if entry["state"] == "MISSING":
            continue
        rows.append(_format_squeue_row(job, entry, fmt))

    state["events"].append({"command": "squeue", "job_id": job_id, "argv": argv})
    save_state(state)

    if rows:
        if not no_header:
            print("JOBID|STATE|TIME")
        print("\n".join(rows))
    return 0


def sacct(argv: list[str]) -> int:
    state = load_state()
    job_id, fields, parsable, no_header = _parse_sacct_args(argv)
    rows: list[str] = []
    separator = "|" if parsable else " "

    for job in _select_jobs(state, job_id):
        job["sacct_calls"] += 1
        rows.append(separator.join(_sacct_value(job, field) for field in fields))

    state["events"].append({"command": "sacct", "job_id": job_id, "argv": argv})
    save_state(state)

    if rows:
        if not no_header:
            print(separator.join(fields))
        print("\n".join(rows))
    return 0


def scancel(argv: list[str]) -> int:
    state = load_state()
    job_ids = [arg for arg in argv if not arg.startswith("-")]
    for job_id in job_ids:
        job = state["jobs"].get(str(job_id))
        if not job:
            continue
        job["cancelled"] = True
        job["plan"]["sacct"] = {
            "state": "CANCELLED",
            "exit_code": "0:15",
            "reason": "Cancelled by fake scancel",
        }

    state["events"].append({"command": "scancel", "job_ids": job_ids, "argv": argv})
    save_state(state)
    return 0


def _parse_sbatch_args(argv: list[str]) -> tuple[dict[str, Any], str, list[str]]:
    options: dict[str, Any] = {"parsable": False}
    i = 0
    while i < len(argv):
        arg = argv[i]
        if not arg.startswith("-"):
            return options, arg, argv[i + 1 :]

        if arg == "--parsable":
            options["parsable"] = True
            i += 1
        elif arg.startswith("--chdir="):
            options["chdir"] = arg.split("=", 1)[1]
            i += 1
        elif arg == "--chdir":
            options["chdir"] = argv[i + 1]
            i += 2
        elif arg.startswith("--job-name="):
            options["job_name"] = arg.split("=", 1)[1]
            i += 1
        elif arg == "--job-name":
            options["job_name"] = argv[i + 1]
            i += 2
        elif arg.startswith("--output="):
            options["output"] = arg.split("=", 1)[1]
            i += 1
        elif arg == "--output":
            options["output"] = argv[i + 1]
            i += 2
        elif arg.startswith("--error="):
            options["error"] = arg.split("=", 1)[1]
            i += 1
        elif arg == "--error":
            options["error"] = argv[i + 1]
            i += 2
        elif arg.startswith("--nodes="):
            options["nodes"] = arg.split("=", 1)[1]
            i += 1
        elif arg in ("--nodes", "-N"):
            options["nodes"] = argv[i + 1]
            i += 2
        elif arg.startswith("--export="):
            options["export"] = arg.split("=", 1)[1]
            i += 1
        elif arg == "--export":
            options["export"] = argv[i + 1]
            i += 2
        else:
            i += 1

    raise FakeSlurmError("sbatch requires a script path")


def _parse_squeue_args(argv: list[str]) -> tuple[Optional[str], str, bool]:
    job_id = None
    fmt = "%i|%T|%M"
    no_header = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "-h":
            no_header = True
            i += 1
        elif arg in ("-j", "--job", "--jobs"):
            job_id = argv[i + 1].split(",", 1)[0]
            i += 2
        elif arg.startswith("-j") and len(arg) > 2:
            job_id = arg[2:].split(",", 1)[0]
            i += 1
        elif arg.startswith("--job=") or arg.startswith("--jobs="):
            job_id = arg.split("=", 1)[1].split(",", 1)[0]
            i += 1
        elif arg in ("-o", "--format"):
            fmt = argv[i + 1]
            i += 2
        elif arg.startswith("-o") and len(arg) > 2:
            fmt = arg[2:]
            i += 1
        elif arg.startswith("--format="):
            fmt = arg.split("=", 1)[1]
            i += 1
        else:
            i += 1
    return job_id, fmt, no_header


def _parse_sacct_args(argv: list[str]) -> tuple[Optional[str], list[str], bool, bool]:
    job_id = None
    fields = ["JobID", "State", "ExitCode"]
    parsable = False
    no_header = False
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg in ("-n", "--noheader", "--no-header"):
            no_header = True
            i += 1
        elif arg in ("-P", "--parsable2", "--parsable"):
            parsable = True
            i += 1
        elif arg in ("-j", "--jobs", "--job"):
            job_id = argv[i + 1].split(",", 1)[0]
            i += 2
        elif arg.startswith("-j") and len(arg) > 2:
            job_id = arg[2:].split(",", 1)[0]
            i += 1
        elif arg.startswith("--jobs=") or arg.startswith("--job="):
            job_id = arg.split("=", 1)[1].split(",", 1)[0]
            i += 1
        elif arg in ("-o", "--format"):
            fields = _split_sacct_fields(argv[i + 1])
            i += 2
        elif arg.startswith("--format="):
            fields = _split_sacct_fields(arg.split("=", 1)[1])
            i += 1
        else:
            i += 1
    return job_id, fields, parsable, no_header


def _split_sacct_fields(raw_fields: str) -> list[str]:
    return [field.strip().split("%", 1)[0] for field in raw_fields.split(",") if field.strip()]


def _select_jobs(state: dict[str, Any], job_id: Optional[str]) -> list[dict[str, Any]]:
    if job_id is None:
        return list(state["jobs"].values())
    job = state["jobs"].get(str(job_id))
    return [job] if job else []


def _next_squeue_entry(job: dict[str, Any]) -> dict[str, str]:
    if job.get("cancelled"):
        return {"state": "CANCELLED", "elapsed": "00:00:00", "reason": "Cancelled by fake scancel"}

    entries = job["plan"].get("squeue", [])
    index = job.get("squeue_calls", 0)
    job["squeue_calls"] = index + 1
    if not entries:
        entry = {"state": "MISSING", "elapsed": "00:00:00", "reason": ""}
    else:
        entry = entries[min(index, len(entries) - 1)]

    if entry["state"] in TERMINAL_STATES or entry["state"] == "MISSING":
        _materialize_artifacts(job)
    return entry


def _format_squeue_row(job: dict[str, Any], entry: dict[str, str], fmt: str) -> str:
    values = {
        "id": job["id"],
        "job_name": job["job_name"],
        "state": entry["state"],
        "elapsed": entry["elapsed"],
        "reason": entry["reason"],
    }

    def replace(match: re.Match[str]) -> str:
        token = match.group("token")
        return str(values[SQUEUE_FIELDS.get(token, "state")])

    return re.sub(r"%(?:\.\d+)?(?P<token>[iAjTMR])", replace, fmt)


def _sacct_value(job: dict[str, Any], field: str) -> str:
    sacct_info = job["plan"]["sacct"]
    normalized = field.lower()
    if normalized in ("jobid", "jobidraw"):
        return job["id"]
    if normalized == "state":
        return sacct_info["state"]
    if normalized == "exitcode":
        return sacct_info["exit_code"]
    if normalized == "reason":
        return sacct_info.get("reason", "")
    if normalized == "elapsed":
        entries = job["plan"].get("squeue", [])
        return entries[-1]["elapsed"] if entries else "00:00:00"
    if normalized == "jobname":
        return job["job_name"]
    return ""


def _materialize_artifacts(job: dict[str, Any]) -> None:
    if job.get("artifacts_materialized"):
        return

    for artifact in job["plan"].get("artifacts", []):
        artifact_path = Path(artifact["path"])
        if not artifact_path.is_absolute():
            artifact_path = Path(job["chdir"]) / artifact_path
        artifact_path.parent.mkdir(parents=True, exist_ok=True)
        artifact_path.write_text(str(artifact.get("content", "")), encoding="utf-8")
    job["artifacts_materialized"] = True
