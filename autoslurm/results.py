from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Optional


@dataclass(frozen=True)
class CheckResult:
    severity: str
    code: str
    message: str
    path: Optional[Path] = None

    @property
    def is_error(self) -> bool:
        return self.severity == "error"

    @property
    def is_warning(self) -> bool:
        return self.severity == "warning"

    def to_dict(self) -> dict:
        data = {"severity": self.severity, "code": self.code, "message": self.message}
        if self.path is not None:
            data["path"] = str(self.path)
        return data


def ok(code: str, message: str, path: Optional[Path] = None) -> CheckResult:
    return CheckResult("ok", code, message, path)


def warn(code: str, message: str, path: Optional[Path] = None) -> CheckResult:
    return CheckResult("warning", code, message, path)


def error(code: str, message: str, path: Optional[Path] = None) -> CheckResult:
    return CheckResult("error", code, message, path)
