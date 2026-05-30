"""Contract tests for AutoSlurm config loading and VASP validation helpers."""

from __future__ import annotations

import shutil
from collections.abc import Mapping
from pathlib import Path

import pytest

from autoslurm.config import load_config
from autoslurm.plugins.vasp import (
    VaspValidationError,
    detect_fatal_errors,
    outcar_has_success,
    validate_contcar,
    validate_required_inputs,
)


FIXTURES = Path(__file__).parent / "fixtures"
DEFAULT_SUCCESS_STRING = "stopping structural energy minimisation"
ACCURACY_SUCCESS_STRING = (
    "reached required accuracy - stopping structural energy minimisation"
)


def _copy_fixture_dir(name: str, destination: Path) -> Path:
    source = FIXTURES / name
    shutil.copytree(source, destination)
    return destination


def _config_value(config: object, *names: str) -> object:
    """Read a config value from either a dataclass-like object or mapping."""
    for name in names:
        if isinstance(config, Mapping) and name in config:
            return config[name]
        if hasattr(config, name):
            return getattr(config, name)
    raise AssertionError(f"config did not expose any of: {', '.join(names)}")


def _path_value(config: object, *names: str) -> Path:
    return Path(str(_config_value(config, *names))).resolve()


def _load_config(workdir: Path, **kwargs: object) -> object:
    """Allow the package to spell the workdir keyword either way."""
    try:
        return load_config(workdir=workdir, **kwargs)
    except TypeError as exc:
        if "workdir" not in str(exc):
            raise
        return load_config(work_dir=workdir, **kwargs)


def _load_config_with_cli_overrides(workdir: Path, overrides: Mapping[str, object]) -> object:
    """Document the expected CLI-override hook while accepting common spellings."""
    try:
        return _load_config(workdir, cli_overrides=overrides)
    except TypeError as exc:
        if "cli_overrides" not in str(exc):
            raise
        return _load_config(workdir, overrides=overrides)


def _fatal_codes(errors: object) -> set[str]:
    if errors is None:
        return set()
    if isinstance(errors, Mapping):
        iterable = errors.values()
    elif isinstance(errors, (str, bytes)):
        iterable = [errors]
    else:
        iterable = errors

    codes: set[str] = set()
    for error in iterable:
        if isinstance(error, Mapping):
            code = error.get("code") or error.get("kind") or error.get("name")
        else:
            code = (
                getattr(error, "code", None)
                or getattr(error, "kind", None)
                or getattr(error, "name", None)
                or error
            )
        if code is not None:
            codes.add(str(code).upper())
    return codes


def _assert_validation_ok(result: object) -> None:
    assert result is None or result is True or getattr(result, "ok", False) is True


def test_load_config_discovers_toml_and_resolves_relative_paths(tmp_path: Path) -> None:
    jobdir = _copy_fixture_dir("config/job-with-config", tmp_path / "job")

    config = _load_config(jobdir)

    assert _path_value(config, "workdir", "work_dir") == jobdir.resolve()
    assert _path_value(config, "input_dir") == (jobdir / "inputs").resolve()
    assert _path_value(config, "log_dir") == (jobdir / "configured-logs").resolve()
    assert _path_value(config, "mirror_log_dir") == (jobdir / "mirror-logs").resolve()
    assert _path_value(config, "submit_script") == (jobdir / "submit.sh").resolve()
    assert _config_value(config, "continue_from") == 2
    assert _config_value(config, "max_iter") == 6
    assert _config_value(config, "monitor_interval") == 300
    assert _config_value(config, "nodes") == 4
    assert _config_value(config, "vasp_exe", "vasp_executable") == "/opt/vasp/bin/vasp_std"
    assert _config_value(config, "success_string") == ACCURACY_SUCCESS_STRING


def test_cli_overrides_take_precedence_over_config_file(tmp_path: Path) -> None:
    jobdir = _copy_fixture_dir("config/job-with-config", tmp_path / "job")
    override_input_dir = jobdir / "input"
    shutil.copytree(jobdir / "inputs", override_input_dir)

    config = _load_config_with_cli_overrides(
        jobdir,
        {
            "input_dir": "input",
            "nodes": 8,
            "max_iter": 9,
            "monitor_interval": 600,
            "success_string": DEFAULT_SUCCESS_STRING,
            "vasp_exe": "/custom/vasp_gam",
        },
    )

    assert _path_value(config, "input_dir") == override_input_dir.resolve()
    assert _config_value(config, "nodes") == 8
    assert _config_value(config, "max_iter") == 9
    assert _config_value(config, "monitor_interval") == 600
    assert _config_value(config, "success_string") == DEFAULT_SUCCESS_STRING
    assert _config_value(config, "vasp_exe", "vasp_executable") == "/custom/vasp_gam"


def test_default_config_discovers_input_directory_names_in_launch_order(
    tmp_path: Path,
) -> None:
    jobdir = tmp_path / "job"
    jobdir.mkdir()
    shutil.copytree(FIXTURES / "vasp/valid-input", jobdir / "inputs")
    shutil.copytree(FIXTURES / "vasp/valid-input", jobdir / "input")

    config = _load_config(jobdir)

    assert _path_value(config, "input_dir") == (jobdir / "input").resolve()


def test_validate_required_inputs_accepts_complete_vasp_input_directory(
    tmp_path: Path,
) -> None:
    input_dir = _copy_fixture_dir("vasp/valid-input", tmp_path / "input")

    result = validate_required_inputs(input_dir)

    _assert_validation_ok(result)


def test_validate_required_inputs_reports_missing_potcar(tmp_path: Path) -> None:
    input_dir = _copy_fixture_dir("vasp/valid-input", tmp_path / "input")
    (input_dir / "POTCAR").unlink()

    with pytest.raises(VaspValidationError, match="POTCAR"):
        validate_required_inputs(input_dir)


def test_validate_contcar_requires_non_empty_structurally_plausible_file(
    tmp_path: Path,
) -> None:
    valid_contcar = FIXTURES / "vasp/contcar/valid.CONTCAR"
    _assert_validation_ok(validate_contcar(valid_contcar))

    empty_contcar = tmp_path / "CONTCAR"
    empty_contcar.touch()
    with pytest.raises(VaspValidationError, match="CONTCAR|empty"):
        validate_contcar(empty_contcar)

    for fixture_name in ("truncated.CONTCAR", "nonempty-junk.CONTCAR"):
        with pytest.raises(VaspValidationError, match="CONTCAR|structure|coordinate"):
            validate_contcar(FIXTURES / f"vasp/contcar/{fixture_name}")


@pytest.mark.parametrize(
    ("outcar_name", "success_string", "expected"),
    [
        ("success-default.OUTCAR", DEFAULT_SUCCESS_STRING, True),
        ("success-accuracy.OUTCAR", ACCURACY_SUCCESS_STRING, True),
        ("not-converged.OUTCAR", DEFAULT_SUCCESS_STRING, False),
    ],
)
def test_outcar_success_string_detection(
    outcar_name: str,
    success_string: str,
    expected: bool,
) -> None:
    assert outcar_has_success(FIXTURES / f"vasp/outcar/{outcar_name}", success_string) is expected


@pytest.mark.parametrize(
    ("log_name", "expected_code"),
    [
        ("zbrent.log", "ZBRENT"),
        ("brmix.log", "BRMIX"),
        ("edddav.log", "EDDDAV"),
        ("missing-potcar.log", "MISSING_POTCAR"),
        ("corrupted-wavecar.log", "CORRUPTED_WAVECAR"),
    ],
)
def test_detect_fatal_errors_labels_common_vasp_failures(
    log_name: str,
    expected_code: str,
) -> None:
    errors = detect_fatal_errors(FIXTURES / f"vasp/fatal-logs/{log_name}")

    assert expected_code in _fatal_codes(errors)


def test_detect_fatal_errors_returns_no_errors_for_clean_log() -> None:
    errors = detect_fatal_errors(FIXTURES / "vasp/fatal-logs/clean.log")

    assert _fatal_codes(errors) == set()
